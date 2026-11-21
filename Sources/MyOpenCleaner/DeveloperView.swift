import SwiftUI
import SweepCore

struct DeveloperView: View {
    @ObservedObject var state = AppState.shared
    @AppStorage(AppState.removalModeKey) private var removalMode = RemovalMode.trash.rawValue
    @State private var items: [DevItem]?
    @State private var selected = Set<String>()
    @State private var expanded: Set<DevItem.Group> = []
    @State private var busy = false
    @State private var progress = ""
    @State private var projectsRoot: URL?
    @State private var docker: DockerCleaner.State = .notInstalled
    @State private var dockerSelected = Set(DockerPrune.allCases.filter(\.selectedByDefault))
    @State private var confirm = false
    @State private var confirmDocker = false
    @State private var message: String?

    var chosen: [DevItem] { items?.filter { selected.contains($0.id) } ?? [] }
    var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.size } }
    var hasCommands: Bool { chosen.contains { if case .command = $0.removal { true } else { false } } }

    var body: some View {
        ModulePage(module: .developer, subtitle: "Simulators and emulators, Xcode firmware, npm and other package caches, project builds, Docker junk.") {
            Button(projectsRoot.map { "Projects: \($0.lastPathComponent)" } ?? "Projects folder…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                p.message = "Where to look for node_modules, .build, target and other builds"
                if p.runModal() == .OK { projectsRoot = p.url }
            }
            .help("By default, your whole home folder")
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if busy && items == nil {
                StateView(symbol: "", title: "Scanning…", message: progress, busy: true)
            } else if let items {
                VStack(spacing: 0) {
                    List {
                        ForEach(DevItem.Group.allCases) { group in
                            let rows = items.filter { $0.group == group }
                            if !rows.isEmpty { section(group, rows) }
                        }
                        dockerSection
                        if items.isEmpty {
                            Text("No developer clutter found.").foregroundStyle(.secondary)
                        }
                    }
                    ActionBar(selectedCount: chosen.count, selectedSize: chosenSize, buttonTitle: "Clean", busy: busy) { confirm = true }
                }
            } else {
                StateView(symbol: "hammer", title: "Free up space taken by developer tools",
                          message: "Nothing is removed unless you choose it. Simulators, runtimes and project builds start unselected.",
                          buttonTitle: "Scan", action: scan)
            }
        }
        .confirmationDialog("Clean \(FileSize.format(chosenSize))?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: clean)
        } message: {
            Text((removalMode == RemovalMode.trash.rawValue ? "Files and folders will be moved to the Trash." : "Files and folders will be deleted permanently.")
                 + (hasCommands ? " Simulators and runtimes are deleted at once and for good (through simctl)." : ""))
        }
        .confirmationDialog("Clean up Docker?", isPresented: $confirmDocker) {
            Button("Clean", role: .destructive, action: pruneDocker)
        } message: {
            Text(dockerSelected.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ")
                 + (dockerSelected.contains(where: \.dangerous) ? ". Warning: some selected items lose data that cannot be restored." : "."))
        }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func section(_ group: DevItem.Group, _ rows: [DevItem]) -> some View {
        let ids = Set(rows.map(\.id))
        let all = Binding(get: { ids.isSubset(of: selected) },
                          set: { on in if on { selected.formUnion(ids) } else { selected.subtract(ids) } })
        return DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group) },
                                                   set: { if $0 { expanded.insert(group) } else { expanded.remove(group) } })) {
            Text(group.hint).font(.caption).foregroundStyle(.secondary)
            if group == .builds {
                Button("Select projects unchanged for over 30 days") {
                    let cutoff = Date().addingTimeInterval(-30 * 86_400)
                    selected.formUnion(rows.filter { ($0.lastUsed ?? .distantFuture) < cutoff }.map(\.id))
                }
                .controlSize(.small)
            }
            if group == .simulators {
                Button("Select those not launched for over 90 days") {
                    let cutoff = Date().addingTimeInterval(-90 * 86_400)
                    selected.formUnion(rows.filter { ($0.lastUsed ?? .distantPast) < cutoff }.map(\.id))
                }
                .controlSize(.small)
            }
            ForEach(rows.prefix(300)) { item in row(item) }
            if rows.count > 300 { Text("…\(rows.count - 300) more").foregroundStyle(.secondary) }
        } label: {
            HStack {
                Toggle("", isOn: all).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: group.symbol).frame(width: 22).foregroundStyle(Module.developer.tint)
                Text(group.title).font(.headline)
                Text("\(rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SizeText(bytes: rows.reduce(0) { $0 + $1.size })
            }
        }
    }

    func row(_ item: DevItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: member($selected, item.id)).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Text(item.detail + (item.lastUsed.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SizeText(bytes: item.size)
            if let url = item.location {
                Button { AppState.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var dockerSection: some View {
        switch docker {
        case .notInstalled:
            EmptyView()
        case .notRunning:
            Section("Docker") {
                Label("Docker is installed but not running. Start Docker Desktop and press Scan to see what can be cleaned up.",
                      systemImage: "shippingbox").font(.callout).foregroundStyle(.secondary)
            }
        case .ready(let usage):
            Section("Docker") {
                ForEach(usage) { u in
                    HStack {
                        Text(u.type)
                        Text("\(u.total), active \(u.active)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(FileSize.format(u.reclaimable)) reclaimable of \(FileSize.format(u.size))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ForEach(DockerPrune.allCases) { p in
                    Toggle(isOn: Binding(get: { dockerSelected.contains(p) },
                                         set: { if $0 { dockerSelected.insert(p) } else { dockerSelected.remove(p) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).foregroundStyle(p.dangerous ? .red : .primary)
                            Text(p.details).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button("Clean up Docker") { confirmDocker = true }
                    .disabled(dockerSelected.isEmpty || busy)
            }
        }
    }

    func scan() {
        busy = true; items = nil
        let env = state.env, roots = projectsRoot.map { [$0] }
        Task {
            progress = "Xcode, firmware, package caches…"
            let folders = await AppState.background { DevFolderScanner(env: env).scan() }
            progress = "Simulators…"
            let sims = await AppState.background { SimulatorScanner(env: env).scan() }
            progress = "Project builds…"
            let builds = await AppState.background { BuildArtifactFinder(env: env).find(roots: roots) }
            progress = "Docker…"
            docker = await AppState.background { DockerCleaner().state() }
            let all = (folders + sims + builds).sorted { $0.size > $1.size }
            items = all
            selected = Set(all.filter(\.selectedByDefault).map(\.id))
            busy = false
        }
    }

    func clean() {
        busy = true
        let targets = chosen, env = state.env, cleaner = state.cleaner()
        Task {
            let r = await AppState.background { DevCleaner(env: env, cleaner: cleaner).remove(targets) }
            state.record(.developer, r)
            message = cleanSummary(r)
            busy = false
            scan()
        }
    }

    func pruneDocker() {
        busy = true
        let kinds = DockerPrune.allCases.filter(dockerSelected.contains)
        Task {
            let (results, reclaimed) = await AppState.background { DockerCleaner().prune(kinds) }
            let failed = results.filter { !$0.value.ok }
            if reclaimed > 0 {
                state.activity.record(module: "Docker", freed: reclaimed, items: kinds.count - failed.count)
                state.activityVersion += 1
            }
            message = "Docker: freed \(FileSize.format(reclaimed))."
                + (failed.isEmpty ? "" : "\nFailed: " + failed.map { "\($0.key.title) (\($0.value.error.trimmingCharacters(in: .whitespacesAndNewlines)))" }.joined(separator: "; "))
            docker = await AppState.background { DockerCleaner().state() }
            busy = false
        }
    }
}
