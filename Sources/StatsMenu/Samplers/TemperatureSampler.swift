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

    /// Friendly, grouped presentation of the raw readings: die sensors
    /// become "CPU die N", the six battery cell sensors collapse into one
    /// "Battery" row, NAND channels into "SSD". PMU calibration references
    /// (tcal) are dropped — they're a fixed reference point, not a
    /// temperature. Unrecognized names pass through raw, so future chips
    /// still show their sensors.
    static func displaySensors(from sensors: [TemperatureSensor]) -> [TemperatureSensor] {
        var cpuDies: [(index: Int, celsius: Double)] = []
        var auxiliaries: [(index: Int, celsius: Double)] = []
        var ssd: [Double] = []
        var battery: [Double] = []
        var other: [TemperatureSensor] = []

        for sensor in sensors {
            if sensor.name == "gas gauge battery" {
                battery.append(sensor.celsius)
            } else if sensor.name.hasPrefix("NAND CH") {
                ssd.append(sensor.celsius)
            } else if let (index, secondPMU) = parsePMUSensor(sensor.name, kind: "tdie") {
                cpuDies.append((index + (secondPMU ? 8 : 0), sensor.celsius))
            } else if let (index, secondPMU) = parsePMUSensor(sensor.name, kind: "tdev") {
                auxiliaries.append((index + (secondPMU ? 8 : 0), sensor.celsius))
            } else if sensor.name.hasPrefix("PMU"), sensor.name.hasSuffix("tcal") {
                continue
            } else {
                other.append(sensor)
            }
        }

        var display = cpuDies.sorted { $0.index < $1.index }
            .map { TemperatureSensor(name: "CPU die \($0.index)", celsius: $0.celsius) }
        display += auxiliaries.sorted { $0.index < $1.index }
            .map { TemperatureSensor(name: "Auxiliary \($0.index)", celsius: $0.celsius) }
        if let hottest = ssd.max() {
            display.append(TemperatureSensor(name: "SSD", celsius: hottest))
        }
        if let hottest = battery.max() {
            display.append(TemperatureSensor(name: "Battery", celsius: hottest))
        }
        return display + other
    }

    /// Parses "PMU tdie3" / "PMU2 tdev5" style names into (index, isPMU2).
    private static func parsePMUSensor(_ name: String, kind: String) -> (Int, Bool)? {
        let parts = name.split(separator: " ")
        guard parts.count == 2,
              parts[0] == "PMU" || parts[0] == "PMU2",
              parts[1].hasPrefix(kind),
              let index = Int(parts[1].dropFirst(kind.count)) else { return nil }
        return (index, parts[0] == "PMU2")
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
