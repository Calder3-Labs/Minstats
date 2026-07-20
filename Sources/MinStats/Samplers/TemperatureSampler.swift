import CoreFoundation
import PrivateIOKit

struct TemperatureSensor: Sendable {
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

    /// Condenses the raw readings into four summary rows — CPU die,
    /// power delivery, SSD, battery — each showing its group's hottest
    /// sensor. PMU calibration references (tcal) are dropped: they're a
    /// fixed reference point, not a temperature. Unrecognized names pass
    /// through raw, so future chips still show their sensors.
    static func displaySensors(from sensors: [TemperatureSensor]) -> [TemperatureSensor] {
        var cpu: [Double] = []
        var power: [Double] = []
        var ssd: [Double] = []
        var battery: [Double] = []
        var other: [TemperatureSensor] = []

        for sensor in sensors {
            if sensor.name == "gas gauge battery" {
                battery.append(sensor.celsius)
            } else if sensor.name.hasPrefix("NAND CH") {
                ssd.append(sensor.celsius)
            } else if isPMUSensor(sensor.name, kind: "tdie") {
                cpu.append(sensor.celsius)
            } else if isPMUSensor(sensor.name, kind: "tdev") {
                power.append(sensor.celsius)
            } else if sensor.name.hasPrefix("PMU"), sensor.name.hasSuffix("tcal") {
                continue
            } else {
                other.append(sensor)
            }
        }

        let groups: [(String, [Double])] = [
            ("CPU die", cpu), ("Power delivery", power), ("SSD", ssd), ("Battery", battery),
        ]
        return groups.compactMap { name, values in
            values.max().map { TemperatureSensor(name: name, celsius: $0) }
        } + other
    }

    /// Matches "PMU tdie3" / "PMU2 tdev5" style names.
    private static func isPMUSensor(_ name: String, kind: String) -> Bool {
        let parts = name.split(separator: " ")
        return parts.count == 2
            && (parts[0] == "PMU" || parts[0] == "PMU2")
            && parts[1].hasPrefix(kind)
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
