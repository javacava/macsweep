import SwiftUI
import SweepCore

/// Shared app list, loaded once.
@MainActor
final class AppsStore: ObservableObject {
    static let shared = AppsStore()
    @Published var apps: [AppInfo] = []
    @Published var loading = false

    func load(force: Bool = false) {
        guard force || apps.isEmpty, !loading else { return }
        loading = true
        let env = AppState.shared.env
        Task {
            apps = await AppState.background { AppScanner.installedApps(env: env) }
            loading = false
        }
    }
}

struct UninstallerView: View {
    @ObservedObject var store = AppsStore.shared
    @ObservedObject var state = AppState.shared
    @State private var search = ""
    @State private var picked: AppInfo?
    @State private var plan: UninstallPlan?
    @State private var selectedLeftovers = Set<String>()
    @State private var removeApp = true
    @State private var inUse: String?
    @State private var confirm = false
    @State private var busy = false
    @State private var message: String?
    @State private var hideApple = true

    var filtered: [AppInfo] {
        store.apps.filter { (!hideApple || !$0.isApple) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = plan.map { $0.targets(includingApp: removeApp, selectedLeftovers: selectedLeftovers).map(\.url) } ?? []
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .uninstaller, subtitle: "Remove apps together with all their files, or reset them to a clean state.") {
            Toggle("Hide Apple apps", isOn: $hideApple).toggleStyle(.checkbox)
            Button("Refresh") { store.load(force: true) }
        } content: {
            HSplitView {
                List(filtered, selection: Binding(get: { picked?.id }, set: { id in pick(store.apps.first { $0.id == id }) })) { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(app.id)
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Search apps")
                .frame(minWidth: 220, idealWidth: 260)
                detail.frame(minWidth: 380)
            }
        }
        .onAppear { store.load() }
        .onChange(of: store.apps) { if AppState.shared.autoScan, picked == nil, let a = store.apps.first(where: { $0.name == "PixelPaint" }) { pick(a) } }
        .confirmationDialog(removeApp ? "Remove \(picked?.name ?? "")?" : "Reset \(picked?.name ?? "")?", isPresented: $confirm) {
            Button(removeApp ? "Remove" : "Reset", role: .destructive, action: uninstall)
        } message: {
            Text((inUse.map { $0 + "\n\n" } ?? "") + (removeApp ? "The app and the selected leftovers will be removed." : "The app's settings and data will be removed; the app itself stays."))
        }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    @ViewBuilder var detail: some View {
        if let app = picked {
            if let plan, plan.app == app {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.title3.bold())
                            Text("\(app.bundleID) · \(app.version)").font(.caption).foregroundStyle(.secondary)
                            if app.isAppStore { Text("From the App Store").font(.caption).foregroundStyle(.blue) }
                        }
                        Spacer()
                        Picker("", selection: $removeApp) {
                            Text("Remove").tag(true)
                            Text("Reset").tag(false)
                        }
                        .pickerStyle(.segmented).frame(width: 180)
                    }
                    .padding()
                    List {
                        if removeApp {
                            HStack {
                                Image(systemName: "checkmark.square.fill").foregroundStyle(.blue)
                                Text("\(app.name).app"); Spacer(); SizeText(bytes: plan.appSize)
                            }
                        }
                        Section {
                            ForEach(plan.leftovers) { l in
                                FileRow(isOn: member($selectedLeftovers, l.id), url: l.url, detail: l.location, size: l.size)
                            }
                        } header: {
                            HStack {
                                Text("Related files (\(plan.leftovers.count))")
                                Spacer()
                                Toggle("Select all", isOn: Binding(
                                    get: { !plan.leftovers.isEmpty && Set(plan.leftovers.map(\.id)).isSubset(of: selectedLeftovers) },
                                    set: { on in
                                        if on { selectedLeftovers.formUnion(plan.leftovers.map(\.id)) }
                                        else { selectedLeftovers.subtract(plan.leftovers.map(\.id)) }
                                    }))
                                .toggleStyle(.checkbox).font(.callout)
                            }
                        }
                    }
                    let size = (removeApp ? plan.appSize : 0) + plan.leftovers.filter { selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
                    ActionBar(selectedCount: selectedLeftovers.count + (removeApp ? 1 : 0), selectedSize: size,
                              buttonTitle: removeApp ? "Remove" : "Reset", busy: busy) { askConfirm() }
                }
                .disabled(app.isApple)
                .overlay { if app.isApple { Text("Apple apps are protected").padding().background(.regularMaterial, in: Capsule()) } }
            } else {
                StateView(symbol: "", title: "Looking for related files…", busy: true)
            }
        } else {
            StateView(symbol: "xmark.app", title: "Choose an app", message: "Shows the app and every file it keeps in the Library folders.")
        }
    }

    func pick(_ app: AppInfo?) {
        picked = app
        plan = nil
        guard let app else { return }
        let env = state.env
        Task {
            let p = await AppState.background { Uninstaller.plan(for: app, env: env) }
            if picked == app { plan = p; selectedLeftovers = Set(p.leftovers.map(\.id)) }
        }
    }

    func uninstall() {
        guard let plan else { return }
        // Also for "reset": pulling the data from under a running app corrupts it.
        if NSRunningApplication.runningApplications(withBundleIdentifier: plan.app.bundleID).first != nil {
            message = "Quit \(plan.app.name) first."
            return
        }
        busy = true
        let targets = plan.targets(includingApp: removeApp, selectedLeftovers: selectedLeftovers)
        let cleaner = state.cleaner()
        let wasRemoving = removeApp
        Task {
            let report = await AppState.background { cleaner.remove(targets) }
            state.record(.uninstaller, report)
            message = cleanSummary(report)
            busy = false
            if wasRemoving { picked = nil; store.load(force: true) } else { pick(plan.app) }
        }
    }
}

struct LeftoversView: View {
    @ObservedObject var state = AppState.shared
    @State private var items: [Leftover]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    var chosen: [Leftover] { items?.filter { selected.contains($0.id) } ?? [] }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = chosen.map(\.url)
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .leftovers, subtitle: "Files of apps that are already gone but whose settings and caches stayed behind.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let items {
                if items.isEmpty {
                    StateView(symbol: "checkmark.seal", title: "No leftovers found")
                } else {
                    VStack(spacing: 0) {
                        SelectAllBar(ids: items.map(\.id), size: items.reduce(0) { $0 + $1.size }, selected: $selected,
                                     note: "Check the list: some files belong to tools that have no separate .app.")
                        Divider()
                        List(items) { l in
                            FileRow(isOn: member($selected, l.id), url: l.url, detail: l.location, size: l.size)
                        }
                        ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.size },
                                  buttonTitle: "Remove", busy: busy) { askConfirm() }
                    }
                }
            } else {
                StateView(symbol: "puzzlepiece.extension", title: busy ? "Searching…" : "Find leftovers of removed apps",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, items == nil, !busy { scan() } }
        .confirmationDialog("Remove \(chosen.count) items?", isPresented: $confirm) {
            Button("Remove", role: .destructive, action: clean)
        } message: { if let inUse { Text(inUse) } }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; items = nil
        let env = state.env, runner = state.runner
        Task {
            let r = await AppState.background {
                // Spotlight knows apps outside /Applications too (other folders, external disks).
                LeftoverFinder(env: env).orphans(installed: AppScanner.installedApps(env: env),
                                                 extraBundleIDs: AppScanner.spotlightBundleIDs(runner: runner))
            }
            items = r; selected = []; busy = false
        }
    }

    func clean() {
        busy = true
        let targets = chosen.map { ($0.url, $0.size) }
        let cleaner = state.cleaner()
        Task {
            let report = await AppState.background { cleaner.remove(targets) }
            state.record(.leftovers, report)
            message = cleanSummary(report)
            scan()
        }
    }
}

struct UpdaterView: View {
    @ObservedObject var store = AppsStore.shared
    @State private var updates: [AppUpdate]?
    @State private var checking = false
    @State private var checked = 0

    var candidates: [AppInfo] { store.apps.filter { $0.feedURL != nil } }
    var appStoreApps: [AppInfo] { store.apps.filter(\.isAppStore) }

    var body: some View {
        ModulePage(module: .updater, subtitle: "Checks for updates of apps that update through Sparkle, and points to the App Store for the rest.") {
            Button("Check", action: check).disabled(checking || store.loading)
        } content: {
            if checking {
                StateView(symbol: "", title: "Checking \(checked) of \(candidates.count)…", busy: true)
            } else if let updates {
                List {
                    Section("Available updates (\(updates.count))") {
                        if updates.isEmpty { Text("All apps are up to date").foregroundStyle(.secondary) }
                        ForEach(updates) { u in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.app.url.path)).resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading) {
                                    Text(u.app.name)
                                    Text("\(u.app.version) → \(u.latest.displayVersion)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open app") { NSWorkspace.shared.open(u.app.url) }
                                    .help("The app offers the update through its built-in Sparkle")
                                if let url = u.latest.safeDownloadURL {
                                    Button("Download") { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                    if !appStoreApps.isEmpty {
                        Section("From the App Store (\(appStoreApps.count))") {
                            Button("Open updates in the App Store") {
                                NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
                            }
                        }
                    }
                }
            } else {
                StateView(symbol: "arrow.down.app", title: "Find outdated apps",
                          message: "\(candidates.count) apps with a Sparkle update feed will be checked.",
                          buttonTitle: "Check", action: check)
            }
        }
        .onAppear { store.load() }
    }

    func check() {
        checking = true; checked = 0
        let apps = candidates
        Task {
            var found: [AppUpdate] = []
            await withTaskGroup(of: AppUpdate?.self) { group in
                for app in apps { group.addTask { await UpdateChecker.check(app) } }
                for await r in group {
                    checked += 1
                    if let r { found.append(r) }
                }
            }
            updates = found.sorted { $0.app.name < $1.app.name }
            checking = false
        }
    }
}
