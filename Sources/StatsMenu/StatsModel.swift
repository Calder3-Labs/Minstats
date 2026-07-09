import Foundation
import Observation

enum MenuBarMode: String {
    case compact, extended
}

@MainActor
@Observable
final class StatsModel {
    var headlineTemp: Double?
    var cpuFraction: Double?
    var memory: MemoryStats?
    var sensors: [TemperatureSensor] = []
    var topCPUProcesses: [ProcessEntry] = []
    var topMemoryProcesses: [ProcessEntry] = []

    var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }

    var menuBarMode: MenuBarMode = MenuBarMode(
        rawValue: UserDefaults.standard.string(forKey: "menuBarMode") ?? ""
    ) ?? .extended {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }

    var interval: Double = {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return stored > 0 ? stored : 2.0
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
        sensors = temperatureSampler.sample()
        headlineTemp = TemperatureSampler.headline(from: sensors)
        cpuFraction = cpuSampler.sample()
        memory = memorySampler.sample()
        (topCPUProcesses, topMemoryProcesses) = processSampler.sample()
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
