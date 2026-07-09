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
            Divider()
            sensorList
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
        // Damp the popover's behind-window vibrancy: keeps the blur but
        // stops busy backgrounds from bleeding through the content.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.headlineTemp.map { "\(Int(model.displayDegrees($0).rounded()))°" } ?? "--°")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("die temperature")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Top process count", selection: $model.topProcessCount) {
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 52)
            }
            metricRow(
                label: "CPU",
                value: model.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                fraction: model.cpuFraction
            )
            processList(model.topCPUProcesses) { "\(Int(($0 * 100).rounded()))%" }
            metricRow(
                label: "Memory",
                value: model.memory.map { String(format: "%.1f / %.0f GB", $0.usedGB, $0.totalGB) } ?? "--",
                fraction: model.memory.map { $0.totalGB > 0 ? $0.usedGB / $0.totalGB : 0 }
            )
            processList(model.topMemoryProcesses, format: formatBytes)
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

    @ViewBuilder
    private func processList(_ entries: [ProcessEntry], format: @escaping (Double) -> String) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.name)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(format(entry.value))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .padding(.leading, 10)
            .padding(.top, -6)
        }
    }

    private func formatBytes(_ bytes: Double) -> String {
        bytes >= 1_073_741_824
            ? String(format: "%.1f GB", bytes / 1_073_741_824)
            : String(format: "%.0f MB", bytes / 1_048_576)
    }

    private var sensorList: some View {
        // NSPopover sizes SwiftUI content to its ideal size, and a
        // ScrollView's ideal height is near zero — so derive an explicit
        // height from the row count instead of relying on maxHeight.
        let rowCount = max(model.sensors.count, 1)
        let contentHeight = CGFloat(rowCount) * 20 + 20
        return ScrollView {
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
                            Text(String(format: "%.1f°", model.displayDegrees(sensor.celsius)))
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(height: min(contentHeight, 260))
    }

    private var footer: some View {
        HStack {
            Picker("Refresh interval", selection: $model.interval) {
                ForEach(StatsModel.intervalOptions, id: \.self) { option in
                    Text("\(Int(option))s").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 128)
            Picker("Unit", selection: $model.useFahrenheit) {
                Text("°C").tag(false)
                Text("°F").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 64)
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
