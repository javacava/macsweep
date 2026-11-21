import SwiftUI
import Charts

struct DeviceDetailView: View {
    @EnvironmentObject var model: BatteryModel
    let device: DevicePresentation

    enum SheetKind: String, Identifiable {
        case details, raw, facts
        var id: String { rawValue }
    }

    @State private var sheet: SheetKind?
    @State private var notice: String?
    // Read only so the view redraws at once when the unit changes.
    @AppStorage(Prefs.fahrenheit) private var fahrenheit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let b = device.battery {
                    capacity(b)
                    tiles(b)
                    liveChart
                    footer(b)
                } else {
                    ContentUnavailableView {
                        Label("No battery data", systemImage: "battery.0percent")
                    } description: {
                        Text(device.problem ?? "No data yet.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh the data now")
                Button {
                    notice = model.saveToHistory(device) ? "Saved to history" : "Nothing to save"
                } label: { Label("Save to history", systemImage: "tray.and.arrow.down") }
                    .help("Save the current battery state to history")
                    .disabled(device.battery == nil)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report(device), forType: .string)
                    notice = "Report copied"
                } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    .help("Copy a text report to the clipboard")
                Button { sheet = .facts } label: { Label("About device", systemImage: "info.circle") }
                    .help("Device information")
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .details: BatteryDetailsSheet(device: device)
            case .raw: RawDataSheet(device: device)
            case .facts: FactsSheet(device: device)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.notice = nil }
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.title).font(.title2.bold()).lineLimit(1)
                Text(device.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let b = device.battery {
                let tint: Color = b.externalConnected ? .green : .orange
                Label(b.stateText, systemImage: b.externalConnected ? "bolt.fill" : "arrow.down.right")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
    }

    private func capacity(_ b: BatteryInfo) -> some View {
        VStack(spacing: 16) {
            CapacityBar(title: "Battery health", valueText: b.condition.map(localizedCondition) ?? "",
                        fraction: b.displayHealth / 100, color: healthColor(b.displayHealth), label: b.healthText)
            CapacityBar(title: "Charge", valueText: Fmt.mAh(b.currentCapacity),
                        fraction: Double(b.percent) / 100, color: chargeColor(b), label: "\(b.percent)%")
            Text("Health is the same figure as Maximum Capacity in the \(device.osLabel) battery settings. Exact mAh values are under Battery details.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tiles(_ b: BatteryInfo) -> some View {
        var items: [StatTile] = []
        items.append(StatTile(symbol: "arrow.triangle.2.circlepath", title: "Charge cycles",
                              value: "\(b.cycleCount)",
                              detail: b.designCycleCount.map { "rated for \($0)" }))
        items.append(StatTile(symbol: "thermometer.medium", title: "Temperature",
                              value: Fmt.temp(b.temperature),
                              detail: b.lifetime.maxTemp.map { "lifetime max \(Fmt.temp($0))" }))
        items.append(StatTile(symbol: "bolt.fill",
                              title: b.amperage > 0 ? "Charging at" : (b.amperage < 0 ? "Discharging at" : "Power"),
                              value: Fmt.watts(b.watts),
                              detail: "\(Fmt.volts(b.voltage)) · \(b.amperage) mA"))
        if let a = b.adapter {
            items.append(StatTile(symbol: a.isWireless ? "wave.3.right" : "powerplug.fill", title: "Adapter",
                                  value: a.watts.map { "\($0) W" } ?? "Connected", detail: a.name))
        } else {
            items.append(StatTile(symbol: "powerplug", title: "Adapter",
                                  value: b.externalConnected ? "Connected" : "Not connected"))
        }
        if let d = b.manufactureDate {
            items.append(StatTile(symbol: "calendar", title: "Battery manufactured",
                                  value: (b.manufactureDateApprox ? "≈ " : "") + Fmt.date(d),
                                  detail: "age \(Fmt.age(since: d))"))
        } else {
            items.append(StatTile(symbol: "calendar", title: "Battery manufactured", value: "Unknown",
                                  detail: b.firstUseEstimate.map { "in use ≈ \(Fmt.age(since: $0))" }))
        }
        if device.kind == "mac", let m = b.minutesRemaining {
            items.append(StatTile(symbol: "clock", title: b.isCharging ? "Until full" : "Remaining",
                                  value: Fmt.duration(minutes: m), detail: "h:mm, system estimate"))
        }
        if let load = b.systemLoadWatts {
            items.append(StatTile(symbol: "cpu", title: "System power draw", value: Fmt.watts(load),
                                  detail: b.systemInputWatts.map { "adapter input \(Fmt.watts($0))" }))
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { $0.element }
        }
    }

    @ViewBuilder
    private var liveChart: some View {
        let data = model.samples[device.id] ?? []
        if data.count >= 3 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Battery power, W").font(.headline)
                Text("This session: above zero is charging, below is discharging")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(data) { s in
                    AreaMark(x: .value("Time", s.date), y: .value("W", s.watts))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                    LineMark(x: .value("Time", s.date), y: .value("W", s.watts))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 130)
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func footer(_ b: BatteryInfo) -> some View {
        HStack {
            Button("Battery details…") { sheet = .details }
            Button("Raw data…") { sheet = .raw }
            Spacer()
            Text("Updated at \(b.updated.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Sheets

private struct SheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: 560, height: 560)
    }
}

struct FactsSheet: View {
    let device: DevicePresentation

    var body: some View {
        SheetFrame(title: device.title) {
            Form {
                ForEach(Array(device.facts.enumerated()), id: \.offset) { _, fact in
                    LabeledContent(fact.0) { Text(fact.1).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct BatteryDetailsSheet: View {
    let device: DevicePresentation

    var body: some View {
        SheetFrame(title: "Battery details — \(device.title)") {
            if let b = device.battery {
                Form {
                    Section("Identification") {
                        row("Serial number", b.serial)
                        row("Manufactured", b.manufactureDate.map { (b.manufactureDateApprox ? "≈ " : "") + Fmt.date($0) })
                        row("Age", b.manufactureDate.map { Fmt.age(since: $0) })
                        row("In use", b.lifetime.operatingHours.map { h in
                            "\(h) h" + (b.firstUseEstimate.map { " (≈ \(Fmt.age(since: $0)))" } ?? "")
                        })
                        row("Gauge", b.gaugeName)
                        row("Chemistry ID", b.chemID.map(String.init))
                    }
                    Section("Health") {
                        row("Battery health", b.healthText)
                        row("Condition", b.condition.map(localizedCondition))
                        if b.systemHealthEstimated {
                            Text("\(device.osLabel) does not send this figure over the cable, so it is worked out the way the phone does it: nominal capacity divided by the largest capacity the battery ever measured. It may differ from the phone's Settings by 1%.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        row("Current charge", "\(b.currentCapacity) mAh (\(b.percent)%)")
                        row("Full charge capacity now", Fmt.mAh(b.fullChargeCapacity))
                        row("Nominal capacity", b.nominalCapacity.map(Fmt.mAh))
                        row("Largest measured capacity", b.peakCapacity.map(Fmt.mAh))
                        row("Design capacity", Fmt.mAh(b.designCapacity))
                        row("Full charge vs design", Fmt.percent(b.health))
                        row("Cycles", "\(b.cycleCount)" + (b.designCycleCount.map { " of \($0)" } ?? ""))
                        if let lo = b.dailyMinSoc, let hi = b.dailyMaxSoc {
                            row("Charge range today", "from \(lo)% to \(hi)%")
                        }
                    } header: {
                        Text("Capacity, mAh")
                    } footer: {
                        Text("New Apple batteries have headroom above the design value, so \"vs design\" can exceed 100%. Health is calculated differently and never exceeds 100%.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Electrical") {
                        row("State", b.stateText)
                        row("Voltage", Fmt.volts(b.voltage, 3))
                        row("Current", "\(b.amperage) mA")
                        row("Power", Fmt.num(b.watts, 2, signed: true) + " W")
                        if !b.cellVoltages.isEmpty {
                            row("Cell voltages", b.cellVoltages.map { "\($0) mV" }.joined(separator: " · "))
                        }
                        row("System power draw", b.systemLoadWatts.map(Fmt.watts))
                        row("Adapter input", b.systemInputWatts.map(Fmt.watts))
                    }
                    Section("Temperature") {
                        row("Now", Fmt.temp(b.temperature))
                        row("Minimum", b.lifetime.minTemp.map { Fmt.temp($0) })
                        row("Average", b.lifetime.avgTemp.map { Fmt.temp($0) })
                        row("Maximum", b.lifetime.maxTemp.map { Fmt.temp($0) })
                    }
                    Section("Lifetime") {
                        row("Max charge current", b.lifetime.maxChargeCurrent.map { "\($0) mA" })
                        row("Max discharge current", b.lifetime.maxDischargeCurrent.map { "\(abs($0)) mA" })
                        row("Min voltage", b.lifetime.minPackVoltage.map { "\($0) mV" })
                        row("Max voltage", b.lifetime.maxPackVoltage.map { "\($0) mV" })
                    }
                    if let a = b.adapter {
                        Section("Adapter") {
                            row("Name", a.name)
                            row("Power", a.watts.map { "\($0) W" })
                            row("Voltage", a.voltage.map { Fmt.volts($0, 1) })
                            row("Current", a.current.map { "\($0) mA" })
                            row("Type", a.isWireless ? "Wireless" : "Wired")
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No data", systemImage: "battery.0percent")
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) { Text(value).monospacedDigit().textSelection(.enabled) }
        }
    }
}

struct RawDataSheet: View {
    let device: DevicePresentation
    @State private var query = ""

    private var entries: [RawEntry] {
        let all = device.battery?.raw ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SheetFrame(title: "Raw data — \(device.title)") {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search keys or values", text: $query).textFieldStyle(.plain)
                    Text("\(entries.count)").foregroundStyle(.secondary).monospacedDigit()
                    Button("Copy all") {
                        let text = entries.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .padding(10)
                Divider()
                List(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(e.value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(4)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}
