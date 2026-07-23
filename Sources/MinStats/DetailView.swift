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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The number is the data — never let it truncate. fixedSize
                    // + priority keep it whole (3-digit Fahrenheit is the tight
                    // case); the caption below yields first if the row is snug.
                    Text(model.headlineTemp.map { "\(Int(model.displayDegrees($0).rounded()))°" } ?? "--°")
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    Text("die temperature")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Picker("Top process count", selection: $model.topProcessCount) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 78)
                }
                temperatureBar
            }
            metricRow(
                label: "CPU",
                value: model.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                fraction: model.cpuFraction
            )
            // "<1%" floor — mirrors the iOS rows; see DeviceDetailView.
            processList(model.topCPUProcesses) { $0 < 0.005 ? "<1%" : "\(Int(($0 * 100).rounded()))%" }
            metricRow(
                label: "Memory",
                value: model.memory.map { String(format: "%.1f / %.0f GB", $0.usedGB, $0.totalGB) } ?? "--",
                fraction: model.memory.map { $0.totalGB > 0 ? $0.usedGB / $0.totalGB : 0 }
            )
            processList(model.topMemoryProcesses, format: formatBytes)
        }
    }

    /// Same 3pt capsule as the CPU/Memory bars, but the fill is a fixed
    /// cold→hot gradient revealed up to where the current temperature
    /// sits — so both the length and the leading-edge color read the heat.
    private var temperatureBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Rectangle()
                    .fill(temperatureGradient)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geo.size.width * (model.temperatureFraction ?? 0))
                    }
            }
        }
        .frame(height: 3)
    }

    private var temperatureGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.62, blue: 0.92),  // cold
                Color(red: 0.98, green: 0.66, blue: 0.25),  // warm
                Color(red: 0.90, green: 0.30, blue: 0.28),  // hot
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
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
        let rowCount = max(model.sensors.count + model.fans.count, 1)
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
                ForEach(Array(model.fans.enumerated()), id: \.offset) { _, fan in
                    HStack {
                        Text(fan.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text("\(Int(fan.rpm)) rpm")
                            .font(.caption)
                            .monospacedDigit()
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
