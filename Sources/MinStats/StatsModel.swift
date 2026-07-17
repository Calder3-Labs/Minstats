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

    @ObservationIgnored private let temperatureSampler = TemperatureSampler()
    @ObservationIgnored private let cpuSampler = CPUSampler()
    @ObservationIgnored private let memorySampler = MemorySampler()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private let fanSampler = FanSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        start()
    }

    private func start() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                sampleOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func sampleOnce() {
        let raw = temperatureSampler.sample()
        headlineTemp = TemperatureSampler.headline(from: raw)
        sensors = TemperatureSampler.displaySensors(from: raw)
        fans = fanSampler.sample()
        cpuFraction = cpuSampler.sample()
        memory = memorySampler.sample()
        (cpuProcessPool, memoryProcessPool) = processSampler.sample(top: 10)
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

    private func pad(_ value: String, to width: Int) -> String {
        value.count >= width
            ? value
            : String(repeating: " ", count: width - value.count) + value
    }
}
