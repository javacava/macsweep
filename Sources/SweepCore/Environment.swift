import Foundation

/// Where the scanners look. Tests point `home` and `root` at temporary folders,
/// the app uses the real home folder and `/`.
public struct SweepEnvironment: Sendable {
    public var home: URL
    /// Paths the user never wants offered for removal (Settings → Exclusions).
    public var exclusions: [URL] = []
    public var root: URL
    public var now: @Sendable () -> Date

    public init(home: URL, root: URL = URL(fileURLWithPath: "/"), now: @escaping @Sendable () -> Date = { Date() }) {
        // Resolved so `/var/folders/...` and `/private/var/folders/...` compare equal.
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.now = now
    }

    public static var live: SweepEnvironment {
        SweepEnvironment(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `~/...` resolves against home, `/...` against root.
    public func resolve(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return trimmed.isEmpty ? root : root.appendingPathComponent(trimmed)
    }

    /// True when removing `url` would touch an excluded path: the path itself, something inside it,
    /// or a folder that contains it.
    public func isExcluded(_ url: URL) -> Bool {
        guard !exclusions.isEmpty else { return false }
        let u = url.resolvingSymlinksInPath().standardizedFileURL
        return exclusions.contains { e in
            let x = e.resolvingSymlinksInPath().standardizedFileURL
            return u.isInside(x) || x.isInside(u)
        }
    }

    /// The reverse of `resolve` for display: `/Users/x/Library` → `~/Library`.
    public func displayPath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if p == home.path { return "~" }
        if p.hasPrefix(home.path + "/") { return "~" + p.dropFirst(home.path.count) }
        if root.path != "/", p.hasPrefix(root.path + "/") { return String(p.dropFirst(root.path.count)) }
        return p
    }
}
