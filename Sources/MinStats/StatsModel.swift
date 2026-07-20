import Foundation
import MinStatsProtocol
import Observation

enum MenuBarMode: String {
    case compact, extended
}

/// Fixed range mapping temperature onto the panel's cold→hot bar.
enum Thermal {
    static let coldPoint = 20.0  // °C — left (cold) end of the bar
    static let hotPoint = 100.0  // °C — right (hot) end of the bar
}

@MainActor
@Observable
final class StatsModel {
    var headlineTemp: Double?
    var cpuFraction: Double?
    var memory: MemoryStats?
    var sensors: [TemperatureSensor] = []
    var fans: [FanReading] = []
    // Pools hold 10 entries: the menu bar slices its own 3/5 off the top
    // (so toggling takes effect instantly without waiting for the next tick),
    // while the agent serves the whole pool so the phone can show a longer
    // list behind its expandable sections.
    private var cpuProcessPool: [ProcessEntry] = []
    private var memoryProcessPool: [ProcessEntry] = []
    var topCPUProcesses: [ProcessEntry] { Array(cpuProcessPool.prefix(topProcessCount)) }
    var topMemoryProcesses: [ProcessEntry] { Array(memoryProcessPool.prefix(topProcessCount)) }

    var topProcessCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: "topProcessCount")
        return [3, 5, 10].contains(stored) ? stored : 3
    }() {
        didSet { UserDefaults.standard.set(topProcessCount, forKey: "topProcessCount") }
    }

    var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }

    /// Whether the phone-facing agent runs. Off by default: until the owner
    /// opts in, MinStats exposes nothing on the network — no listener, no
    /// Bonjour. `StatusBarController` starts/stops the server to match.
    var phonePairingEnabled: Bool = UserDefaults.standard.bool(forKey: "phonePairingEnabled") {
        didSet { UserDefaults.standard.set(phonePairingEnabled, forKey: "phonePairingEnabled") }
    }

    var menuBarMode: MenuBarMode = MenuBarMode(
        rawValue: UserDefaults.standard.string(forKey: "menuBarMode") ?? ""
    ) ?? .extended {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }

    static let intervalOptions: [Double] = [2, 5, 10, 30]

    var interval: Double = {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return StatsModel.intervalOptions.contains(stored) ? stored : 5.0
    }() {
        didSet {
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            start()
        }
    }

    /// Samplers live on a background actor so the per-tick IOKit/libproc work
    /// (temperature, fans, CPU, memory, and a syscall per process) never runs on
    /// the main thread — a busy Mac would otherwise hitch the menu bar.
    @ObservationIgnored private let sampler = SamplingActor()
    /// Temperature alerting (Discord/Slack/ntfy). Independent of the agent; the
    /// config window binds to it directly.
    @ObservationIgnored let alerts = AlertMonitor()
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        start()
    }

    private func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let sampler = self?.sampler else { return }
                // Collect on the background sampling actor, off the main thread.
                let reading = await sampler.collect()
                guard let self, !Task.isCancelled else { return }
                self.apply(reading)
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    /// Publishes a background sample onto the main-actor @Observable state that
    /// SwiftUI and the menu bar read, then evaluates alerts.
    private func apply(_ reading: SampleSet) {
        headlineTemp = reading.headlineTemp
        sensors = reading.sensors
        fans = reading.fans
        cpuFraction = reading.cpuFraction
        memory = reading.memory
        cpuProcessPool = reading.cpuPool
        memoryProcessPool = reading.memoryPool
        alerts.evaluate(headlineC: headlineTemp, machineName: SystemInfo.computerName, useFahrenheit: useFahrenheit)
    }

    /// The current values as the agent's wire format. Reads the last sample
    /// the menu bar already took — the server never triggers its own
    /// sampling, so a polling client costs no extra IOKit work.
    func snapshot() -> StatsDTO {
        StatsDTO(
            protocol: MinStatsProtocolVersion.current,
            sampledAt: Date().timeIntervalSince1970,
            interval: interval,
            headlineC: headlineTemp,
            cpu: cpuFraction,
            memory: memory.map { MemoryDTO(usedGB: $0.usedGB, totalGB: $0.totalGB) },
            sensors: sensors.map { SensorDTO(name: $0.name, c: $0.celsius) },
            fans: fans.map { FanDTO(name: $0.name, rpm: $0.rpm) },
            topCPU: cpuProcessPool.map { ProcessDTO(name: $0.name, value: $0.value, pids: $0.pids) },
            topMemory: memoryProcessPool.map { ProcessDTO(name: $0.name, value: $0.value, pids: $0.pids) }
        )
    }

    /// Unpadded temperature for the compact menu bar image, e.g. "38°".
    var compactTemperatureText: String {
        headlineTemp.map { "\(Int(displayDegrees($0).rounded()))°" } ?? "--°"
    }

    /// Where the current temperature sits on the cold→hot bar, 0...1.
    var temperatureFraction: Double? {
        headlineTemp.map {
            min(max(($0 - Thermal.coldPoint) / (Thermal.hotPoint - Thermal.coldPoint), 0), 1)
        }
    }

    /// Celsius converted to the display unit.
    func displayDegrees(_ celsius: Double) -> Double {
        useFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// Fixed-width menu bar title so the item never jitters horizontally.
    /// Extended: "58°  12%  9.2G"; compact: " 58°"; "--" before first sample.
    var menuTitle: String {
        let temp = headlineTemp.map { String(Int(displayDegrees($0).rounded())) } ?? "--"
        guard menuBarMode == .extended else { return "\(pad(temp, to: 3))°" }
        let cpu = cpuFraction.map { String(Int(($0 * 100).rounded())) } ?? "--"
        let ram = memory.map { String(format: "%.1f", $0.usedGB) } ?? "--"
        return "\(pad(temp, to: 3))°  \(pad(cpu, to: 3))%  \(pad(ram, to: 4))G"
    }

    /// A spoken summary for VoiceOver on the menu-bar item. The compact mode is
    /// a custom-drawn image with no readable text, and the padded extended title
    /// reads awkwardly, so both get this explicit label instead.
    var voiceOverSummary: String {
        var parts = [headlineTemp.map { "\(Int(displayDegrees($0).rounded())) degrees" } ?? "temperature unavailable"]
        if menuBarMode == .extended {
            if let cpu = cpuFraction { parts.append("CPU \(Int((cpu * 100).rounded())) percent") }
            if let memory { parts.append(String(format: "RAM %.1f gigabytes", memory.usedGB)) }
        }
        return "MinStats: " + parts.joined(separator: ", ")
    }

    private func pad(_ value: String, to width: Int) -> String {
        value.count >= width
            ? value
            : String(repeating: " ", count: width - value.count) + value
    }
}

/// A Sendable snapshot of one sampling pass, handed from the background
/// `SamplingActor` to the main actor.
struct SampleSet: Sendable {
    var headlineTemp: Double?
    var sensors: [TemperatureSensor]
    var fans: [FanReading]
    var cpuFraction: Double?
    var memory: MemoryStats?
    var cpuPool: [ProcessEntry]
    var memoryPool: [ProcessEntry]
}

/// Owns the samplers and runs them off the main thread. Each sampler holds
/// mutable state (delta baselines, IOKit handles), but it's only ever touched
/// here, so actor isolation keeps it safe without any locks. The result is a
/// value-type `SampleSet` the main actor applies.
actor SamplingActor {
    private let temperatureSampler = TemperatureSampler()
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let processSampler = ProcessSampler()
    private let fanSampler = FanSampler()

    func collect() -> SampleSet {
        let raw = temperatureSampler.sample()
        let (cpuPool, memoryPool) = processSampler.sample(top: 10)
        return SampleSet(
            headlineTemp: TemperatureSampler.headline(from: raw),
            sensors: TemperatureSampler.displaySensors(from: raw),
            fans: fanSampler.sample(),
            cpuFraction: cpuSampler.sample(),
            memory: memorySampler.sample(),
            cpuPool: cpuPool,
            memoryPool: memoryPool
        )
    }
}
