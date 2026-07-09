import Foundation
import Observation

@MainActor
@Observable
final class StatsModel {
    var headlineTemp: Double?
    var cpuFraction: Double?
    var memory: MemoryStats?
    var sensors: [TemperatureSensor] = []
    var topProcesses: [ProcessUsage] = []

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
        topProcesses = processSampler.sample()
    }

    /// Fixed-width menu bar title so the item never jitters horizontally.
    /// Example: "58°  12%  9.2G"; before the first sample: " --°   --%    --G".
    var menuTitle: String {
        let temp = headlineTemp.map { String(Int($0.rounded())) } ?? "--"
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
