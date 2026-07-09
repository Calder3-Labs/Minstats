import Foundation

if CommandLine.arguments.contains("--print") {
    let sampler = TemperatureSampler()
    let sensors = sampler.sample()
    print("Temperature sensors (\(sensors.count)):")
    for sensor in sensors {
        print(String(format: "  %-32s %6.1f°C", (sensor.name as NSString).utf8String!, sensor.celsius))
    }
    if let headline = TemperatureSampler.headline(from: sensors) {
        print(String(format: "Headline: %.1f°C", headline))
    } else {
        print("Headline: no valid sensors")
    }
    exit(0)
}

print("UI not implemented yet — run with --print")
exit(1)
