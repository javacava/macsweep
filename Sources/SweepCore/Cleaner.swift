import Foundation

/// The last line of defence: every path the app deletes goes through `check`.
public struct SafetyGuard: Sendable {
    public let env: SweepEnvironment

    public init(env: SweepEnvironment) { self.env = env }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    /// Folders that may only be emptied, never removed themselves.
    var protectedFolders: [URL] {
        let homeDirs = ["", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
                        "Library/Preferences", "Library/Containers", "Library/Group Containers",
                        "Library/LaunchAgents", "Library/Mail", "Library/Keychains", "Documents", "Desktop",
                        "Downloads", "Pictures", "Movies", "Music", "Applications", ".Trash",
                        "Library/Developer", "Library/Developer/Xcode", "Library/Developer/Xcode/DerivedData",
                        "Library/Mobile Documents", "Library/Mobile Documents/com~apple~CloudDocs",
                        "Library/CloudStorage", "Library/Safari", "Library/Messages", "Library/Calendars",
                        "Library/Photos", "Library/Application Support/AddressBook",
                        "Library/Application Support/MobileSync", "Library/Application Support/MobileSync/Backup",
                        "Library/Containers/com.apple.mail", "Library/Saved Application State",
                        "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/Application Scripts",
                        ".ssh", ".gnupg", "Public"]
        let rootDirs = ["", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
                        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Preferences", "Applications",
                        "Users", "private", "private/var", "private/var/log", "System", "usr", "bin", "sbin", "etc", "var"]
        return homeDirs.map { $0.isEmpty ? env.home : env.home.appendingPathComponent($0) }
            + rootDirs.map { $0.isEmpty ? env.root : env.root.appendingPathComponent($0) }
    }

    /// Trees nothing inside of which is ever removed.
    var forbiddenTrees: [URL] {
        ["System", "usr", "bin", "sbin", "private/etc", "private/var/db", "Library/Apple"]
            .map { env.root.appendingPathComponent($0) }
            + [env.home.appendingPathComponent("Library/Keychains")]
    }

    /// Where removable things may live at all.
    var allowedTrees: [URL] {
        [env.home, env.root.appendingPathComponent("Library"), env.root.appendingPathComponent("Applications"),
         env.root.appendingPathComponent("private/var/log"), env.root.appendingPathComponent("Users/Shared"),
         env.root.appendingPathComponent("private/tmp"), env.root.appendingPathComponent("private/var/tmp")]
    }

    public func check(_ url: URL) -> Verdict {
        let raw = url.path
        if raw.isEmpty || !raw.hasPrefix("/") { return .denied("Path is not absolute") }
        if raw.split(separator: "/").contains("..") { return .denied("Path contains \"..\"") }
        let u = url.standardizedFileURL.resolvingSymlinksInParent()
        if env.isExcluded(u) { return .denied("Excluded in Settings") }
        let path = Self.canonical(u.path)
        func inside(_ p: String, _ tree: String) -> Bool { p == tree || p.hasPrefix(tree.hasSuffix("/") ? tree : tree + "/") }
        // Deny rules compare case-insensitively: on a default (case-insensitive) APFS volume
        // `~/documents` and `~/Documents` are the same folder.
        let folded = Self.fold(path)
        if protectedFolders.contains(where: { Self.fold(Self.canonical($0.standardizedFileURL.path)) == folded }) {
            return .denied("Protected system folder")
        }
        if forbiddenTrees.contains(where: { inside(folded, Self.fold(Self.canonical($0.standardizedFileURL.path))) }) {
            return .denied("System area")
        }
        if u.pathComponents.contains(where: { Self.mediaLibraryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return .denied("Media library (Photos, Music): remove its contents in the app itself")
        }
        if !allowedTrees.contains(where: { tree in
            let t = Self.canonical(tree.standardizedFileURL.path)
            return path != t && inside(path, t)
        }) {
            return .denied("Outside the allowed folders")
        }
        if u.pathExtension == "app", u.deletingLastPathComponent().lastPathComponent == "Applications",
           Self.appleSystemApps.contains(u.deletingPathExtension().lastPathComponent) {
            return .denied("Built-in Apple app")
        }
        return .allowed
    }

    /// macOS reports `/private/var`, `/private/tmp`, `/private/etc` with or without `/private`
    /// depending on the API. Both spellings are reduced to one before any comparison.
    static func canonical(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    static func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// Library packages that hold a whole photo/music collection. Never removed, not even partly.
    static let mediaLibraryExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "imovielibrary", "fcpbundle"]

    static let appleSystemApps: Set<String> = ["Safari", "Finder", "App Store", "System Settings", "Mail", "Messages"]
}

private extension URL {
    /// Resolves symlinks in the parent only, so a symlink itself is removed and its target is left alone.
    func resolvingSymlinksInParent() -> URL {
        let parent = deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(lastPathComponent).standardizedFileURL
    }
}

public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    case trash, permanent
}

public protocol FileRemoving: Sendable {
    /// Moves the item to the Trash and returns where it landed (nil when unknown).
    @discardableResult func moveToTrash(_ url: URL) throws -> URL?
    func removePermanently(_ url: URL) throws
}

public struct SystemFileRemover: FileRemoving {
    public init() {}
    public func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
    public func removePermanently(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Something MyOpenCleaner moved to the Trash, and where it came from, so it can be put back.
public struct TrashedItem: Codable, Equatable, Sendable {
    public let original: URL
    public let inTrash: URL
    public let size: Int64

    public init(original: URL, inTrash: URL, size: Int64) {
        self.original = original; self.inTrash = inTrash; self.size = size
    }
}

public struct CleanReport: Sendable {
    public var removed: [URL] = []
    public var failed: [(url: URL, reason: String)] = []
    public var freedBytes: Int64 = 0
    /// The removed items that went to the Trash (the rest were deleted for good).
    public var trashed: [TrashedItem] = []

    public init() {}

    public mutating func merge(_ other: CleanReport) {
        removed += other.removed; failed += other.failed
        freedBytes += other.freedBytes; trashed += other.trashed
    }
}

public struct Cleaner: Sendable {
    public let safety: SafetyGuard
    public let remover: FileRemoving
    public var mode: RemovalMode

    public init(env: SweepEnvironment, remover: FileRemoving = SystemFileRemover(), mode: RemovalMode = .trash) {
        self.safety = SafetyGuard(env: env)
        self.remover = remover
        self.mode = mode
    }

    /// Removes each path that passes the safety guard. Things already in the Trash are deleted for good.
    public func remove(_ targets: [(url: URL, size: Int64)]) -> CleanReport {
        var report = CleanReport()
        let trash = safety.env.home.appendingPathComponent(".Trash")
        // Drop targets nested inside another target, they go away with their parent.
        let sorted = targets.sorted { $0.url.path.count < $1.url.path.count }
        var taken: [URL] = []
        for t in sorted {
            if taken.contains(where: { t.url.isInside($0) }) { continue }
            if case .denied(let why) = safety.check(t.url) {
                report.failed.append((t.url, why))
                continue
            }
            do {
                if mode == .permanent || t.url.isInside(trash) {
                    try remover.removePermanently(t.url)
                } else {
                    if let landed = try remover.moveToTrash(t.url) {
                        report.trashed.append(TrashedItem(original: t.url, inTrash: landed, size: t.size))
                    }
                }
                report.removed.append(t.url)
                report.freedBytes += t.size
                taken.append(t.url)
            } catch {
                report.failed.append((t.url, error.localizedDescription))
            }
        }
        return report
    }

    public func remove(_ items: [JunkItem]) -> CleanReport {
        remove(items.map { ($0.url, $0.size) })
    }
}
