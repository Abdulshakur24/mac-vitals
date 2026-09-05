import Foundation

/// Command-line dump of every sampler, for cross-checking against the system's
/// own tools. Run with `Vitals --probe`.
enum Probe {
    static func run() {
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let network = NetworkSampler()
        let disk = DiskSampler()
        let thermal = ThermalSampler()
        let processes = ProcessSampler()

        print("thermal sensors available: \(thermal.isAvailable)")
        print("low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")

        print("cores: \(cpu.performanceCoreCount)P + \(cpu.efficiencyCoreCount)E")

        // Prime the delta-based samplers; their first call has no baseline.
        _ = cpu.sample()
        _ = network.sample()
        _ = disk.sample()
        _ = processes.sample()

        for round in 1...3 {
            Thread.sleep(forTimeInterval: 1.0)
            print("\n--- sample \(round) ---")

            if let sample = cpu.sample() {
                print(String(
                    format: "cpu    total %5.1f%%  user %5.1f%%  system %5.1f%%  idle %5.1f%%",
                    sample.total * 100, sample.user * 100,
                    sample.system * 100, sample.idle * 100
                ))
                let cores = sample.perCore
                    .map { String(format: "%.0f", $0 * 100) }
                    .joined(separator: " ")
                print("cores  \(cores)")
            }

            if let sample = memory.sample() {
                print("""
                mem    used \(Format.bytes(sample.used)) / \(Format.bytes(sample.total))  \
                pressure \(sample.pressureLabel) (level \(sample.pressureLevel))
                """)
                print("""
                       app \(Format.bytes(sample.app))  wired \(Format.bytes(sample.wired))  \
                compressed \(Format.bytes(sample.compressed))  free \(Format.bytes(sample.free))
                """)
                print("""
                       swap \(Format.bytes(sample.swapUsed)) / \(Format.bytes(sample.swapTotal))  \
                (\(Format.percent(sample.swapFraction)))
                """)
            }

            if let sample = network.sample() {
                print("""
                net    down \(Format.rate(sample.download))  up \(Format.rate(sample.upload))  \
                [\(sample.interface) \(sample.ipAddress ?? "-")]
                """)
                print("""
                       session in \(Format.bytes(sample.sessionReceived))  \
                out \(Format.bytes(sample.sessionSent))
                """)
            }

            let thermalSample = thermal.sample()
            if let cpuTemp = thermalSample.cpu {
                print("""
                temp   cpu \(Format.celsius(cpuTemp)) max / \
                \(thermalSample.cpuAverage.map(Format.celsius) ?? "-") avg  \
                gpu \(thermalSample.gpu.map(Format.celsius) ?? "-")  \
                ssd \(thermalSample.ssd.map(Format.celsius) ?? "-")  \
                batt \(thermalSample.battery.map(Format.celsius) ?? "-")
                """)
                let cpuCount = thermalSample.readings.filter { $0.kind == .cpu }.count
                print("       \(thermalSample.readings.count) live sensors "
                      + "(\(cpuCount) die), thermal state \(thermalSample.state.rawValue)")
            } else {
                print("temp   unavailable (state \(thermalSample.state.rawValue))")
            }

            if let sample = disk.sample() {
                print("""
                disk   read \(Format.rate(sample.read))  write \(Format.rate(sample.write))  \
                free \(Format.bytes(sample.free)) / \(Format.bytes(sample.total))
                """)
            }

            if round == 3, let sample = processes.sample() {
                print("top by cpu:")
                for row in sample.topByCPU {
                    print(String(
                        format: "       %-28@ %5.1f%%  %@",
                        row.name as NSString, row.cpu * 100, Format.bytes(row.memory) as NSString
                    ))
                }
                print("top by memory:")
                for row in sample.topByMemory {
                    print(String(
                        format: "       %-28@ %5.1f%%  %@",
                        row.name as NSString, row.cpu * 100, Format.bytes(row.memory) as NSString
                    ))
                }
            }
        }
    }
}
