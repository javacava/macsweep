import SwiftUI
import SweepCore

/// Polls CPU, memory, disk and network every couple of seconds for the menu bar and the Monitor page.
@MainActor
final class MonitorModel: ObservableObject {
    static let shared = MonitorModel()

    @Published var cpu: Double = 0
    @Published var memory: MemoryStats?
    @Published var swap: SwapStats?
    @Published var disk: DiskStats?
    @Published var downPerSec: Double = 0
    @Published var upPerSec: Double = 0
    @Published var topCPU: [ProcessUsage] = []
    @Published var topMemory: [ProcessUsage] = []
    @Published var cpuHistory: [Double] = []

    private var lastTicks: CPUTicks?
    private var lastNet: (NetworkCounters, Date)?
    private var timer: Timer?

    func start() {
        if let demo = Demo.active {
            // Screenshot mode: fixed figures, no polling of the real Mac.
            cpu = 0.31; memory = demo.memory; swap = demo.swap; disk = demo.disk; downPerSec = 2_400_000; upPerSec = 310_000
            cpuHistory = demo.cpuHistory
            let all = SystemMonitor.parseProcesses(demo.runner.run("/bin/ps", []).output)
            topCPU = Array(all.sorted { $0.cpu > $1.cpu }.prefix(5))
            topMemory = Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(5))
            return
        }
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in MonitorModel.shared.tick() } }
    }

    func tick() {
        if let t = SystemMonitor.cpuTicks() {
            if let last = lastTicks { cpu = CPUTicks.usage(from: last, to: t) }
            lastTicks = t
            cpuHistory.append(cpu)
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        }
        memory = SystemMonitor.memory()
        swap = SystemMonitor.swap()
        disk = SystemMonitor.disk()
        let net = SystemMonitor.network(), now = Date()
        if let (prev, at) = lastNet, now > at, net.received >= prev.received, net.sent >= prev.sent {
            let dt = now.timeIntervalSince(at)
            downPerSec = Double(net.received - prev.received) / dt
            upPerSec = Double(net.sent - prev.sent) / dt
        }
        lastNet = (net, now)
        Task {
            let (c, m) = await AppState.background { () -> ([ProcessUsage], [ProcessUsage]) in
                let all = SystemMonitor.topProcesses(limit: .max)   // one `ps` run for both lists
                return (Array(all.prefix(5)), Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(5)))
            }
            topCPU = c; topMemory = m
        }
    }

    static func rate(_ bytesPerSec: Double) -> String { FileSize.format(Int64(bytesPerSec)) + "/s" }
}

struct MonitorView: View {
    @ObservedObject var m = MonitorModel.shared
    @ObservedObject var state = AppState.shared

    var body: some View {
        ModulePage(module: .monitor, subtitle: "CPU load, memory, disk, network and the heaviest processes, live.") {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 30) {
                        GaugeRing(fraction: m.cpu, label: "CPU", value: "\(Int(m.cpu * 100))%", tint: .blue)
                        if let mem = m.memory {
                            GaugeRing(fraction: mem.usedFraction, label: "Memory · \(pressureTitle(mem.pressure))",
                                      value: "\(Int(mem.usedFraction * 100))%", tint: pressureColor(mem.pressure))
                        }
                        if let d = m.disk {
                            VStack(spacing: 2) {
                                GaugeRing(fraction: d.usedFraction, label: "\(FileSize.format(d.available)) free",
                                          value: "\(Int(d.usedFraction * 100))%", tint: .teal)
                                if d.purgeable > 0 {
                                    Text("incl. \(FileSize.format(d.purgeable)) purgeable")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .help("Caches and local Time Machine snapshots macOS frees by itself when space runs low. Thin Time Machine snapshots under Maintenance to free it now.")
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label(MonitorModel.rate(m.downPerSec), systemImage: "arrow.down.circle")
                            Label(MonitorModel.rate(m.upPerSec), systemImage: "arrow.up.circle")
                        }
                        .font(.callout.monospacedDigit())
                    }
                    Sparkline(values: m.cpuHistory).frame(height: 60)
                    if let mem = m.memory { MemoryBreakdown(memory: mem, swap: m.swap) }
                    HStack(alignment: .top, spacing: 30) {
                        ProcessTable(title: "Top CPU", rows: m.topCPU, value: { String(format: "%.1f%%", $0.cpu) })
                        ProcessTable(title: "Top memory", rows: m.topMemory, value: { FileSize.format(Int64($0.memoryBytes)) })
                    }
                    ActivitySummary().id(state.activityVersion)
                }
                .padding(24)
            }
        }
        .onAppear { m.start() }
    }
}

func pressureTitle(_ p: MemoryStats.Pressure) -> String {
    switch p { case .normal: "normal"; case .warning: "elevated pressure"; case .critical: "critical" }
}

func pressureColor(_ p: MemoryStats.Pressure) -> Color {
    switch p { case .normal: .green; case .warning: .orange; case .critical: .red }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                     y: g.size.height * (1 - CGFloat(v)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(.blue.gradient, lineWidth: 2)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProcessTable: View {
    let title: String
    let rows: [ProcessUsage]
    let value: (ProcessUsage) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(value(p)).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        NSRunningApplication(processIdentifier: p.pid)?.terminate()
                    } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Quit")
                    .disabled(NSRunningApplication(processIdentifier: p.pid) == nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActivitySummary: View {
    let log = AppState.shared.activity
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CleanHistoryList()
            Text("Activity").font(.headline)
            HStack(spacing: 30) {
                stat("Freed in total", FileSize.format(log.totalFreed))
                stat("Last 30 days", FileSize.format(log.freed(since: Date().addingTimeInterval(-30 * 86_400))))
                stat("Cleanups", "\(log.state.entries.count)")
            }
            ForEach(log.state.entries.suffix(5).reversed()) { e in
                HStack {
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Text(e.module)
                    Spacer()
                    Text(FileSize.format(e.freedBytes)).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var m = MonitorModel.shared
    @ObservedObject var battery = BatteryModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var freeing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MyOpenCleaner").font(.headline)
                Spacer()
                Button("Open") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            row("cpu", "CPU", "\(Int(m.cpu * 100))%", m.cpu, .blue)
            if let mem = m.memory {
                row("memorychip", "Memory (\(pressureTitle(mem.pressure)))",
                    "\(FileSize.format(Int64(mem.used))) of \(FileSize.format(Int64(mem.total)))", mem.usedFraction, pressureColor(mem.pressure))
            }
            if let d = m.disk {
                row("internaldrive", "Disk", "\(FileSize.format(d.available)) free", d.usedFraction, .teal)
            }
            if let b = battery.macBattery {
                row(batterySymbol(percent: b.percent, charging: b.isCharging), "Battery · health \(b.healthText)",
                    "\(b.percent)% · \(b.stateText.lowercased())", Double(b.percent) / 100, chargeColor(b))
            }
            HStack {
                Label(MonitorModel.rate(m.downPerSec), systemImage: "arrow.down")
                Spacer()
                Label(MonitorModel.rate(m.upPerSec), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            Divider()
            Text("Heaviest apps").font(.caption).foregroundStyle(.secondary)
            ForEach(m.topCPU.prefix(4)) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    if let app = NSRunningApplication(processIdentifier: p.pid), app.activationPolicy == .regular {
                        Button("Quit") { app.terminate() }.controlSize(.small)
                    }
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Button(freeing ? "Freeing…" : "Free up memory") {
                    freeing = true
                    Task {
                        let task = MaintenanceTask.all.first { $0.id == "free-ram" }!
                        let runner = AppState.shared.runner
                        _ = await AppState.background { MaintenanceRunner(runner: runner).run([task]) }
                        freeing = false
                        m.tick()
                    }
                }
                .disabled(freeing)
                Spacer()
                Button("Quit MyOpenCleaner") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { m.start(); battery.start() }
    }

    func row(_ symbol: String, _ title: String, _ value: String, _ fraction: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var m = MonitorModel.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text("\(Int(m.cpu * 100))%").monospacedDigit()
        }
        .onAppear { m.start() }
    }
}

/// Recent cleans, each with a Restore button while its items are still in the Trash.
struct CleanHistoryList: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        let entries = Array(state.history.entries.prefix(8))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean history").font(.headline)
                ForEach(entries) { e in
                    let restorable = state.history.restorableCount(e)
                    HStack {
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text(e.module)
                        Text("\(e.removedCount) \(e.removedCount == 1 ? "item" : "items") · \(FileSize.format(e.freedBytes))").foregroundStyle(.secondary)
                        Spacer()
                        if e.restoredAt != nil {
                            Text("Restored").foregroundStyle(.secondary)
                        } else if restorable > 0 {
                            Button("Restore \(restorable)") { state.undo(e) }.controlSize(.small)
                        } else {
                            Text(e.permanentCount == e.removedCount ? "Deleted for good" : "Trash emptied")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
            }
            .id(state.activityVersion)
            .padding(.bottom, 10)
        }
    }
}

/// Where the memory goes, as one bar, and how much has spilled to the swap file on disk.
struct MemoryBreakdown: View {
    let memory: MemoryStats
    let swap: SwapStats?

    var parts: [(label: String, bytes: UInt64, color: Color, help: String)] {
        [("Apps", memory.appMemory, .blue, "Memory your apps are using"),
         ("Wired", memory.wired, .purple, "Memory macOS itself needs and cannot move"),
         ("Compressed", memory.compressed, .orange, "Memory squeezed in place to avoid swapping"),
         ("Cached files", memory.purgeable + memory.external, .teal, "Recently read files, dropped first when memory is needed")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory").font(.headline)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.label) { p in
                        Rectangle().fill(p.color.gradient)
                            .frame(width: max(geo.size.width * CGFloat(p.bytes) / CGFloat(max(memory.total, 1)) - 2, 0))
                            .help("\(p.label): \(FileSize.format(Int64(p.bytes))) · \(p.help)")
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            HStack(spacing: 16) {
                ForEach(parts, id: \.label) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text("\(p.label) \(FileSize.format(Int64(p.bytes)))").font(.caption.monospacedDigit())
                    }
                    .help(p.help)
                }
                Spacer()
                Text("of \(FileSize.format(Int64(memory.total)))").font(.caption).foregroundStyle(.secondary)
            }
            if let swap {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Swap \(FileSize.format(Int64(swap.used)))", systemImage: "arrow.left.arrow.right.square")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Double(swap.used) / Double(max(memory.total, 1)) >= 0.1 ? .orange : .primary)
                    Text(swap.advice(physicalMemory: memory.total)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
