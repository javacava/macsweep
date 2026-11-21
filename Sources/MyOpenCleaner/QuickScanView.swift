import SwiftUI
import SweepCore

struct QuickScanView: View {
    @ObservedObject var state = AppState.shared
    @State private var report: QuickScanReport?
    @State private var busy = false
    @State private var progress = ""
    @State private var done: QuickScanResult?
    @State private var confirm = false
    @AppStorage(AppState.removalModeKey) private var removalMode = RemovalMode.trash.rawValue

    var body: some View {
        ModulePage(module: .quickScan, subtitle: "One scan: junk, threats, app leftovers and maintenance.") {
            EmptyView()
        } content: {
            VStack(spacing: 24) {
                Spacer()
                if busy {
                    ProgressView().controlSize(.large)
                    Text(progress).foregroundStyle(.secondary)
                } else if let done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 70)).foregroundStyle(.green)
                    Text("All done!").font(.largeTitle.bold())
                    Text("Freed \(FileSize.format(done.cleaned.freedBytes)) · tasks run: \(done.tasksRun.values.filter(\.ok).count)"
                         + (done.cleaned.failed.isEmpty ? "" : " · failed: \(done.cleaned.failed.count)"))
                        .foregroundStyle(.secondary)
                    if let n = report?.threats.count, n > 0 {
                        Button("Review launch items (\(n))") { state.selection = .malware }
                    }
                    Button("Scan again", action: scan).controlSize(.large)
                } else if let report {
                    cards(report)
                    if !report.threats.isEmpty {
                        Text("Quick Scan does not remove the launch items it finds: review them under Malware.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if report.reclaimable == 0 && report.dueTasks.isEmpty {
                        Text(report.threats.isEmpty ? "All good, your Mac is in great shape." : "No junk.").font(.title3)
                    } else {
                        Button(action: { confirm = true }) {
                            Text("Run").font(.title3.bold()).frame(width: 160, height: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(.purple)
                    }
                } else {
                    Image(systemName: "sparkles").font(.system(size: 80, weight: .light)).foregroundStyle(.purple.gradient)
                    Text("Welcome to MyOpenCleaner").font(.largeTitle.bold())
                    Text("Start with Quick Scan: everything is scanned at once, and you decide what to clean.")
                        .foregroundStyle(.secondary)
                    Button(action: scan) {
                        Text("Scan").font(.title3.bold()).frame(width: 160, height: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Clean \(FileSize.format(report?.reclaimable ?? 0))?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: run)
        } message: {
            Text((removalMode == RemovalMode.trash.rawValue
                  ? "Caches, logs and other selected junk will be moved to the Trash."
                  : "Caches, logs and other selected junk will be deleted permanently.")
                 + " Whatever is already in the Trash is deleted for good. See System Junk for the full list.")
        }
    }

    func cards(_ r: QuickScanReport) -> some View {
        HStack(spacing: 16) {
            card(.junk, "Cleanup", FileSize.format(r.reclaimable), "junk to remove") { state.selection = .junk }
            card(.malware, "Protection", r.threats.isEmpty ? "Clean" : "\(r.threats.count)",
                 r.threats.isEmpty ? "no threats found" : "items to review") { state.selection = .malware }
            card(.maintenance, "Performance", "\(r.dueTasks.count)", "maintenance tasks") { state.selection = .maintenance }
            card(.leftovers, "Applications", FileSize.format(r.orphanLeftovers.reduce(0) { $0 + $1.size }),
                 "leftovers of removed apps") { state.selection = .leftovers }
        }
        .padding(.horizontal, 30)
    }

    func card(_ m: Module, _ title: String, _ value: String, _ caption: String, open: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: m.symbol).font(.title).foregroundStyle(m.tint)
            Text(title).font(.headline)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Details", action: open).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity).padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    func scan() {
        busy = true; done = nil; report = nil
        let env = state.env, last = state.activity.state.lastMaintenance
        Task {
            let r = await AppState.background {
                QuickScan(env: env).scan(lastMaintenance: last) { msg in
                    Task { @MainActor in progress = msg }
                }
            }
            report = r; busy = false
        }
    }

    func run() {
        guard let report else { return }
        busy = true; progress = "Cleaning…"
        let env = state.env, mode = state.removalMode
        Task {
            let r = await AppState.background { QuickScan(env: env).run(report, mode: mode) }
            state.record(.quickScan, r.cleaned)
            state.activity.markMaintenance(r.tasksRun.filter { $0.value.ok }.map(\.key))
            done = r; busy = false
        }
    }
}
