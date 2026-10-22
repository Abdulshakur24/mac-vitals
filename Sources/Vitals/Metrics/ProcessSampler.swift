import AppKit
import Darwin
import Foundation

/// Per-process CPU and memory via libproc.
///
/// Deliberately not shelling out to `ps`: a fork and exec every few seconds is
/// far more expensive than the numbers are worth, and is exactly the kind of
/// background cost this app exists to avoid.
///
/// This sampler only runs while the popover is open. Walking every pid costs a
/// couple of syscalls per process — cheap on demand, pointless to pay every
/// two seconds when nobody is looking at the result.
final class ProcessSampler {
    struct Reading {
        var pid: Int32
        var started: UInt64
        var cpuTime: UInt64
        var memory: UInt64
    }

    struct Metadata {
        var name: String
        var app: ProcessApp?
    }

    /// What was seen of a process last time round.
    ///
    /// Keyed by pid, but a pid is only an identity until the process exits and
    /// the number is handed to another one — which would inherit the old name
    /// and be measured against the old CPU total. The start time tells them
    /// apart, so an entry only counts when it matches.
    private struct Seen {
        var started: UInt64
        var cpuTime: UInt64
        /// Names never change, so they are fetched once per process.
        var metadata: Metadata
    }

    private var seen: [Int32: Seen] = [:]
    private var previousTime: TimeInterval?
    private var apps: [URL: ProcessApp] = [:]
    private let read: () -> [Reading]?
    private let clock: () -> TimeInterval
    private let resolveMetadata: ((Int32) -> Metadata)?

    /// Converts mach absolute time units to nanoseconds.
    ///
    /// `ri_user_time` and `ri_system_time` are widely documented as
    /// nanoseconds, but they are not: they are mach absolute time units. On
    /// this M4 the timebase is 125/3, so treating them as nanoseconds reports
    /// CPU roughly 42x too low. Verified against a single-core busy loop,
    /// which reads 99.4% with this conversion and 2.4% without it.
    private static let systemTicksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    private let ticksToNanoseconds: Double

    init(read: @escaping () -> [Reading]? = ProcessSampler.readProcesses,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         ticksToNanoseconds: Double = ProcessSampler.systemTicksToNanoseconds,
         metadata: ((Int32) -> Metadata)? = nil) {
        self.read = read
        self.clock = clock
        self.ticksToNanoseconds = ticksToNanoseconds
        self.resolveMetadata = metadata
    }

    /// Keep cached names and bundle metadata, but never measure CPU over time
    /// spent hidden, asleep, or without readable counters.
    func resetBaseline() {
        previousTime = nil
    }

    func sample() -> ProcessSample {
        guard let readings = read() else {
            resetBaseline()
            return ProcessSample(state: .unavailable)
        }

        let now = clock()
        let elapsed = previousTime.map { now - $0 } ?? 0
        let hasBaseline = previousTime != nil && elapsed > 0
        defer { previousTime = now }

        var rows: [ProcessInfoRow] = []
        // Rebuilt every pass, which also drops processes that have exited.
        var current: [Int32: Seen] = [:]
        rows.reserveCapacity(readings.count)

        for reading in readings {
            let pid = reading.pid
            let cpuTime = reading.cpuTime
            let started = reading.started
            let previous = seen[pid].flatMap { $0.started == started ? $0 : nil }
            let metadata = previous?.metadata ?? resolveMetadata?(pid) ?? metadata(of: pid)
            current[pid] = Seen(started: started, cpuTime: cpuTime, metadata: metadata)

            var cpuShare = 0.0
            if hasBaseline, let previous, cpuTime >= previous.cpuTime {
                let nanoseconds = Double(cpuTime - previous.cpuTime) * ticksToNanoseconds
                cpuShare = nanoseconds / (elapsed * 1_000_000_000)
            }

            rows.append(ProcessInfoRow(
                pid: pid,
                started: started,
                name: metadata.name,
                cpu: cpuShare,
                memory: reading.memory,
                app: metadata.app
            ))
        }

        seen = current
        let liveApps = Set(rows.compactMap { $0.app?.bundleURL })
        apps = apps.filter { liveApps.contains($0.key) }

        guard hasBaseline else { return ProcessSample() }

        return ProcessSample(rows: rows, state: .ready)
    }

    private static func readProcesses() -> [Reading]? {
        guard let pids = allPIDs() else { return nil }
        var readings: [Reading] = []
        for pid in pids where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // Inaccessible or exited processes are omitted without root access.
            guard result == 0 else { continue }
            readings.append(Reading(pid: pid, started: usage.ri_proc_start_abstime,
                                    cpuTime: usage.ri_user_time + usage.ri_system_time,
                                    memory: usage.ri_resident_size))
        }
        return readings.isEmpty && pids.contains(where: { $0 > 0 }) ? nil : readings
    }

    private func metadata(of pid: Int32) -> Metadata {
        let name = name(of: pid)
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0,
              let url = ProcessApp.bundleURL(containing: URL(fileURLWithPath: String(cString: path))) else {
            return Metadata(name: name, app: nil)
        }
        if let app = apps[url] { return Metadata(name: name, app: app) }

        // Running metadata belongs to the outer app only when its bundle URL
        // matches. A renderer's localizedName is not the app's display name.
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
        }
        let bundle = Bundle(url: url)
        let displayName = running?.localizedName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let app = ProcessApp(bundleURL: url, name: displayName)
        apps[url] = app
        return Metadata(name: name, app: app)
    }

    private static func allPIDs() -> [Int32]? {
        // Ask for the buffer size first; the process table changes between
        // calls, so pad it rather than assume the count holds.
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return nil }

        let capacity = Int(byteCount) / MemoryLayout<Int32>.size + 32
        var pids = [Int32](repeating: 0, count: capacity)

        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<Int32>.size)
            )
        }
        guard written > 0 else { return nil }

        return Array(pids.prefix(Int(written) / MemoryLayout<Int32>.size))
    }

    private func name(of pid: Int32) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }

        var resolved = "pid \(pid)"
        if result > 0 {
            // `pbi_name` is the longer of the two (32 chars vs 16), so prefer
            // it when it is meaningful.
            let long = withUnsafePointer(to: info.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            let short = withUnsafePointer(to: info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            // Both fields come from the executable's file name, so a program
            // installed under a versioned path reports a bare version string:
            // the `claude` CLI lives at `.../claude/versions/2.1.218` and
            // shows up as "2.1.218" in both. `ps` displays "claude" because it
            // reads argv[0], so fall back to that when the name starts with a
            // digit. It costs an extra syscall, but only once per process and
            // only for the processes that actually need it.
            let looksLikeAVersion = long.first.map { $0.isNumber } ?? true
            if looksLikeAVersion, let argument = Self.argumentZero(of: pid) {
                resolved = argument
            } else if !long.isEmpty {
                resolved = long
            } else if !short.isEmpty {
                resolved = short
            }
        }

        return resolved
    }

    /// Basename of `argv[0]`, which is the name a process was invoked as.
    ///
    /// Returns nil for processes owned by another user, since reading their
    /// arguments requires root. Callers fall back to the executable name.
    private static func argumentZero(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        // Layout: argc (Int32), executable path, NUL padding, then argv[0].
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        guard index < size else { return nil }

        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }

        let argument = String(decoding: buffer[start..<index], as: UTF8.self)
        let name = (argument as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
