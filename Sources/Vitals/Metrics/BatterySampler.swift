import Foundation
import IOKit
import IOKit.ps

struct BatterySample: Equatable {
    enum State: Equatable {
        case discharging, charging, charged
        /// On power but not charging, as with Optimized Charging holding at 80%.
        case pluggedIn
    }

    var percent: Int
    var state: State
    /// To empty while discharging, to full while charging. nil while macOS is
    /// still estimating, which it reports as -1 for some minutes after a change.
    var minutesRemaining: Int?
    /// Everything the machine is drawing, whichever source it comes from.
    var watts: Double?
    var cycleCount: Int?

    /// Deliberately no health percentage. The figure in System Settings is not
    /// exposed, and it cannot be derived: on this Mac it reads 90% while the
    /// capacities in the registry give 87% and 85%. A number that disagrees
    /// with macOS is worse than none.
    var isLow: Bool { state == .discharging && percent <= 20 }

    /// `description` is one power source's dictionary from IOKit.ps, and
    /// `registry` the properties of `AppleSmartBattery`. nil unless it is the
    /// internal battery: the same list includes Bluetooth accessories, and a
    /// pair of hearing aids is not this Mac's charge level.
    init?(description: [String: Any], registry: [String: Any]?) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool != false,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))

        let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let toFull = description[kIOPSTimeToFullChargeKey] as? Int
        let toEmpty = description[kIOPSTimeToEmptyKey] as? Int
        if description[kIOPSIsChargingKey] as? Bool == true {
            state = .charging
            minutesRemaining = toFull.flatMap { $0 > 0 ? $0 : nil }
        } else if onPower {
            state = description[kIOPSIsChargedKey] as? Bool == true ? .charged : .pluggedIn
        } else {
            state = .discharging
            minutesRemaining = toEmpty.flatMap { $0 > 0 ? $0 : nil }
        }

        guard let registry else { return }
        cycleCount = (registry["CycleCount"] as? NSNumber)?.intValue
        watts = Self.watts(registry)
    }

    private static func watts(_ registry: [String: Any]) -> Double? {
        // Milliwatts for the whole system, which is the number people mean.
        let telemetry = registry["PowerTelemetryData"] as? [String: Any]
        if let load = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            return load / 1000
        }
        // Volts times amps is the battery's side of it, so only right when the
        // battery is what is running the machine. Amperage is signed but
        // arrives as a 64-bit pattern, so a discharge reads as 18 quintillion
        // unless it goes through `int64Value`.
        guard let millivolts = (registry["Voltage"] as? NSNumber)?.doubleValue,
              let milliamps = (registry["Amperage"] as? NSNumber)?.int64Value, milliamps != 0 else { return nil }
        return millivolts * Double(milliamps.magnitude) / 1_000_000
    }
}

/// Charge, charging state and draw, from public power source APIs and the
/// battery's registry entry. Desktops have no internal battery, so `sample`
/// returns nil and the panel hides everything to do with it.
final class BatterySampler {
    private var source: CFRunLoopSource?
    private var onChange: (() -> Void)?

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func sample() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let registry = Self.registryProperties()
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let sample = BatterySample(description: description, registry: registry) { return sample }
        }
        return nil
    }

    private static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    /// Called on the main run loop when anything about a power source changes,
    /// so plugging in shows at once rather than at the next periodic read. A
    /// run loop source, not a timer: it costs nothing until macOS posts.
    func observeChanges(_ handler: @escaping () -> Void) {
        onChange = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatterySampler>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }
}
