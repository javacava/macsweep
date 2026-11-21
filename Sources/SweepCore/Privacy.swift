import Foundation

public enum Browser: String, CaseIterable, Sendable {
    case safari = "Safari", chrome = "Google Chrome", firefox = "Firefox", edge = "Microsoft Edge", brave = "Brave"

    public var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .firefox: "org.mozilla.firefox"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        }
    }

    /// Chromium-family profile root.
    var chromiumRoot: String? {
        switch self {
        case .chrome: "~/Library/Application Support/Google/Chrome"
        case .edge: "~/Library/Application Support/Microsoft Edge"
        case .brave: "~/Library/Application Support/BraveSoftware/Brave-Browser"
        default: nil
        }
    }
}

public enum PrivacyKind: String, CaseIterable, Sendable {
    case history, cookies, autofill, downloads, recentItems

    public var title: String {
        switch self {
        case .history: "Browsing history"
        case .cookies: "Cookies"
        case .autofill: "Autofill (addresses, saved cards, search engines)"
        case .downloads: "Download history"
        case .recentItems: "Recent items"
        }
    }
}

public struct PrivacyItem: Identifiable, Sendable {
    public var id: String { "\(owner)-\(kind.rawValue)" }
    public let owner: String
    public let bundleID: String?
    public let kind: PrivacyKind
    public let files: [URL]
    public var size: Int64 { files.reduce(0) { $0 + FileSize.of($1) } }
}

/// Lists browser traces that can be wiped. Saved passwords are never included.
public struct PrivacyScanner: Sendable {
    public let env: SweepEnvironment
    public init(env: SweepEnvironment) { self.env = env }

    public func scan() -> [PrivacyItem] {
        var out: [PrivacyItem] = []
        let fm = FileManager.default
        func existing(_ urls: [URL]) -> [URL] { urls.filter { fm.fileExists(atPath: $0.path) } }
        func add(_ owner: String, _ bid: String?, _ kind: PrivacyKind, _ urls: [URL]) {
            let f = existing(urls)
            if !f.isEmpty { out.append(PrivacyItem(owner: owner, bundleID: bid, kind: kind, files: f)) }
        }

        // Safari (reading it needs Full Disk Access).
        let safari = env.resolve("~/Library/Safari")
        add("Safari", Browser.safari.bundleID, .history, ["History.db", "History.db-wal", "History.db-shm"].map { safari.appendingPathComponent($0) })
        add("Safari", Browser.safari.bundleID, .downloads, [safari.appendingPathComponent("Downloads.plist")])
        add("Safari", Browser.safari.bundleID, .cookies, [env.resolve("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                                                         env.resolve("~/Library/Cookies/Cookies.binarycookies")])
        add("Safari", Browser.safari.bundleID, .autofill, [safari.appendingPathComponent("Form Values")])

        for b in [Browser.chrome, .edge, .brave] {
            guard let root = b.chromiumRoot else { continue }
            for profile in chromiumProfiles(env.resolve(root)) {
                let owner = profile.lastPathComponent == "Default" ? b.rawValue : "\(b.rawValue) (\(profile.lastPathComponent))"
                add(owner, b.bundleID, .history, ["History", "History-journal", "Visited Links", "Top Sites"].map { profile.appendingPathComponent($0) })
                add(owner, b.bundleID, .cookies, ["Cookies", "Cookies-journal", "Network/Cookies"].map { profile.appendingPathComponent($0) })
                add(owner, b.bundleID, .autofill, ["Web Data", "Web Data-journal"].map { profile.appendingPathComponent($0) })
            }
        }

        let ff = env.resolve("~/Library/Application Support/Firefox/Profiles")
        for profile in fm.children(of: ff) where profile.isDirectoryURL {
            let owner = "Firefox (\(profile.lastPathComponent))"
            add(owner, Browser.firefox.bundleID, .history, ["places.sqlite", "places.sqlite-wal"].map { profile.appendingPathComponent($0) })
            add(owner, Browser.firefox.bundleID, .cookies, ["cookies.sqlite", "cookies.sqlite-wal"].map { profile.appendingPathComponent($0) })
            add(owner, Browser.firefox.bundleID, .autofill, [profile.appendingPathComponent("formhistory.sqlite")])
        }

        let shared = env.resolve("~/Library/Application Support/com.apple.sharedfilelist")
        let recent = fm.children(of: shared).filter { $0.lastPathComponent.contains("RecentDocuments")
            || $0.lastPathComponent.contains("RecentApplications") || $0.lastPathComponent.contains("RecentServers") }
        add("macOS", nil, .recentItems, recent)
        return out
    }

    func chromiumProfiles(_ root: URL) -> [URL] {
        FileManager.default.children(of: root).filter {
            $0.isDirectoryURL && ($0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile "))
        }
    }

    /// Files that must survive a privacy clean no matter what.
    public static func isProtected(_ url: URL) -> Bool {
        ["Login Data", "logins.json", "key4.db", "Bookmarks", "bookmarks.plist"].contains(url.lastPathComponent)
    }
}

public struct WiFiNetworks: Sendable {
    public let runner: CommandRunning
    public init(runner: CommandRunning = ProcessRunner()) { self.runner = runner }

    /// Parses `networksetup -listpreferredwirelessnetworks en0`.
    public static func parse(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func list(interface: String = "en0") -> [String] {
        Self.parse(runner.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface]).output)
    }

    public func remove(_ ssid: String, interface: String = "en0") -> CommandResult {
        runner.runAsAdmin("/usr/sbin/networksetup -removepreferredwirelessnetwork \(AdminScript.shellQuote(interface)) \(AdminScript.shellQuote(ssid))")
    }
}
