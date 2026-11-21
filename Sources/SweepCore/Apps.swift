import Foundation

public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    /// Sparkle appcast, when the app updates itself with Sparkle.
    public let feedURL: URL?
    public let isAppStore: Bool

    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    public init(url: URL, name: String, bundleID: String, version: String, build: String = "",
                feedURL: URL? = nil, isAppStore: Bool = false) {
        self.url = url; self.name = name; self.bundleID = bundleID; self.version = version
        self.build = build; self.feedURL = feedURL; self.isAppStore = isAppStore
    }

    /// Reads `Contents/Info.plist` of an .app bundle.
    public init?(bundle url: URL) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String, !bid.isEmpty else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (plist["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let mas = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        self.init(url: url, name: name, bundleID: bid,
                  version: plist["CFBundleShortVersionString"] as? String ?? "",
                  build: plist["CFBundleVersion"] as? String ?? "", feedURL: feed, isAppStore: mas)
    }
}

public enum AppScanner {
    /// Apps in /Applications, its subfolders (Utilities etc.) and ~/Applications.
    public static func installedApps(env: SweepEnvironment) -> [AppInfo] {
        let fm = FileManager.default
        var found: [AppInfo] = []
        var seen = Set<String>()
        func visit(_ dir: URL, depth: Int) {
            for child in fm.children(of: dir) {
                if child.pathExtension == "app" {
                    if let app = AppInfo(bundle: child), seen.insert(child.path).inserted { found.append(app) }
                } else if depth > 0, child.isDirectoryURL, !child.lastPathComponent.hasPrefix(".") {
                    visit(child, depth: depth - 1)
                }
            }
        }
        visit(env.resolve("/Applications"), depth: 1)
        visit(env.resolve("~/Applications"), depth: 1)
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension AppScanner {
    /// Bundle IDs of every app Spotlight knows about, wherever it lives (other folders, other disks).
    /// Used so that data of an app outside /Applications is not mistaken for a leftover.
    static func spotlightBundleIDs(runner: CommandRunning = ProcessRunner()) -> Set<String> {
        parseSpotlight(runner.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'",
                                                      "-attr", "kMDItemCFBundleIdentifier"]).output)
    }

    /// Parses `mdfind -attr kMDItemCFBundleIdentifier` lines: `<path>   kMDItemCFBundleIdentifier = <id>`.
    static func parseSpotlight(_ output: String) -> Set<String> {
        var ids = Set<String>()
        for line in output.split(separator: "\n") {
            guard let r = line.range(of: "kMDItemCFBundleIdentifier = ", options: .backwards) else { continue }
            let id = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id != "(null)" { ids.insert(id) }
        }
        return ids
    }
}

public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let location: String
}

/// Finds files an app left in Library folders. Matching follows the approach popularised by
/// Pearcleaner (bundle ID first, then the app's name), reimplemented here from scratch.
public struct LeftoverFinder: Sendable {
    public let env: SweepEnvironment

    public init(env: SweepEnvironment) { self.env = env }

    public static let searchFolders: [(path: String, title: String)] = [
        ("~/Library/Application Support", "App data"),
        ("~/Library/Caches", "Cache"),
        ("~/Library/Preferences", "Preferences"),
        ("~/Library/Preferences/ByHost", "Preferences"),
        ("~/Library/Containers", "Container"),
        ("~/Library/Group Containers", "Group container"),
        ("~/Library/Saved Application State", "Saved state"),
        ("~/Library/Logs", "Logs"),
        ("~/Library/HTTPStorages", "HTTP storage"),
        ("~/Library/WebKit", "WebKit"),
        ("~/Library/Cookies", "Cookies"),
        ("~/Library/LaunchAgents", "Launch agent"),
        ("~/Library/Application Scripts", "Scripts"),
        ("/Library/Application Support", "App data (system)"),
        ("/Library/Caches", "Cache (system)"),
        ("/Library/Preferences", "Preferences (system)"),
        ("/Library/LaunchAgents", "Launch agent (system)"),
        ("/Library/LaunchDaemons", "Launch daemon"),
        ("/Library/PrivilegedHelperTools", "Privileged helper"),
        ("/Library/Logs", "Logs (system)"),
    ]

    /// Lowercased name without the extension (and without `.savedState`, `.plist`, `.bom`).
    static func stem(_ name: String) -> String {
        var s = name.lowercased()
        for ext in [".plist", ".savedstate", ".bom", ".binarycookies", ".log"] where s.hasSuffix(ext) {
            s.removeLast(ext.count)
        }
        return s
    }

    static func lettersOnly(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// True when a file or folder named `name` belongs to the app.
    public static func matches(name: String, bundleID: String, appName: String) -> Bool {
        let s = stem(name)
        let bid = bundleID.lowercased()
        if !bid.isEmpty, bid.contains(".") {
            if s == bid { return true }
            // A two-part ID ("com.acme") is a vendor prefix: matching by prefix would claim the vendor's other apps.
            if bid.split(separator: ".").count >= 3,
               s.hasPrefix(bid + ".") || s.hasSuffix("." + bid) || s.contains("." + bid + ".") { return true }
        }
        let n = lettersOnly(appName)
        guard n.count >= 3, !sharedFolderNames.contains(n) else { return false }
        // Name match only for exact names: "Notion" must not catch "NotionHelperOther".
        return lettersOnly(s) == n
    }

    /// Folders shared by many apps of one vendor (or by the system). Never claimed by an app's name alone.
    static let sharedFolderNames: Set<String> = [
        "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains", "amazon", "meta", "oracle", "intel",
        "caches", "logs", "preferences", "cookies", "containers", "library", "data", "temp", "cache", "common",
    ]

    /// Bundle ID stored by the system inside a sandbox container.
    static func containerIdentifier(_ container: URL) -> String? {
        let meta = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: meta),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    public func leftovers(for app: AppInfo) -> [Leftover] {
        guard !app.isApple else { return [] }
        let fm = FileManager.default
        var out: [Leftover] = []
        var seen = Set<String>()
        for folder in Self.searchFolders {
            let dir = env.resolve(folder.path)
            for child in fm.children(of: dir) {
                let name = child.lastPathComponent
                var hit = Self.matches(name: name, bundleID: app.bundleID, appName: app.name)
                if !hit, folder.path.hasSuffix("Containers"),
                   Self.containerIdentifier(child)?.lowercased() == app.bundleID.lowercased() {
                    hit = true
                }
                guard hit, !child.isInside(app.url), seen.insert(child.standardizedFileURL.path).inserted else { continue }
                out.append(Leftover(url: child, size: FileSize.of(child), location: folder.title))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Leftovers of apps that are no longer installed: reverse-DNS named items whose ID belongs to no installed app.
    public func orphans(installed: [AppInfo], extraBundleIDs: Set<String> = []) -> [Leftover] {
        let ids = installed.map { $0.bundleID.lowercased() } + extraBundleIDs.map { $0.lowercased() }
        let vendors = Set(ids.map(Self.vendor))
        let fm = FileManager.default
        var out: [Leftover] = []
        let folders = ["~/Library/Application Support", "~/Library/Preferences", "~/Library/Containers",
                       "~/Library/Saved Application State", "~/Library/Caches", "~/Library/HTTPStorages"]
        for path in folders {
            for child in fm.children(of: env.resolve(path)) {
                var id = Self.stem(child.lastPathComponent)
                if path.hasSuffix("Containers"), let meta = Self.containerIdentifier(child) { id = meta.lowercased() }
                guard Self.looksLikeBundleID(id), !Self.isSystemID(id) else { continue }
                if ids.contains(where: { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { continue }
                // Same vendor as something installed ("com.google.Keystone" next to Chrome): most likely a
                // helper of living software, so leave it. Missing a real leftover is the cheaper mistake.
                if vendors.contains(Self.vendor(id)) { continue }
                out.append(Leftover(url: child, size: FileSize.of(child), location: path))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// First two components of a bundle ID: "com.google.Chrome" → "com.google".
    static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let tlds: Set<String> = ["com", "org", "net", "io", "de", "co", "app", "dev", "me", "ru", "ua", "uk", "info"]
        return tlds.contains(String(parts[0])) && s.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    static func isSystemID(_ s: String) -> Bool {
        ["com.apple.", "com.openssh.", "org.cups.", "com.microsoft.autoupdate"].contains { s.hasPrefix($0) }
    }
}

public struct UninstallPlan: Sendable {
    public let app: AppInfo
    public let appSize: Int64
    public let leftovers: [Leftover]
    public var total: Int64 { appSize + leftovers.reduce(0) { $0 + $1.size } }

    public func targets(includingApp: Bool, selectedLeftovers: Set<String>) -> [(url: URL, size: Int64)] {
        var t: [(url: URL, size: Int64)] = includingApp ? [(app.url, appSize)] : []
        t += leftovers.filter { selectedLeftovers.contains($0.id) }.map { ($0.url, $0.size) }
        return t
    }
}

public enum Uninstaller {
    public static func plan(for app: AppInfo, env: SweepEnvironment) -> UninstallPlan {
        UninstallPlan(app: app, appSize: FileSize.of(app.url), leftovers: LeftoverFinder(env: env).leftovers(for: app))
    }
}
