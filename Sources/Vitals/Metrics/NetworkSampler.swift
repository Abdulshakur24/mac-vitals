import Darwin
import Foundation

struct NetworkSample: Equatable {
    var download: Double = 0   // bytes/sec
    var upload: Double = 0     // bytes/sec
    /// Accumulated since the app launched, not since boot. See the note below.
    var sessionReceived: UInt64 = 0
    var sessionSent: UInt64 = 0
    var interface: String = ""
    var ipAddress: String?
}

/// Throughput from the kernel's per-interface byte counters.
///
/// Two things here are less obvious than they look.
///
/// **The counters are effectively 32-bit.** `if_msghdr2` declares `ifi_ibytes`
/// as `u_int64_t`, but on this machine the value it carries is the true
/// counter truncated to 32 bits — verified by comparing against `netstat -ib`,
/// which reports a figure exceeding 2^32 while this API returns exactly that
/// figure mod 2^32, with no 64-bit copy anywhere in the message payload. So
/// every counter is read back as wrapping at 4 GB, and deltas are corrected
/// for that wrap. At gigabit speeds a wrap happens every ~35 seconds, so
/// ignoring it would visibly undercount throughput.
///
/// **Totals are session-scoped.** Since-boot totals cannot be recovered from a
/// wrapped counter, and they are not especially interesting anyway. Summing
/// wrap-corrected deltas since launch gives a number that is both accurate and
/// more useful: how much this machine has moved while you were watching.
///
/// Deltas are tracked per interface rather than on a summed total, so a VPN
/// coming up or Wi-Fi reconnecting doesn't register as a huge phantom
/// transfer — a newly appeared interface simply has no baseline to diff yet.
final class NetworkSampler {
    private struct Counters {
        var received: UInt64
        var sent: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: TimeInterval = 0
    private var sessionReceived: UInt64 = 0
    private var sessionSent: UInt64 = 0

    /// Widest plausible transfer in one sample interval. Anything above this
    /// is a counter reset or an interface being renumbered, not real traffic.
    private let implausibleDelta: UInt64 = 8 << 30 // 8 GB

    func sample() -> NetworkSample? {
        guard let current = readInterfaces() else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousTime
        let hasBaseline = previousTime > 0 && elapsed > 0

        var deltaReceived: UInt64 = 0
        var deltaSent: UInt64 = 0

        for (name, counters) in current.byInterface {
            defer { previous[name] = counters }
            guard hasBaseline, let old = previous[name] else { continue }
            deltaReceived += wrapCorrectedDelta(new: counters.received, old: old.received)
            deltaSent += wrapCorrectedDelta(new: counters.sent, old: old.sent)
        }

        // Drop interfaces that have gone away so their stale baselines don't
        // linger and produce a bogus delta if the name is ever reused.
        previous = previous.filter { current.byInterface.keys.contains($0.key) }
        previousTime = now

        guard hasBaseline else { return nil }

        sessionReceived += deltaReceived
        sessionSent += deltaSent

        return NetworkSample(
            download: Double(deltaReceived) / elapsed,
            upload: Double(deltaSent) / elapsed,
            sessionReceived: sessionReceived,
            sessionSent: sessionSent,
            interface: current.primary,
            ipAddress: current.primary.isEmpty ? nil : ipAddress(for: current.primary)
        )
    }

    /// Difference between two readings of a counter that wraps at 2^32.
    private func wrapCorrectedDelta(new: UInt64, old: UInt64) -> UInt64 {
        let delta: UInt64
        if new >= old {
            delta = new - old
        } else {
            // Went backwards: assume one 32-bit wrap rather than a reset.
            delta = (UInt64(UInt32.max) + 1 - old) + new
        }
        return delta < implausibleDelta ? delta : 0
    }

    private struct Interfaces {
        var byInterface: [String: Counters] = [:]
        var primary = ""
    }

    private func readInterfaces() -> Interfaces? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        var result = Interfaces()
        var bestScore: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            while offset + MemoryLayout<if_msghdr>.stride <= size {
                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.stride <= size else { continue }

                let message = base.advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr2.self).pointee

                let flags = message.ifm_flags
                // Loopback traffic is not network traffic; counting it makes a
                // local dev server look like a saturated uplink.
                guard flags & IFF_LOOPBACK == 0 else { continue }
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }

                let name = Self.interfaceName(base: base, offset: offset, limit: size)
                guard !name.isEmpty else { continue }

                let data = message.ifm_data
                result.byInterface[name] = Counters(
                    received: data.ifi_ibytes,
                    sent: data.ifi_obytes
                )

                // Show whichever interface has moved the most, so an active
                // Ethernet dock or VPN wins over idle Wi-Fi.
                let score = data.ifi_ibytes &+ data.ifi_obytes
                if score >= bestScore {
                    bestScore = score
                    result.primary = name
                }
            }
        }

        return result.byInterface.isEmpty ? nil : result
    }

    /// The interface name lives in the `sockaddr_dl` that immediately follows
    /// the message header, not in the header itself.
    private static func interfaceName(base: UnsafeRawPointer, offset: Int, limit: Int) -> String {
        let addressOffset = offset + MemoryLayout<if_msghdr2>.stride
        guard addressOffset + MemoryLayout<sockaddr_dl>.stride <= limit else { return "" }

        let link = base.advanced(by: addressOffset)
            .assumingMemoryBound(to: sockaddr_dl.self)
        let length = Int(link.pointee.sdl_nlen)
        guard length > 0, length <= 16 else { return "" }

        return withUnsafePointer(to: link.pointee.sdl_data) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            }
        }
    }

    private func ipAddress(for interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let name = entry.ifa_name.map({ String(cString: $0) }),
                  name == interface
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            return String(cString: host)
        }
        return nil
    }
}
