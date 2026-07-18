import AppKit
import Foundation
import MinStatsProtocol
import ServiceManagement

if CommandLine.arguments.contains("--print") {
    let sampler = TemperatureSampler()
    let sensors = sampler.sample()
    print("Temperature sensors (\(sensors.count)):")
    for sensor in sensors {
        print(String(format: "  %-32s %6.1f°C", (sensor.name as NSString).utf8String!, sensor.celsius))
    }
    print("Display sensors:")
    for sensor in TemperatureSampler.displaySensors(from: sensors) {
        print(String(format: "  %-32s %6.1f°C", (sensor.name as NSString).utf8String!, sensor.celsius))
    }
    let fanSampler = FanSampler()
    let fans = fanSampler.sample()
    if fans.isEmpty {
        print("Fans: none")
    } else {
        print("Fans:")
        for fan in fans {
            print(String(format: "  %-32s %6.0f rpm", (fan.name as NSString).utf8String!, fan.rpm))
        }
    }
    if let headline = TemperatureSampler.headline(from: sensors) {
        print(String(format: "Headline: %.1f°C", headline))
    } else {
        print("Headline: no valid sensors")
    }

    let cpuSampler = CPUSampler()
    let processSampler = ProcessSampler()
    _ = cpuSampler.sample()
    _ = processSampler.sample()
    Thread.sleep(forTimeInterval: 0.5)
    if let cpuUsage = cpuSampler.sample() {
        print(String(format: "CPU: %.1f%%", cpuUsage * 100))
    } else {
        print("CPU: unavailable")
    }

    let (topCPU, topMemory) = processSampler.sample()
    print("Top processes by CPU:")
    for entry in topCPU {
        print(String(format: "  %-32s %5.1f%%", (entry.name as NSString).utf8String!, entry.value * 100))
    }
    print("Top processes by memory:")
    for entry in topMemory {
        print(String(format: "  %-32s %7.0f MB", (entry.name as NSString).utf8String!, entry.value / 1_048_576))
    }

    let memorySampler = MemorySampler()
    if let memory = memorySampler.sample() {
        print(String(format: "RAM: %.1f / %.1f GB", memory.usedGB, memory.totalGB))
    } else {
        print("RAM: unavailable")
    }

    exit(0)
}

if CommandLine.arguments.contains("--register-login") {
    do {
        try SMAppService.mainApp.register()
        print("Launch at login enabled (status: \(SMAppService.mainApp.status.rawValue))")
        exit(0)
    } catch {
        print("Failed to enable launch at login: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--unregister-login") {
    do {
        try SMAppService.mainApp.unregister()
        print("Launch at login disabled (status: \(SMAppService.mainApp.status.rawValue))")
        exit(0)
    } catch {
        print("Failed to disable launch at login: \(error.localizedDescription)")
        exit(1)
    }
}

// Headless agent: serves the API with no menu bar UI, so the whole wire
// contract can be exercised with curl. Same spirit as --print.
if CommandLine.arguments.contains("--serve") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = StatsModel()
    let deviceID = AgentIdentity.deviceID()
    let store = ClientStore(deviceID: deviceID)
    let auth = Auth(deviceID: deviceID, store: store)
    let server = StatsServer(auth: auth, deviceID: deviceID) { model.snapshot() }
    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(Data("Failed to start agent: \(error)\n".utf8))
        exit(1)
    }
    let host = (SystemInfo.computerName)
        .replacingOccurrences(of: " ", with: "-") + ".local"
    let banner = """
        MinStats agent on port \(MinStatsProtocolVersion.defaultPort)
        device id: \(deviceID)
        pairing:   \(auth.pairingURL(for: store.unclaimed, host: host, port: MinStatsProtocolVersion.defaultPort, name: SystemInfo.computerName, altHosts: SystemInfo.reachableHosts()))

        """
    FileHandle.standardError.write(Data(banner.utf8))
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
