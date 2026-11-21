import Foundation

/// Places besides LaunchAgents/LaunchDaemons where code can start by itself or hook into the system.
/// The list of places follows the categories KnockKnock covers; the implementation is our own.
/// Everything here is read-only: items are shown and revealed in Finder, never removed automatically.
public struct PersistenceItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case cron, periodic, shellConfig, browserExtension, quickLook, spotlight, authPlugin, kernelExtension,
             systemExtension, dylibInsert

        public var title: String {
            switch self {
            case .cron: "Scheduled jobs (cron)"
            case .periodic: "Periodic scripts"
            case .shellConfig: "Shell startup files"
            case .browserExtension: "Browser extensions"
            case .quickLook: "Quick Look plug-ins"
            case .spotlight: "Spotlight importers"
            case .authPlugin: "Login authorization plug-ins"
            case .kernelExtension: "Kernel extensions"
            case .systemExtension: "System extensions"
            case .dylibInsert: "Library injection"
            }
        }

        public var symbol: String {
            switch self {
            case .cron: "clock"
            case .periodic: "calendar.badge.clock"
            case .shellConfig: "terminal"
            case .browserExtension: "puzzlepiece"
            case .quickLook: "eye"
            case .spotlight: "magnifyingglass"
            case .authPlugin: "lock"
            case .kernelExtension: "cpu"
            case .systemExtension: "gearshape.2"
            case .dylibInsert: "syringe"
            }
        }
    }

    public var id: String { kind.rawValue + "|" + title + "|" + (url?.path ?? "") + "|" + detail }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let url: URL?
    /// nil: just information. Otherwise how worrying it looks.
    public let level: Threat.Level?
    public let reasons: [String]

    public init(kind: Kind, title: String, detail: String, url: URL?, level: Threat.Level? = nil, reasons: [String] = []) {
        self.kind = kind; self.title = title; self.detail = detail; self.url = url; self.level = level; self.reasons = reasons
    }
}

public struct PersistenceScanner: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    public var signatures: [Signature]
    public var codeSignatureCheck: @Sendable (URL) -> Bool

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(),
                signatures: [Signature] = MalwareScanner.knownFamilies,
                codeSignatureCheck: @escaping @Sendable (URL) -> Bool = MalwareScanner.isValidlySigned) {
        self.env = env; self.runner = runner; self.signatures = signatures; self.codeSignatureCheck = codeSignatureCheck
    }

    public func scan() -> [PersistenceItem] {
        let all = cron() + periodic() + shellConfigs() + browserExtensions() + plugins() + kernelExtensions()
            + systemExtensions() + dylibInserts()
        return all.sorted { ($0.level?.rawValue ?? -1) > ($1.level?.rawValue ?? -1) }
    }

    // MARK: Text heuristics shared by cron lines and shell files

    static let suspiciousPatterns: [(regex: String, reason: String)] = [
        (#"(curl|wget)[^|;\n]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "Downloads a script and runs it"),
        (#"base64\s+(-d|-D|--decode)"#, "Decodes hidden (base64) content"),
        (#"eval\s+"?\$\(\s*(curl|wget)"#, "Evaluates code downloaded from the internet"),
        (#"osascript\s+-e"#, "Runs AppleScript"),
        (#"(^|[\s'"=])(/private)?/tmp/|/users/shared/"#, "Uses a temporary or shared folder"),
        (#"launchctl\s+(load|bootstrap|submit)"#, "Registers a background job"),
        (#"dyld_insert_libraries"#, "Injects a library into other programs"),
        (#"nohup\s.+&\s*$"#, "Starts a hidden background process"),
    ]

    func reasons(for line: String) -> [String] {
        let l = line.lowercased()
        var out = Self.suspiciousPatterns.compactMap { p in
            l.range(of: p.regex, options: .regularExpression) != nil ? p.reason : nil
        }
        // Names are often spelled with spaces ("Safe Finder"); signatures are written without.
        let squashed = l.replacingOccurrences(of: " ", with: "")
        if let sig = signatures.first(where: { $0.patterns.contains { l.contains($0) || squashed.contains($0) } }) {
            out.insert("Matches the \"\(sig.family)\" signature", at: 0)
        }
        return out
    }

    func level(_ reasons: [String]) -> Threat.Level? {
        if reasons.contains(where: { $0.hasPrefix("Matches the") }) { return .known }
        return reasons.isEmpty ? nil : .suspicious
    }

    // MARK: cron

    func cron() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        func add(_ text: String, source: String, url: URL?) {
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                // A job is "@reboot cmd" or five time fields plus a command; comments and
                // variable lines such as SHELL=/bin/sh are skipped.
                guard !line.isEmpty, !line.hasPrefix("#"),
                      line.hasPrefix("@") || line.split(whereSeparator: { $0 == " " || $0 == "\t" }).count >= 6 else { continue }
                let r = reasons(for: line)
                out.append(PersistenceItem(kind: .cron, title: line, detail: source, url: url, level: level(r), reasons: r))
            }
        }
        let user = runner.run("/usr/bin/crontab", ["-l"])
        if user.ok { add(user.output, source: "Your crontab", url: nil) }
        let etc = env.resolve("/etc/crontab")
        if let text = try? String(contentsOf: etc, encoding: .utf8) { add(text, source: "/etc/crontab", url: etc) }
        return out
    }

    // MARK: periodic

    /// Scripts macOS ships in /etc/periodic; anything else there was added by someone.
    static let stockPeriodic: Set<String> = ["110.clean-tmps", "130.clean-msgs", "140.clean-rwho", "199.rotate-fax",
                                              "400.status-disks", "420.status-network", "430.status-uptime", "999.local",
                                              "320.whatis", "200.accounting"]

    func periodic() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        for folder in ["/etc/periodic/daily", "/etc/periodic/weekly", "/etc/periodic/monthly",
                       "/usr/local/etc/periodic/daily", "/usr/local/etc/periodic/weekly", "/usr/local/etc/periodic/monthly"] {
            for script in FileManager.default.children(of: env.resolve(folder)) where !Self.stockPeriodic.contains(script.lastPathComponent) {
                let text = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
                let r = text.split(separator: "\n").flatMap { reasons(for: String($0)) }
                out.append(PersistenceItem(kind: .periodic, title: script.lastPathComponent, detail: "Not part of macOS · \(folder)",
                                           url: script, level: level(Array(Set(r))), reasons: Array(Set(r)).sorted()))
            }
        }
        return out
    }

    // MARK: Shell startup files

    static let shellFiles = ["~/.zshrc", "~/.zshenv", "~/.zprofile", "~/.zlogin", "~/.zlogout", "~/.bashrc",
                             "~/.bash_profile", "~/.profile", "/etc/zshrc", "/etc/zprofile", "/etc/profile", "/etc/bashrc"]

    /// Only lines that look suspicious are listed; ordinary configuration is not.
    func shellConfigs() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        for path in Self.shellFiles {
            let url = env.resolve(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let r = reasons(for: line)
                guard !r.isEmpty else { continue }
                out.append(PersistenceItem(kind: .shellConfig, title: line, detail: "\(path), line \(n + 1)", url: url,
                                           level: level(r), reasons: r))
            }
        }
        return out
    }

    // MARK: Browser extensions

    static let chromium: [(browser: String, root: String)] = [
        ("Chrome", "~/Library/Application Support/Google/Chrome"),
        ("Edge", "~/Library/Application Support/Microsoft Edge"),
        ("Brave", "~/Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Arc", "~/Library/Application Support/Arc/User Data"),
        ("Vivaldi", "~/Library/Application Support/Vivaldi"),
    ]

    func browserExtensions() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        let fm = FileManager.default
        for (browser, root) in Self.chromium {
            for profile in fm.children(of: env.resolve(root)) where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
                for ext in fm.children(of: profile.appendingPathComponent("Extensions")) where !ext.lastPathComponent.hasPrefix(".") {
                    guard let version = fm.children(of: ext).filter(\.isDirectoryURL).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
                          let name = Self.chromiumExtensionName(version) else { continue }
                    let r = reasons(for: name + " " + ext.lastPathComponent)
                    out.append(PersistenceItem(kind: .browserExtension, title: name,
                                               detail: "\(browser) · \(profile.lastPathComponent) · \(ext.lastPathComponent)",
                                               url: ext, level: level(r), reasons: r))
                }
            }
        }
        for profile in fm.children(of: env.resolve("~/Library/Application Support/Firefox/Profiles")) {
            for (name, id) in Self.firefoxExtensions(profile.appendingPathComponent("extensions.json")) {
                let r = reasons(for: name + " " + id)
                out.append(PersistenceItem(kind: .browserExtension, title: name, detail: "Firefox · \(id)",
                                           url: profile.appendingPathComponent("extensions"), level: level(r), reasons: r))
            }
        }
        return out
    }

    /// The extension's name from manifest.json, resolving `__MSG_key__` through _locales.
    static func chromiumExtensionName(_ versionDir: URL) -> String? {
        guard let data = try? Data(contentsOf: versionDir.appendingPathComponent("manifest.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var name = m["name"] as? String else { return nil }
        if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            let key = String(name.dropFirst(6).dropLast(2))
            let locale = (m["default_locale"] as? String) ?? "en"
            let file = versionDir.appendingPathComponent("_locales/\(locale)/messages.json")
            if let d = try? Data(contentsOf: file), let msgs = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let entry = (msgs[key] ?? msgs[key.lowercased()]) as? [String: Any], let text = entry["message"] as? String {
                name = text
            }
        }
        return name
    }

    /// User-installed Firefox add-ons (built-in and system ones are left out).
    static func firefoxExtensions(_ file: URL) -> [(name: String, id: String)] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = json["addons"] as? [[String: Any]] else { return [] }
        return addons.compactMap { a in
            guard (a["type"] as? String) == "extension", (a["location"] as? String) == "app-profile",
                  let id = a["id"] as? String else { return nil }
            let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String) ?? id
            return (name, id)
        }
    }

    // MARK: Plug-ins that load into system processes

    func plugins() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        let sets: [(PersistenceItem.Kind, [String], String)] = [
            (.quickLook, ["~/Library/QuickLook", "/Library/QuickLook"], "qlgenerator"),
            (.spotlight, ["~/Library/Spotlight", "/Library/Spotlight"], "mdimporter"),
            (.authPlugin, ["/Library/Security/SecurityAgentPlugins"], "bundle"),
        ]
        for (kind, folders, ext) in sets {
            for folder in folders {
                for item in FileManager.default.children(of: env.resolve(folder)) where item.pathExtension == ext {
                    var r = reasons(for: item.lastPathComponent)
                    if !codeSignatureCheck(item) { r.append("Not validly signed") }
                    let lvl: Threat.Level? = level(r) ?? (r.isEmpty ? nil : .suspicious)
                    out.append(PersistenceItem(kind: kind, title: item.deletingPathExtension().lastPathComponent,
                                               detail: folder, url: item, level: lvl, reasons: r))
                }
            }
        }
        return out
    }

    func kernelExtensions() -> [PersistenceItem] {
        FileManager.default.children(of: env.resolve("/Library/Extensions")).filter { $0.pathExtension == "kext" }.map { kext in
            var r = reasons(for: kext.lastPathComponent)
            if !codeSignatureCheck(kext) { r.append("Not validly signed") }
            return PersistenceItem(kind: .kernelExtension, title: kext.deletingPathExtension().lastPathComponent,
                                   detail: "Third-party kernel extension · /Library/Extensions", url: kext,
                                   level: level(r) ?? (r.isEmpty ? nil : .suspicious), reasons: r)
        }
    }

    func systemExtensions() -> [PersistenceItem] {
        Self.parseSystemExtensions(runner.run("/usr/bin/systemextensionsctl", ["list"]).output).map { e in
            let r = reasons(for: e.bundleID)
            return PersistenceItem(kind: .systemExtension, title: e.name, detail: "\(e.bundleID) · team \(e.team) · \(e.state)",
                                   url: nil, level: level(r), reasons: r)
        }
    }

    /// Parses `systemextensionsctl list` rows:
    /// `*\t*\tTEAMID\tcom.vendor.ext (1.0/1)\tName\t[activated enabled]`
    public static func parseSystemExtensions(_ output: String) -> [(team: String, bundleID: String, name: String, state: String)] {
        output.split(separator: "\n").compactMap { line in
            // Keep empty columns: a disabled or inactive extension has blanks where "*" would be.
            let cols = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            // Data rows start with "*" or a blank; the column header row starts with "enabled".
            guard cols.count >= 6, cols[0] == "*" || cols[0].isEmpty, cols[5].hasPrefix("["),
                  cols[3].contains(" (") else { return nil }
            let bundleID = cols[3].components(separatedBy: " (").first ?? cols[3]
            return (cols[2], bundleID, cols[4], cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }
    }

    // MARK: Library injection through launch items

    func dylibInserts() -> [PersistenceItem] {
        var out: [PersistenceItem] = []
        for scope in LaunchItem.Scope.allCases {
            for plist in FileManager.default.children(of: env.resolve(scope.folder)) where plist.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: plist),
                      let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let vars = d["EnvironmentVariables"] as? [String: Any],
                      let lib = vars["DYLD_INSERT_LIBRARIES"] as? String else { continue }
                out.append(PersistenceItem(kind: .dylibInsert, title: (d["Label"] as? String) ?? plist.lastPathComponent,
                                           detail: "Injects \(lib)", url: plist, level: .suspicious,
                                           reasons: ["Sets DYLD_INSERT_LIBRARIES, which loads code into the program it starts"]))
            }
        }
        return out
    }
}
