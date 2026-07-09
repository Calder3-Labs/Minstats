import AppKit
import SwiftUI

struct DetailView: View {
    @Bindable var model: StatsModel

    var body: some View {
        VStack(spacing: 0) {
            headline
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            if !model.topProcesses.isEmpty {
                Divider()
                topProcesses
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            Divider()
            sensorList
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.headlineTemp.map { "\(Int($0.rounded()))°" } ?? "--°")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("die temperature")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            metricRow(
                label: "CPU",
                value: model.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                fraction: model.cpuFraction
            )
            metricRow(
                label: "Memory",
                value: model.memory.map { String(format: "%.1f / %.0f GB", $0.usedGB, $0.totalGB) } ?? "--",
                fraction: model.memory.map { $0.totalGB > 0 ? $0.usedGB / $0.totalGB : 0 }
            )
        }
    }

    private func metricRow(label: String, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: geo.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 3)
        }
    }

    private var topProcesses: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Top Processes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.topProcesses) { process in
                HStack {
                    Text(process.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("\(Int((process.cpuFraction * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
    }

    private var sensorList: some View {
        ScrollView {
            VStack(spacing: 7) {
                if model.sensors.isEmpty {
                    Text("No sensors")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(model.sensors.enumerated()), id: \.offset) { _, sensor in
                        HStack {
                            Text(sensor.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(String(format: "%.1f°", sensor.celsius))
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 260)
    }

    private var footer: some View {
        HStack {
            Picker("Refresh interval", selection: $model.interval) {
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
