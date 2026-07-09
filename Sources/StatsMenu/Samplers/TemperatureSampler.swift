import CoreFoundation
import PrivateIOKit

struct TemperatureSensor {
    let name: String
    let celsius: Double
}

/// Reads Apple Silicon temperature sensors via the private IOHID
/// event-system API. No root or entitlements required (unsandboxed).
final class TemperatureSampler {
    // Swift imports the CFTypeRef typedefs with the `Ref` suffix stripped.
    private let client: IOHIDEventSystemClient
    private var services: [(name: String, service: IOHIDServiceClient)] = []

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(kAppleVendorUsagePage),
            "PrimaryUsage": Int(kAppleVendorTemperatureUsage),
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        enumerateServices()
    }

    private func enumerateServices() {
        services.removeAll()
        guard let array = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            return
        }
        for service in array {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String else {
                continue
            }
            services.append((name, service))
        }
        services.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sample() -> [TemperatureSensor] {
        // Service list can come back empty right after wake; retry lazily.
        if services.isEmpty { enumerateServices() }
        var sensors: [TemperatureSensor] = []
        for (name, service) in services {
            guard let event = IOHIDServiceClientCopyEvent(service, Int64(kIOHIDEventTypeTemperature), 0, 0) else {
                continue
            }
            let celsius = IOHIDEventGetFloatValue(event, Int32(kTemperatureEventField))
            // Some sensors report 0, negatives, or wild values; drop them.
            guard (0.1..<130).contains(celsius) else { continue }
            sensors.append(TemperatureSensor(name: name, celsius: celsius))
        }
        return sensors
    }

    /// Headline number: hottest CPU/SoC die sensor, falling back to the
    /// hottest sensor overall if die sensors aren't recognizable.
    static func headline(from sensors: [TemperatureSensor]) -> Double? {
        let die = sensors.filter { s in
            s.name.localizedCaseInsensitiveContains("tdie")
                || s.name.localizedCaseInsensitiveContains("CPU")
                || s.name.hasPrefix("SOC MTR Temp Sensor")
        }
        return (die.isEmpty ? sensors : die).map(\.celsius).max()
    }
}
