import SwiftUI
import SweepCore

struct MaintenanceView: View {
    @ObservedObject var state = AppState.shared
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var results: [String: CommandResult] = [:]
    private let tasks = MaintenanceTask.available()

    var body: some View {
        ModulePage(module: .maintenance, subtitle: "System routines that speed up the Mac and fix small glitches.") {
            Button("Recommended") {
                selected = Set(MaintenanceRunner.due(lastRun: state.activity.state.lastMaintenance, now: Date(), among: tasks)
                    .filter(\.automatic).map(\.id))
            }
            .help("Selects only light tasks with no side effects")
        } content: {
            VStack(spacing: 0) {
                List(tasks) { t in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("", isOn: member($selected, t.id)).labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: t.symbol).font(.title2).frame(width: 30).foregroundStyle(Module.maintenance.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.title).font(.headline)
                                if t.needsAdmin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Needs an administrator password") }
                            }
                            Text(t.details).font(.callout).foregroundStyle(.secondary)
                            if let last = state.activity.state.lastMaintenance[t.id] {
                                Text("Last run: \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if let r = results[t.id] {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.ok ? .green : .red).help(r.ok ? "Done" : r.error)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Text("Tasks marked 🔒 ask for the password once, together.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: run) {
                        if busy { ProgressView().controlSize(.small) } else { Text("Run (\(selected.count))") }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(selected.isEmpty || busy)
                }
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .onAppear {
            if selected.isEmpty {
                selected = Set(MaintenanceRunner.due(lastRun: state.activity.state.lastMaintenance, now: Date(), among: tasks)
                    .filter { $0.automatic && !$0.needsAdmin }.map(\.id))
            }
        }
    }

    func run() {
        busy = true
        let chosen = tasks.filter { selected.contains($0.id) }, runner = state.runner
        Task {
            let r = await AppState.background { MaintenanceRunner(runner: runner).run(chosen) }
            results = r
            state.activity.markMaintenance(r.filter { $0.value.ok }.map(\.key))
            state.activityVersion += 1
            busy = false
        }
    }
}

struct LaunchItemsView: View {
    @ObservedObject var state = AppState.shared
    @State private var items: [LaunchItem] = []
    @State private var disabled = Set<String>()
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        ModulePage(module: .launchItems, subtitle: "Agents and daemons that start on their own. Turn off the ones you do not need so the Mac starts faster.") {
            Button("Login Items…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            Button("Refresh", action: load)
        } content: {
            if loading && items.isEmpty {
                StateView(symbol: "", title: "Reading…", busy: true)
            } else {
                List {
                    ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                        let group = items.filter { $0.scope == scope }
                        if !group.isEmpty {
                            Section("\(scope.title) · \(scope.folder)") {
                                ForEach(group) { item in row(item) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .alert("Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func row(_ item: LaunchItem) -> some View {
        let on = !disabled.contains(item.label) && !item.disabledInPlist
        return HStack {
            Image(systemName: "gearshape").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1)
                Text(item.program ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.keepAlive { Text("always on").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
            if item.runAtLoad { Text("at login").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
            Button { AppState.reveal(item.plist) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            Toggle("", isOn: Binding(get: { on }, set: { toggle(item, $0) })).labelsHidden().toggleStyle(.switch)
        }
    }

    func load() {
        loading = true
        let env = state.env, runner = state.runner
        Task {
            let (i, d) = await AppState.background { () -> ([LaunchItem], Set<String>) in
                let m = LaunchItemsManager(env: env, runner: runner)
                return (m.items(), m.disabledLabels())
            }
            items = i; disabled = d; loading = false
        }
    }

    func toggle(_ item: LaunchItem, _ on: Bool) {
        let env = state.env, runner = state.runner
        Task {
            let r = await AppState.background { LaunchItemsManager(env: env, runner: runner).setEnabled(item, on) }
            if !r.ok { message = r.error.isEmpty ? "launchctl exited with code \(r.status)" : r.error }
            load()
        }
    }
}
