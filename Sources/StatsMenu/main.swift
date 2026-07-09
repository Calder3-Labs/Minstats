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

    let cpuSampler = CPUSampler()
    _ = cpuSampler.sample()
    Thread.sleep(forTimeInterval: 0.5)
    if let cpuUsage = cpuSampler.sample() {
        print(String(format: "CPU: %.1f%%", cpuUsage * 100))
    } else {
        print("CPU: unavailable")
    }

    let memorySampler = MemorySampler()
    if let memory = memorySampler.sample() {
        print(String(format: "RAM: %.1f / %.1f GB", memory.usedGB, memory.totalGB))
    } else {
        print("RAM: unavailable")
    }

    exit(0)
}

StatsMenuApp.main()
