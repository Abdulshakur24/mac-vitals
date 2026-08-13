import Foundation
import IOKit

enum SensorKind {
    case cpu       // SoC die sensors
    case gpu
    case ssd
    case battery
    case other     // board/device sensors, calibration references
}

struct TemperatureReading: Equatable, Identifiable {
    var id: Int
    var name: String
    var celsius: Double
    var kind: SensorKind
}

struct ThermalSample: Equatable {
    /// Hottest SoC die sensor. nil when no sensor could be read at all — the
    /// UI hides the readout rather than showing a fabricated zero.
    var cpu: Double?
    var cpuAverage: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var readings: [TemperatureReading] = []
    /// The kernel's own thermal state. Needs no private API, so this stays
    /// meaningful even if the sensor interface ever disappears.
    var state: ProcessInfo.ThermalState = .nominal
}

/// Temperature from the HID sensor services Apple exposes on Apple Silicon.
///
/// There is no public API for die temperature on Apple Silicon. `powermetrics`
/// can read it but requires root, which a background menu bar app has no
/// business holding. The remaining option is the IOHIDEventSystem sensor
/// interface, which is private.
///
/// Every symbol is resolved with `dlsym` at run time rather than linked
/// against. That is deliberate: if a future macOS drops or renames any of
/// them, `load()` fails, `isAvailable` goes false, and the temperature readout
/// quietly disappears while every other metric keeps working. Linking these
/// directly would instead produce an app that fails to launch at all.
final class ThermalSampler {
    // MARK: - Private API bindings

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ClientSetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias ClientCopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias ServiceCopyEvent = @convention(c)
        (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias ServiceCopyProperty = @convention(c)
        (AnyObject?, CFString?) -> Unmanaged<AnyObject>?
    private typealias EventGetFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    private struct Bindings {
        var clientCreate: ClientCreate
        var setMatching: ClientSetMatching
        var copyServices: ClientCopyServices
        var copyEvent: ServiceCopyEvent
        var copyProperty: ServiceCopyProperty
        var floatValue: EventGetFloatValue
    }

    /// Apple's vendor HID page, and the temperature-sensor usage within it.
    private static let appleVendorPage: Int64 = 0xff00
    private static let temperatureSensorUsage: Int64 = 0x0005
    /// kIOHIDEventTypeTemperature, and the field selector derived from it.
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let bindings: Bindings?
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var names: [String] = []
    private var kinds: [SensorKind] = []

    var isAvailable: Bool { bindings != nil && !services.isEmpty }

    init() {
        bindings = Self.load()
        connect()
    }

    private static func load() -> Bindings? {
        // The framework is already resident in every process; this just gets a
        // handle for symbol lookup.
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY
        ) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
            let matching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
            let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
            let floatValue = symbol("IOHIDEventGetFloatValue", as: EventGetFloatValue.self)
        else { return nil }

        return Bindings(
            clientCreate: create,
            setMatching: matching,
            copyServices: copyServices,
            copyEvent: copyEvent,
            copyProperty: copyProperty,
            floatValue: floatValue
        )
    }

    /// Builds the sensor client once and caches each service's name.
    /// Enumerating services and copying their properties is comparatively
    /// expensive, and the names never change, so only the event read happens
    /// per sample.
    private func connect() {
        guard let bindings else { return }
        guard let created = bindings.clientCreate(kCFAllocatorDefault) else { return }
        let client = created.takeRetainedValue()

        let matching: [String: Int64] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureSensorUsage,
        ]
        _ = bindings.setMatching(client, matching as CFDictionary)

        guard let copied = bindings.copyServices(client) else { return }
        let array = copied.takeRetainedValue() as [AnyObject]

        var services: [AnyObject] = []
        var names: [String] = []
        var kinds: [SensorKind] = []
        for service in array {
            guard let nameRef = bindings.copyProperty(service, "Product" as CFString),
                  let name = nameRef.takeRetainedValue() as? String
            else { continue }

            // Reading an event from a service is the expensive part of a
            // sample, and this machine exposes 47 of them — half being board
            // and calibration sensors that are never displayed. Filtering
            // here, once, removes that work from every subsequent sample.
            let kind = Self.classify(name)
            guard kind != .other else { continue }

            services.append(service)
            names.append(name)
            kinds.append(kind)
        }

        self.client = client
        self.services = services
        self.names = names
        self.kinds = kinds
    }

    /// Maps a sensor's product name onto what it actually measures.
    ///
    /// Naming is not consistent across Macs or OS versions. This M4 exposes
    /// descriptive names ("PMU tdie8", "NAND CH0 temp"), while other Apple
    /// Silicon machines report the four-character SMC-style keys ("Tp09",
    /// "Tg0D"). Both forms are handled so the app is not silently blind on
    /// hardware other than the one it was written on.
    static func classify(_ name: String) -> SensorKind {
        let lower = name.lowercased()

        // Calibration references, not temperatures. On this machine tcal
        // reads ~52°C at idle and would otherwise dominate the CPU maximum.
        if lower.contains("tcal") { return .other }

        if lower.contains("battery") || lower.contains("gas gauge") { return .battery }
        if lower.contains("nand") || lower.contains("ssd") { return .ssd }
        if lower.contains("gpu") { return .gpu }
        if lower.contains("tdie") || lower.contains("soc") { return .cpu }

        // SMC-style four-character keys: Tp = P-cores, Te = E-cores, Tg = GPU.
        if lower.count == 4 {
            if lower.hasPrefix("tp") || lower.hasPrefix("te") { return .cpu }
            if lower.hasPrefix("tg") { return .gpu }
        }

        return .other
    }

    func sample() -> ThermalSample {
        var result = ThermalSample()
        result.state = ProcessInfo.processInfo.thermalState

        guard let bindings, !services.isEmpty else { return result }

        var readings: [TemperatureReading] = []
        var cpuValues: [Double] = []
        var gpuValues: [Double] = []
        var ssdValues: [Double] = []
        var batteryValues: [Double] = []

        for (index, service) in services.enumerated() {
            guard let eventRef = bindings.copyEvent(
                service, Self.temperatureEventType, 0, 0
            ) else { continue }
            let event = eventRef.takeRetainedValue()

            let value = bindings.floatValue(event, Self.temperatureField)
            // Unpopulated sensors on this machine report around -22°C, and no
            // real reading belongs outside this window. Bounding here keeps a
            // dead sensor from dragging an average down.
            guard value > 1, value < 130 else { continue }

            let kind = kinds[index]
            readings.append(
                TemperatureReading(id: index, name: names[index], celsius: value, kind: kind)
            )

            switch kind {
            case .cpu: cpuValues.append(value)
            case .gpu: gpuValues.append(value)
            case .ssd: ssdValues.append(value)
            case .battery: batteryValues.append(value)
            case .other: break
            }
        }

        // Report the hottest die sensor rather than the mean: averaging two
        // dozen sensors understates the one spot that is actually throttling.
        result.cpu = cpuValues.max()
        result.cpuAverage = cpuValues.isEmpty
            ? nil : cpuValues.reduce(0, +) / Double(cpuValues.count)
        result.gpu = gpuValues.max()
        result.ssd = ssdValues.max()
        result.battery = batteryValues.max()
        result.readings = readings.sorted { $0.name < $1.name }
        return result
    }
}
