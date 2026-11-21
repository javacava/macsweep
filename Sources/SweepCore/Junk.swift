import Foundation

public enum JunkCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case userCache, systemCache, userLogs, systemLogs, browserCache, xcode, devTools
    case mailAttachments, trash, iosBackups, brokenDownloads, installers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCache: "User cache"
        case .systemCache: "System cache"
        case .userLogs: "User logs"
        case .systemLogs: "System logs"
        case .browserCache: "Browser cache"
        case .xcode: "Xcode junk"
        case .devTools: "Developer tool caches"
        case .mailAttachments: "Mail attachments"
        case .trash: "Trash"
        case .iosBackups: "iOS backups"
        case .brokenDownloads: "Incomplete downloads"
        case .installers: "Installers in Downloads"
        }
    }

    public var symbol: String {
        switch self {
        case .userCache, .systemCache: "internaldrive"
        case .userLogs, .systemLogs: "doc.text"
        case .browserCache: "safari"
        case .xcode: "hammer"
        case .devTools: "shippingbox"
        case .mailAttachments: "paperclip"
        case .trash: "trash"
        case .iosBackups: "iphone"
        case .brokenDownloads: "arrow.down.circle.dotted"
        case .installers: "opticaldiscdrive"
        }
    }
}

public struct JunkRule: Sendable, Identifiable {
    public enum Mode: Sendable, Equatable {
        /// Every direct child of the folder is one removable item.
        case children
        /// The folder's direct children that are files with one of these extensions.
        case files(extensions: Set<String>)
    }

    public let id: String
    public let category: JunkCategory
    public let path: String
    public let mode: Mode
    /// Child names (case-insensitive) that are never offered, usually because another rule owns them.
    public let excludes: Set<String>
    /// Only items not modified for this long are offered.
    public let minAge: TimeInterval?
    public let selectedByDefault: Bool

    public init(id: String, category: JunkCategory, path: String, mode: Mode = .children,
                excludes: Set<String> = [], minAge: TimeInterval? = nil, selectedByDefault: Bool = true) {
        self.id = id; self.category = category; self.path = path; self.mode = mode
        self.excludes = Set(excludes.map { $0.lowercased() }); self.minAge = minAge
        self.selectedByDefault = selectedByDefault
    }
}

public enum JunkRules {
    static let day: TimeInterval = 86_400

    /// Caches inside ~/Library/Caches that a more specific rule owns, or that must never be touched.
    static let userCacheExcludes: Set<String> = [
        // owned by browserCache
        "com.apple.Safari", "Google", "Firefox", "com.microsoft.edgemac", "BraveSoftware", "com.operasoftware.Opera",
        // owned by devTools
        "Homebrew", "Yarn", "pip", "CocoaPods", "org.swift.swiftpm", "com.apple.dt.Xcode",
        // system state that breaks things or re-downloads gigabytes when cleared
        "CloudKit", "com.apple.bird", "com.apple.akd", "com.apple.nsurlsessiond", "com.apple.HomeKit",
        "com.apple.ap.adprivacyd", "FamilyCircle", "com.apple.containermanagerd",
        "PassKit", "com.apple.passd", "GeoServices", "com.apple.findmy.fmipcore", "com.apple.findmy.fmfcore",
        "com.apple.homed", "com.apple.iCloudHelper", "com.apple.Photos", "com.apple.photoanalysisd",
    ]

    public static let all: [JunkRule] = [
        JunkRule(id: "user-caches", category: .userCache, path: "~/Library/Caches", excludes: userCacheExcludes),
        JunkRule(id: "system-caches", category: .systemCache, path: "/Library/Caches",
                 excludes: ["com.apple.iconservices.store", "com.apple.amsengagementd.classicdatavault"]),
        JunkRule(id: "user-logs", category: .userLogs, path: "~/Library/Logs"),
        JunkRule(id: "system-logs", category: .systemLogs, path: "/Library/Logs"),
        JunkRule(id: "system-var-logs", category: .systemLogs, path: "/private/var/log",
                 mode: .files(extensions: ["gz", "bz2", "old"])),

        JunkRule(id: "safari-cache", category: .browserCache, path: "~/Library/Caches/com.apple.Safari"),
        JunkRule(id: "chrome-cache", category: .browserCache, path: "~/Library/Caches/Google/Chrome"),
        JunkRule(id: "firefox-cache", category: .browserCache, path: "~/Library/Caches/Firefox/Profiles"),
        JunkRule(id: "edge-cache", category: .browserCache, path: "~/Library/Caches/com.microsoft.edgemac"),
        JunkRule(id: "brave-cache", category: .browserCache, path: "~/Library/Caches/BraveSoftware/Brave-Browser"),

        JunkRule(id: "xcode-derived", category: .xcode, path: "~/Library/Developer/Xcode/DerivedData"),
        JunkRule(id: "xcode-device-support", category: .xcode, path: "~/Library/Developer/Xcode/iOS DeviceSupport"),
        JunkRule(id: "xcode-watch-support", category: .xcode, path: "~/Library/Developer/Xcode/watchOS DeviceSupport"),
        JunkRule(id: "xcode-archives", category: .xcode, path: "~/Library/Developer/Xcode/Archives",
                 minAge: 180 * day, selectedByDefault: false),
        JunkRule(id: "xcode-cache", category: .xcode, path: "~/Library/Caches/com.apple.dt.Xcode"),
        JunkRule(id: "simulator-caches", category: .xcode, path: "~/Library/Developer/CoreSimulator/Caches"),

        JunkRule(id: "brew-cache", category: .devTools, path: "~/Library/Caches/Homebrew"),
        JunkRule(id: "yarn-cache", category: .devTools, path: "~/Library/Caches/Yarn"),
        JunkRule(id: "pip-cache", category: .devTools, path: "~/Library/Caches/pip"),
        JunkRule(id: "cocoapods-cache", category: .devTools, path: "~/Library/Caches/CocoaPods"),
        JunkRule(id: "swiftpm-cache", category: .devTools, path: "~/Library/Caches/org.swift.swiftpm"),
        JunkRule(id: "npm-cache", category: .devTools, path: "~/.npm/_cacache"),
        JunkRule(id: "gradle-cache", category: .devTools, path: "~/.gradle/caches"),
        JunkRule(id: "cargo-cache", category: .devTools, path: "~/.cargo/registry/cache"),

        JunkRule(id: "mail-downloads", category: .mailAttachments,
                 path: "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", minAge: 30 * day),
        JunkRule(id: "mail-downloads-legacy", category: .mailAttachments, path: "~/Library/Mail Downloads",
                 minAge: 30 * day),

        JunkRule(id: "trash", category: .trash, path: "~/.Trash"),
        JunkRule(id: "ios-backups", category: .iosBackups, path: "~/Library/Application Support/MobileSync/Backup",
                 selectedByDefault: false),
        JunkRule(id: "broken-downloads", category: .brokenDownloads, path: "~/Downloads",
                 mode: .files(extensions: ["crdownload", "part", "partial", "download", "opdownload"]), minAge: day),
        JunkRule(id: "installers", category: .installers, path: "~/Downloads",
                 mode: .files(extensions: ["dmg", "pkg", "mpkg", "xip"]), minAge: 7 * day, selectedByDefault: false),
    ]
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let category: JunkCategory
    public let ruleID: String
    public let selectedByDefault: Bool
}

public struct JunkScanResult: Sendable {
    public var items: [JunkItem]
    /// Folders a rule pointed at but could not read (usually missing permissions).
    public var unreadable: [URL]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var defaultSelection: Set<String> { Set(items.filter(\.selectedByDefault).map(\.id)) }

    public func items(in category: JunkCategory) -> [JunkItem] { items.filter { $0.category == category } }
    public func size(of category: JunkCategory) -> Int64 { items(in: category).reduce(0) { $0 + $1.size } }
    public var categories: [JunkCategory] { JunkCategory.allCases.filter { size(of: $0) > 0 } }
}

public final class JunkScanner: @unchecked Sendable {
    public let env: SweepEnvironment
    public let rules: [JunkRule]
    let fm = FileManager.default

    public init(env: SweepEnvironment, rules: [JunkRule] = JunkRules.all) {
        self.env = env
        self.rules = rules
    }

    public func scan(categories: Set<JunkCategory> = Set(JunkCategory.allCases),
                     progress: ((JunkRule) -> Void)? = nil) -> JunkScanResult {
        var result = JunkScanResult(items: [], unreadable: [])
        var claimed = Set<String>()
        for rule in rules where categories.contains(rule.category) {
            progress?(rule)
            let dir = env.resolve(rule.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileSize.keys) else {
                result.unreadable.append(dir)
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                if rule.excludes.contains(name.lowercased()) { continue }
                if case .files(let exts) = rule.mode {
                    guard exts.contains(child.pathExtension.lowercased()), !child.isDirectoryURL || child.pathExtension == "download"
                    else { continue }
                }
                if let minAge = rule.minAge {
                    // Unknown age counts as fresh: when in doubt, leave the file alone.
                    guard let mod = child.modificationDate, env.now().timeIntervalSince(mod) >= minAge else { continue }
                }
                // A path is offered once, by the first rule that reaches it.
                guard claimed.insert(child.standardizedFileURL.path).inserted else { continue }
                let size = FileSize.of(child)
                guard size > 0 else { continue }
                result.items.append(JunkItem(url: child, size: size, category: rule.category,
                                             ruleID: rule.id, selectedByDefault: rule.selectedByDefault))
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }
}
