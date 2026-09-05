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
/// Some machines expose wrapping 32-bit counters through 64-bit fields.
/// Wrap recovery is deliberately conservative; an uncertain reading is dropped
/// rather than presented as a multi-gigabyte transfer.
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
    struct Counters {
        var received: UInt64
        var sent: UInt64
        var index: UInt16 = 0
        var changedAt: Int64 = 0
        var baudrate: UInt64 = 0
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: TimeInterval = 0
    private var sessionReceived: UInt64 = 0
    private var sessionSent: UInt64 = 0

    func resetBaseline() {
        previous.removeAll()
        previousTime = 0
    }

    func sample() -> NetworkSample? {
        guard let current = readInterfaces() else { resetBaseline(); return nil }
        var sample = consume(current.byInterface, at: ProcessInfo.processInfo.systemUptime)
        if !sample.interface.isEmpty { sample.ipAddress = ipAddress(for: sample.interface) }
        return sample
    }

    /// Exposed internally so counter resets and interface replacement can be
    /// regression-tested without changing the machine's network connection.
    func consume(_ current: [String: Counters], at now: TimeInterval) -> NetworkSample {
        let elapsed = now - previousTime
        let hasBaseline = previousTime > 0 && elapsed > 0
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var busiest = ""
        var bestDelta: UInt64 = 0
        for name in current.keys.sorted() {
            guard let counters = current[name] else { continue }
            if busiest.isEmpty { busiest = name }
            guard hasBaseline, let old = previous[name],
                  old.index == counters.index, old.changedAt == counters.changedAt else { continue }
            let down = Self.counterDelta(new: counters.received, old: old.received,
                                         elapsed: elapsed, baudrate: counters.baudrate)
            let up = Self.counterDelta(new: counters.sent, old: old.sent,
                                       elapsed: elapsed, baudrate: counters.baudrate)
            received &+= down
            sent &+= up
            if down &+ up > bestDelta {
                busiest = name
                bestDelta = down &+ up
            }
        }
        previous = current // includes the empty/disconnected state
        previousTime = now
        sessionReceived &+= received
        sessionSent &+= sent
        return NetworkSample(download: hasBaseline ? Double(received) / elapsed : 0,
                             upload: hasBaseline ? Double(sent) / elapsed : 0,
                             sessionReceived: sessionReceived, sessionSent: sessionSent,
                             interface: busiest)
    }

    /// A backward counter is ambiguous. Accept a single 32-bit wrap only when
    /// it crosses near the boundary within a conservative link-rate budget.
    /// Unknown link speeds and long intervals are rebaselined instead. A reset
    /// at the boundary with unchanged identity cannot be distinguished by this API.
    static func counterDelta(new: UInt64, old: UInt64, elapsed: TimeInterval, baudrate: UInt64) -> UInt64 {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let modulus = UInt64(UInt32.max) + 1
        if new >= old { return new - old }
        guard old < modulus, new < modulus, baudrate > 0 else { return 0 }
        let budget = Double(baudrate) / 8 * elapsed * 1.25
        guard budget < Double(modulus) / 8 else { return 0 }
        let delta = modulus - old + new
        return Double(delta) <= budget ? delta : 0
    }

    private struct Interfaces {
        var byInterface: [String: Counters] = [:]
    }

    private func readInterfaces() -> Interfaces? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        if size < buffer.count { buffer.removeSubrange(size...) }
        return Interfaces(byInterface: Self.interfaceCounters(in: buffer))
    }

    static func interfaceCounters(in buffer: [UInt8]) -> [String: Counters] {
        let size = buffer.count
        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            // Route records share only a four-byte prefix. Address records
            // between interface records are shorter than if_msghdr.
            while offset + 4 <= size {
                let messageLength = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let messageType = base.load(fromByteOffset: offset + 3, as: UInt8.self)
                guard messageLength >= 4, offset + messageLength <= size else { break }
                defer { offset += messageLength }

                guard messageType == RTM_IFINFO2,
                      MemoryLayout<if_msghdr2>.stride <= messageLength else { continue }

                let message = base.advanced(by: offset)
                    .loadUnaligned(as: if_msghdr2.self)

                let flags = message.ifm_flags
                // Loopback traffic is not network traffic; counting it makes a
                // local dev server look like a saturated uplink.
                guard flags & IFF_LOOPBACK == 0 else { continue }
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }

                let name = Self.interfaceName(base: base, offset: offset, limit: offset + messageLength)
                guard !name.isEmpty else { continue }

                let data = message.ifm_data
                result[name] = Counters(
                    received: data.ifi_ibytes,
                    sent: data.ifi_obytes,
                    index: message.ifm_index,
                    changedAt: Int64(data.ifi_lastchange.tv_sec) * 1_000_000 + Int64(data.ifi_lastchange.tv_usec),
                    baudrate: data.ifi_baudrate
                )
            }
        }

        return result
    }

    /// The interface name lives in the `sockaddr_dl` that immediately follows
    /// the message header, not in the header itself.
    static func interfaceName(base: UnsafeRawPointer, offset: Int, limit: Int) -> String {
        let addressOffset = offset + MemoryLayout<if_msghdr2>.stride
        // sockaddr_dl is variable-length on the wire. A short name need not
        // occupy the full sizeof(sockaddr_dl); only read the fixed 8-byte
        // prefix followed by the declared name bytes, within this message.
        let prefixSize = 8
        guard addressOffset + prefixSize <= limit else { return "" }
        let link = base.advanced(by: addressOffset)
        let addressLength = Int(link.load(as: UInt8.self))
        let nameLength = Int(link.load(fromByteOffset: 5, as: UInt8.self))
        guard nameLength > 0, nameLength <= 16,
              prefixSize + nameLength <= addressLength,
              addressOffset + addressLength <= limit else { return "" }
        let bytes = link.advanced(by: prefixSize).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: bytes, count: nameLength), as: UTF8.self)
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
