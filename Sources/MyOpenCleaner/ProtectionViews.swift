import SwiftUI
import SweepCore

struct MalwareView: View {
    @ObservedObject var state = AppState.shared
    @State private var threats: [Threat]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var message: String?
    @State private var confirm = false

    var chosen: [Threat] { threats?.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        ModulePage(module: .malware, subtitle: "Checks everything that starts automatically: known adware, miners, suspicious and broken items.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let threats {
                if threats.isEmpty {
                    StateView(symbol: "checkmark.shield", title: "No threats found",
                              message: "macOS also protects you with its built-in XProtect.")
                } else {
                    VStack(spacing: 0) {
                        List(threats) { t in
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
                        ActionBar(selectedCount: chosen.count, selectedSize: 0, buttonTitle: "Remove", busy: busy) { confirm = true }
                    }
                }
            } else {
                StateView(symbol: "shield.lefthalf.filled", title: busy ? "Checking…" : "Check your Mac for threats",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .confirmationDialog("Remove \(chosen.count) items?", isPresented: $confirm) {
            Button("Stop and remove", role: .destructive, action: remove)
        } message: { Text("The processes are stopped and their launch files removed. System items need a password.") }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; threats = nil
        let env = state.env
        Task {
            let t = await AppState.background { MalwareScanner(env: env).scan(LaunchItemsManager(env: env).items()) }
            threats = t
            selected = Set(t.filter { $0.level == .known }.map(\.id))
            busy = false
        }
    }

    func remove() {
        busy = true
        let env = state.env, items = chosen, cleaner = state.cleaner()
        Task {
            let r = await AppState.background { () -> CleanReport in
                let m = LaunchItemsManager(env: env)
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
                    _ = ProcessRunner().runAsAdmin(lines.joined(separator: "; "))
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
        .confirmationDialog("Clear the selection?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: clean)
        } message: { Text("Quit browsers before clearing. Removing cookies signs you out of websites.") }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; items = nil
        let env = state.env
        Task {
            let (found, s, w) = await AppState.background { () -> ([PrivacyItem], [String: Int64], [String]) in
                let f = PrivacyScanner(env: env).scan()
                return (f, Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0.size) }), WiFiNetworks().list())
            }
            items = found; sizes = s; wifi = w; selected = []; busy = false
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

    func forget(_ ssid: String) {
        Task {
            let r = await AppState.background { WiFiNetworks().remove(ssid) }
            if r.ok { wifi.removeAll { $0 == ssid } } else { message = "Failed: \(r.error)" }
        }
    }
}
