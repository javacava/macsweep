import SwiftUI
import SweepCore

struct MalwareView: View {
    @ObservedObject var state = AppState.shared
    @State private var threats: [Threat]?
    @State private var checks: [SecurityCheck] = []
    @State private var persistence: [PersistenceItem] = []
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var message: String?
    @State private var confirm = false

    var chosen: [Threat] { threats?.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        ModulePage(module: .malware, subtitle: "Checks everything that starts automatically: known adware, miners, suspicious and broken items.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
          VStack(spacing: 0) {
            ProtectionStatus(checks: checks)
            if let threats {
                VStack(spacing: 0) {
                    List {
                        Section("Launch agents and daemons") {
                            if threats.isEmpty {
                                Label("No threats found. macOS also protects you with its built-in XProtect.", systemImage: "checkmark.shield")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(threats) { t in threatRow(t) }
                        }
                        ForEach(PersistenceItem.Kind.allCases, id: \.self) { kind in
                            let rows = persistence.filter { $0.kind == kind }
                            if !rows.isEmpty {
                                Section {
                                    ForEach(rows) { item in persistenceRow(item) }
                                } header: {
                                    Label("\(kind.title) (\(rows.count))", systemImage: kind.symbol)
                                }
                            }
                        }
                    }
                    if !threats.isEmpty {
                        ActionBar(selectedCount: chosen.count, selectedSize: 0, buttonTitle: "Remove", busy: busy) { confirm = true }
                    }
                }
            } else {
                StateView(symbol: "shield.lefthalf.filled", title: busy ? "Checking…" : "Check your Mac for threats",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
          }
        .onAppear { if AppState.shared.autoScan, threats == nil, !busy { scan() } }
        .task { await loadChecks() }
        .confirmationDialog("Remove \(chosen.count) items?", isPresented: $confirm) {
            Button("Stop and remove", role: .destructive, action: remove)
        } message: { Text("The processes are stopped and their launch files removed. System items need a password.") }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func threatRow(_ t: Threat) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: member($selected, t.id)).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: t.level == .broken ? "exclamationmark.triangle" : "ladybug.fill")
                .foregroundStyle(t.level == .known ? .red : t.level == .suspicious ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.item.label).font(.headline)
                Text(t.level.title).font(.caption.bold()).foregroundStyle(t.level == .known ? .red : .orange)
                ForEach(t.reasons, id: \.self) { Text("• " + $0).font(.caption) }
                Text(state.display(t.item.plist)).font(.caption2).foregroundStyle(.secondary)
                if let p = t.item.program { Text(p).font(.caption2).foregroundStyle(.secondary) }
                if let app = t.appBundle {
                    Text("Only the launch item is turned off. Remove the \(app.deletingPathExtension().lastPathComponent) app itself with the Uninstaller.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { AppState.reveal(t.item.plist) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
        }
    }

    /// Other autostart places are shown, never removed from here: open them in Finder to act.
    func persistenceRow(_ item: PersistenceItem) -> some View {
        HStack(alignment: .top) {
            Image(systemName: item.level == nil ? "info.circle" : item.level == .known ? "ladybug.fill" : "exclamationmark.triangle")
                .foregroundStyle(item.level == .known ? .red : item.level == .suspicious ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout).lineLimit(2).truncationMode(.middle)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(item.reasons, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if let url = item.url {
                Button { AppState.reveal(url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            }
        }
    }

    func loadChecks() async {
        let env = state.env, runner = state.runner
        checks = await AppState.background { SecurityAudit(env: env, runner: runner).run() }
    }

    func scan() {
        busy = true; threats = nil
        let env = state.env, runner = state.runner
        Task {
            let (t, p) = await AppState.background { () -> ([Threat], [PersistenceItem]) in
                (MalwareScanner(env: env).scan(LaunchItemsManager(env: env, runner: runner).items()),
                 PersistenceScanner(env: env, runner: runner).scan())
            }
            persistence = p
            threats = t
            selected = Set(t.filter { $0.level == .known }.map(\.id))
            busy = false
        }
    }

    func remove() {
        busy = true
        let env = state.env, items = chosen, cleaner = state.cleaner(), runner = state.runner
        Task {
            let r = await AppState.background { () -> CleanReport in
                let m = LaunchItemsManager(env: env, runner: runner)
                let user = items.filter { $0.item.scope == .userAgent }
                for t in user { m.setEnabled(t.item, false) }
                var report = cleaner.remove(user.flatMap(\.files).map { ($0, FileSize.of($0)) })
                // System-wide items need root. Stop them and remove their files in ONE admin prompt.
                // The same safety guard as everywhere else decides which files may go, and `rm -f`
                // (no -r) can only ever remove single files.
                let system = items.filter { $0.item.scope != .userAgent }
                if !system.isEmpty {
                    let guardrail = SafetyGuard(env: env)
                    let files = system.flatMap(\.files)
                    let allowed = files.filter { guardrail.check($0) == .allowed }
                    report.failed += files.filter { !allowed.contains($0) }.map { ($0, "Protected path") }
                    var lines = system.flatMap { t -> [String] in
                        let target = AdminScript.shellQuote("\(t.item.scope == .systemDaemon ? "system" : "gui/\(getuid())")/\(t.item.label)")
                        return ["/bin/launchctl bootout \(target)", "/bin/launchctl disable \(target)"]
                    }
                    if !allowed.isEmpty {
                        lines.append("/bin/rm -f -- " + allowed.map { AdminScript.shellQuote($0.path) }.joined(separator: " "))
                    }
                    _ = runner.runAsAdmin(lines.joined(separator: "; "))
                    // Trust the disk, not the exit code: bootout fails harmlessly when the item was not loaded.
                    for f in allowed {
                        if FileManager.default.fileExists(atPath: f.path) { report.failed.append((f, "Cancelled or not permitted")) }
                        else { report.removed.append(f) }
                    }
                }
                return report
            }
            state.record(.malware, r)
            message = cleanSummary(r)
            busy = false
            scan()
        }
    }
}

struct PrivacyView: View {
    @ObservedObject var state = AppState.shared
    @State private var items: [PrivacyItem]?
    @State private var sizes: [String: Int64] = [:]
    @State private var selected = Set<String>()
    @State private var wifi: [String] = []
    @State private var keychain: [KeychainEntry] = []
    @State private var busy = false
    @State private var message: String?
    @State private var confirm = false

    var chosen: [PrivacyItem] { items?.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        ModulePage(module: .privacy, subtitle: "Browser history, cookies, autofill, recent items, saved Wi‑Fi. Passwords are never touched.") {
            Button("App permissions…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let items {
                VStack(spacing: 0) {
                    FullDiskAccessBanner()
                    List {
                        let owners = Array(Set(items.map(\.owner))).sorted()
                        ForEach(owners, id: \.self) { owner in
                            Section(owner) {
                                ForEach(items.filter { $0.owner == owner }) { item in
                                    HStack {
                                        Toggle(item.kind.title, isOn: member($selected, item.id)).toggleStyle(.checkbox)
                                        Spacer()
                                        SizeText(bytes: sizes[item.id] ?? 0)
                                    }
                                }
                            }
                        }
                        if !keychain.isEmpty { keychainSection }
                        Section("Saved Wi‑Fi networks (\(wifi.count))") {
                            ForEach(wifi, id: \.self) { ssid in
                                HStack {
                                    Image(systemName: "wifi")
                                    Text(ssid)
                                    Spacer()
                                    Button("Forget") { forget(ssid) }
                                }
                            }
                        }
                    }
                    if items.isEmpty {
                        Text("Nothing found. Safari needs Full Disk Access.").foregroundStyle(.secondary).padding(6)
                    }
                    ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + (sizes[$1.id] ?? 0) },
                              buttonTitle: "Clean", busy: busy) { confirm = true }
                }
            } else {
                StateView(symbol: "hand.raised", title: busy ? "Looking for traces…" : "Clear traces of your activity",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, items == nil, !busy { scan() } }
        .confirmationDialog("Clear the selection?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: clean)
        } message: { Text("Quit browsers before clearing. Removing cookies signs you out of websites.") }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; items = nil
        let env = state.env, runner = state.runner
        Task {
            let (found, s, w, k) = await AppState.background { () -> ([PrivacyItem], [String: Int64], [String], [KeychainEntry]) in
                let f = PrivacyScanner(env: env).scan()
                // Apps anywhere on the Mac count as installed, so their keychain entries are never listed.
                let installed = Set(AppScanner.installedApps(env: env).map(\.bundleID)).union(AppScanner.spotlightBundleIDs(runner: runner))
                return (f, Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0.size) }), WiFiNetworks(runner: runner).list(),
                        KeychainReview(runner: runner).staleEntries(installed: installed))
            }
            items = found; sizes = s; wifi = w; keychain = k; selected = []; busy = false
        }
    }

    func clean() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let busyApp = chosen.first(where: { $0.bundleID.map(running.contains) ?? false }) {
            message = "Quit \(busyApp.owner) first."
            return
        }
        busy = true
        let targets = chosen.flatMap(\.files).filter { !PrivacyScanner.isProtected($0) }.map { ($0, FileSize.of($0)) }
        let cleaner = Cleaner(env: state.env, mode: .permanent)  // traces should not linger in the Trash
        Task {
            let r = await AppState.background { cleaner.remove(targets) }
            state.record(.privacy, r)
            message = cleanSummary(r)
            busy = false
            scan()
        }
    }

    /// Saved passwords of apps that are gone. Shown only: MyOpenCleaner never deletes keychain entries.
    var keychainSection: some View {
        Section {
            Text("Only names are read, never passwords. MyOpenCleaner does not delete keychain entries: find one in Keychain Access and delete it there if you no longer need it.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(keychain) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "key").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.service).lineLimit(1).truncationMode(.middle)
                        Text([entry.account, entry.modified.map { "changed " + $0.formatted(date: .abbreviated, time: .omitted) }]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    SafetyBadge(safety: .kept)
                    Button("Find in Keychain Access") { Self.findInKeychainAccess(entry.service) }
                        .controlSize(.small)
                        .help("Copies the name and opens Keychain Access: paste it into the search field")
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Keychain entries of removed apps (\(keychain.count))")
        }
    }

    /// Keychain Access cannot be pointed at one entry, so the name goes to the clipboard for its search field.
    static func findInKeychainAccess(_ service: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service, forType: .string)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        AppState.shared.toast = "Copied “\(service)”. Paste it into Keychain Access's search field."
    }

    func forget(_ ssid: String) {
        Task {
            let runner = state.runner
            let r = await AppState.background { WiFiNetworks(runner: runner).remove(ssid) }
            if r.ok { wifi.removeAll { $0 == ssid } } else { message = "Failed: \(r.error)" }
        }
    }
}

/// Read-only summary of the Mac's built-in protections, shown above the launch-item scan.
struct ProtectionStatus: View {
    let checks: [SecurityCheck]

    var body: some View {
        if !checks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("System protection").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: symbol(c.state)).foregroundStyle(color(c.state))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.callout.weight(.medium))
                                Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let advice = c.advice {
                                    Text(advice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            if c.state != .good, let link = c.settingsURL, let url = URL(string: link) {
                                Button("Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.quaternary.opacity(0.35))
        }
    }

    func symbol(_ s: SecurityCheck.State) -> String {
        switch s { case .good: "checkmark.shield.fill"; case .warning: "exclamationmark.shield.fill"; case .unknown: "questionmark.circle" }
    }

    func color(_ s: SecurityCheck.State) -> Color {
        switch s { case .good: .green; case .warning: .orange; case .unknown: .secondary }
    }
}
