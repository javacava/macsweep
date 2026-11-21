import SwiftUI
import Charts
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject var model: BatteryModel
    @EnvironmentObject var history: HistoryStore

    enum Metric: String, CaseIterable, Identifiable {
        case health = "Health, %"
        case capacity = "Capacity, mAh"
        case cycles = "Cycles"
        var id: String { rawValue }
    }

    @State private var deviceID = ""
    @State private var metric = Metric.health
    @State private var selected = Set<UUID>()
    @AppStorage(Prefs.fahrenheit) private var fahrenheit = false

    private var current: HistoryDevice? {
        history.device(deviceID) ?? history.devices.first
    }

    var body: some View {
        Group {
            if let device = current {
                content(device)
            } else {
                ContentUnavailableView {
                    Label("History is empty", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Entries appear automatically once a day, or when you press Save to history.")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .help("Export the device history as CSV")
                    .disabled(current == nil)
                Button {
                    if let d = current { history.delete(entries: selected, from: d.id) }
                    selected.removeAll()
                } label: { Label("Delete entries", systemImage: "trash") }
                    .help("Delete the selected entries")
                    .disabled(selected.isEmpty)
            }
        }
    }

    private func value(_ e: HistoryEntry) -> Double {
        switch metric {
        case .health: return e.health
        case .capacity: return Double(e.fullCharge)
        case .cycles: return Double(e.cycles)
        }
    }

    private func domain(_ entries: [HistoryEntry]) -> ClosedRange<Double> {
        let values = entries.map(value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, max(abs(hi) * 0.02, 1))
        return (lo - pad)...(hi + pad)
    }

    private func content(_ device: HistoryDevice) -> some View {
        let entries = device.entries.sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Device", selection: Binding(get: { device.id }, set: { deviceID = $0; selected.removeAll() })) {
                    ForEach(history.devices) { d in
                        Label(d.name, systemImage: d.kind == "mac" ? "laptopcomputer" : "iphone").tag(d.id)
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }

            if let first = entries.first, let last = entries.last {
                Text(summary(first, last, count: entries.count))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Chart(entries) { e in
                LineMark(x: .value("Date", e.date), y: .value(metric.rawValue, value(e)))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", e.date), y: .value(metric.rawValue, value(e)))
                    .symbolSize(30)
            }
            .chartYScale(domain: domain(entries))
            .frame(height: 210)
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            Table(entries.reversed(), selection: $selected) {
                TableColumn("Date") { Text(Fmt.dateTime($0.date)).monospacedDigit() }
                    .width(min: 140, ideal: 150)
                TableColumn("Health") { Text(verbatim: "\(Int($0.health.rounded()))%").monospacedDigit() }
                    .width(min: 60, ideal: 75)
                TableColumn("Capacity") { Text(Fmt.mAh($0.fullCharge)).monospacedDigit() }
                    .width(min: 90, ideal: 105)
                TableColumn("Cycles") { Text(verbatim: "\($0.cycles)").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("Temperature") { Text(Fmt.temp($0.temperature)).monospacedDigit() }
                    .width(min: 70, ideal: 85)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
    }

    private func summary(_ first: HistoryEntry, _ last: HistoryEntry, count: Int) -> String {
        guard count > 1 else { return "1 entry from \(Fmt.date(first.date)). Changes show up once there are more." }
        let dh = last.health - first.health
        let dc = last.cycles - first.cycles
        return "\(count) entries since \(Fmt.date(first.date)): health \(Fmt.num(dh, 1, signed: true)) pts, cycles \(dc >= 0 ? "+" : "")\(dc)."
    }

    private func exportCSV() {
        guard let d = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "bettary-\(d.name).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? history.csv(for: d.id).write(to: url, atomically: true, encoding: .utf8)
    }
}
