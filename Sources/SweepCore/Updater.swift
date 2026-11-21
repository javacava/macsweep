import Foundation

public enum VersionCompare {
    /// Compares dotted versions numerically: "1.10" > "1.9", "2.0" == "2", "1.2b3" < "1.2".
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.nums.count, pb.nums.count) {
            let x = i < pa.nums.count ? pa.nums[i] : 0
            let y = i < pb.nums.count ? pb.nums[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        // Same numbers: a pre-release suffix (beta, rc...) is older than the plain release.
        switch (pa.pre, pb.pre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x == y ? .orderedSame : (x.compare(y, options: .numeric) == .orderedAscending ? .orderedAscending : .orderedDescending)
        }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func parts(_ v: String) -> (nums: [Int], pre: String?) {
        let trimmed = v.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        var nums: [Int] = []
        var current = ""
        var rest: Substring = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let c = trimmed[idx]
            if c.isNumber { current.append(c) }
            else if c == "." { if !current.isEmpty { nums.append(Int(current) ?? 0); current = "" } }
            else { rest = trimmed[idx...]; break }
            idx = trimmed.index(after: idx)
        }
        if !current.isEmpty { nums.append(Int(current) ?? 0) }
        while nums.count > 1, nums.last == 0 { nums.removeLast() }
        let pre = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        return (nums, pre.isEmpty ? nil : pre)
    }
}

public struct AppcastItem: Equatable, Sendable {
    public var title: String?
    public var shortVersion: String?
    public var build: String?
    public var downloadURL: URL?
    public var minimumSystemVersion: String?
    public var displayVersion: String { shortVersion ?? build ?? "?" }
    /// The download link, only when it is plain https. A feed must not make us open file:// or app-scheme URLs.
    public var safeDownloadURL: URL? { downloadURL.flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil } }
}

/// Parses Sparkle appcast feeds (RSS with `sparkle:` attributes or elements).
public final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""

    public static func parse(_ data: Data) -> [AppcastItem] {
        let p = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.items
    }

    /// The newest release, optionally skipping ones that need a newer macOS.
    public static func latest(_ items: [AppcastItem], systemVersion: String? = nil) -> AppcastItem? {
        items.filter { item in
            guard let sys = systemVersion, let min = item.minimumSystemVersion else { return true }
            return VersionCompare.compare(min, sys) != .orderedDescending
        }
        .max { VersionCompare.compare($0.build ?? $0.displayVersion, $1.build ?? $1.displayVersion) == .orderedAscending }
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                       qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = AppcastItem() }
        if name == "enclosure", current != nil {
            if let u = attributes["url"] { current?.downloadURL = URL(string: u) }
            if let v = attributes["sparkle:shortVersionString"] { current?.shortVersion = v }
            if let v = attributes["sparkle:version"] { current?.build = v }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let c = current { items.append(c) }; current = nil
        case "title": if current != nil { current?.title = t }
        case "sparkle:shortVersionString": current?.shortVersion = t
        case "sparkle:version": current?.build = t
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = t
        default: break
        }
        text = ""
    }
}

public struct AppUpdate: Identifiable, Sendable {
    public var id: String { app.id }
    public let app: AppInfo
    public let latest: AppcastItem
}

public enum UpdateChecker {
    /// Checks an app's Sparkle feed. Returns nil when the app is current or has no feed.
    public static func check(_ app: AppInfo, session: URLSession = .shared) async -> AppUpdate? {
        guard let feed = app.feedURL, feed.scheme == "https" else { return nil }
        guard let (data, _) = try? await session.data(from: feed) else { return nil }
        return evaluate(app, feedData: data)
    }

    public static func evaluate(_ app: AppInfo, feedData: Data, systemVersion: String? = currentSystemVersion) -> AppUpdate? {
        guard let item = AppcastParser.latest(AppcastParser.parse(feedData), systemVersion: systemVersion) else { return nil }
        let newer: Bool
        if let b = item.build, !app.build.isEmpty, item.shortVersion == nil || item.shortVersion == app.version {
            newer = VersionCompare.isNewer(b, than: app.build)
        } else {
            newer = VersionCompare.isNewer(item.displayVersion, than: app.version)
        }
        return newer ? AppUpdate(app: app, latest: item) : nil
    }

    public static var currentSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
