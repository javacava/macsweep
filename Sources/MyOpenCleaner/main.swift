import SwiftUI
import SweepCore

// `MyOpenCleaner --scan` prints what the junk scanner finds and exits (nothing is deleted).
if CommandLine.arguments.contains("--scan") {
    let env = SweepEnvironment.live
    let r = JunkScanner(env: env).scan()
    for c in r.categories {
        print(c.title.padding(toLength: 32, withPad: " ", startingAt: 0) + FileSize.format(r.size(of: c)) + "  (\(r.items(in: c).count))")
    }
    print("Total: \(FileSize.format(r.totalSize)); unreadable folders: \(r.unreadable.count)")
    let items = LaunchItemsManager(env: env).items()
    let threats = MalwareScanner(env: env).scan(items)
    print("Launch items: \(items.count), threats/suspicious/broken: \(threats.count)")
    for t in threats { print("  [\(t.level.title)] \(t.item.label): \(t.reasons.joined(separator: "; "))") }
    exit(0)
}

// `MyOpenCleaner --dev-scan` prints what the Developer page would offer and exits (nothing is deleted).
if CommandLine.arguments.contains("--dev-scan") {
    let env = SweepEnvironment.live
    let items = DevFolderScanner(env: env).scan() + SimulatorScanner(env: env).scan() + BuildArtifactFinder(env: env).find()
    for g in DevItem.Group.allCases {
        let rows = items.filter { $0.group == g }.sorted { $0.size > $1.size }
        guard !rows.isEmpty else { continue }
        print("\(g.title): \(FileSize.format(rows.reduce(0) { $0 + $1.size })) (\(rows.count))")
        for r in rows.prefix(8) { print("   \(r.selectedByDefault ? "[x]" : "[ ]") \(FileSize.format(r.size))\t\(r.title) — \(r.detail)") }
    }
    switch DockerCleaner().state() {
    case .notInstalled: print("Docker: not installed")
    case .notRunning: print("Docker: not running")
    case .ready(let u): for x in u { print("Docker \(x.type): \(FileSize.format(x.reclaimable)) of \(FileSize.format(x.size))") }
    }
    exit(0)
}

AppState.registerDefaults()
Prefs.registerDefaults()

// `MyOpenCleaner --snapshot <dir>` renders every module page to PNG (for checking the UI without a screen grab).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated { Snapshotter.run(into: dir) }
}

MyOpenCleanerApp.main()

@MainActor
enum Snapshotter {
    static func run(into dir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: RootView().frame(width: 1100, height: 720))
        window.orderFrontRegardless()
        var modules = Module.allCases.makeIterator()
        func next() {
            guard let m = modules.next() else { exit(0) }
            AppState.shared.selection = m
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(m.rawValue).png"))
                next()
            }
        }
        next()
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon are queued in the Shredder (never shredded without confirmation).
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        ShredderQueue.shared.add(files)
        AppState.shared.selection = .shredder
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppState.shared.showMenuBar
    }
}

struct MyOpenCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppState.showMenuBarKey) private var showMenuBar = true

    var body: some Scene {
        Window("MyOpenCleaner", id: "main") {
            RootView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuPanel()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

struct RootView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(Module.sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { m in
                            Label { Text(m.title) } icon: { Image(systemName: m.symbol).foregroundStyle(m.tint) }
                                .tag(m)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch state.selection ?? .quickScan {
            case .quickScan: QuickScanView()
            case .junk: JunkView()
            case .developer: DeveloperView()
            case .cloud: CloudView()
            case .malware: MalwareView()
            case .privacy: PrivacyView()
            case .shredder: ShredderView()
            case .maintenance: MaintenanceView()
            case .launchItems: LaunchItemsView()
            case .uninstaller: UninstallerView()
            case .updater: UpdaterView()
            case .leftovers: LeftoversView()
            case .largeOld: LargeOldView()
            case .duplicates: DuplicatesView()
            case .similar: SimilarView()
            case .spaceMap: SpaceMapView()
            case .monitor: MonitorView()
            case .battery: BatteryView()
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppState.removalModeKey) private var removalMode = RemovalMode.trash.rawValue
    @AppStorage(AppState.showMenuBarKey) private var showMenuBar = true
    @AppStorage(Prefs.fahrenheit) private var fahrenheit = false
    @AppStorage(Prefs.autoHistory) private var autoHistory = true

    var body: some View {
        Form {
            Picker("Removed files", selection: $removalMode) {
                Text("Move to Trash (safe)").tag(RemovalMode.trash.rawValue)
                Text("Delete permanently").tag(RemovalMode.permanent.rawValue)
            }
            Toggle("Show the monitor in the menu bar", isOn: $showMenuBar)
            Section("Battery") {
                Picker("Temperature", selection: $fahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Record battery health to history once a day", isOn: $autoHistory)
            }
            LabeledContent("Full Disk Access") {
                Button("Open Settings") { AppState.openFullDiskAccessSettings() }
            }
            Text("Without Full Disk Access, MyOpenCleaner cannot see Safari history, some system caches, or Mail.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
