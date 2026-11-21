import Foundation

/// Cloud Cleanup: files from iCloud Drive / Dropbox / Google Drive / OneDrive that are stored locally
/// and could be left only in the cloud.
public enum CloudProvider: String, CaseIterable, Sendable {
    case iCloud = "iCloud Drive", dropbox = "Dropbox", googleDrive = "Google Drive", oneDrive = "OneDrive"

    /// Local sync folders, relative to home.
    public func roots(env: SweepEnvironment) -> [URL] {
        let fm = FileManager.default
        switch self {
        case .iCloud:
            return [env.resolve("~/Library/Mobile Documents/com~apple~CloudDocs")]
        case .dropbox, .googleDrive, .oneDrive:
            // File Provider based clients live in ~/Library/CloudStorage/<Provider>-<account>.
            let prefix = ["Dropbox": "Dropbox", "Google Drive": "GoogleDrive", "OneDrive": "OneDrive"][rawValue]!
            var r = fm.children(of: env.resolve("~/Library/CloudStorage")).filter { $0.lastPathComponent.hasPrefix(prefix) }
            if self == .dropbox { r.append(env.resolve("~/Dropbox")) }
            return r.filter { fm.fileExists(atPath: $0.path) }
        }
    }
}

public struct CloudFile: Identifiable, Sendable {
    public var id: String { entry.id }
    public let entry: FileEntry
    public let provider: CloudProvider
}

public struct CloudScanner: Sendable {
    public let env: SweepEnvironment
    /// Whether a file is fully downloaded. Injected so tests do not need a real iCloud account.
    public var isLocal: @Sendable (URL) -> Bool

    public init(env: SweepEnvironment, isLocal: @escaping @Sendable (URL) -> Bool = CloudScanner.isDownloaded) {
        self.env = env; self.isLocal = isLocal
    }

    public func scan(minSize: Int64 = 10 * 1_048_576) -> [CloudFile] {
        CloudProvider.allCases.flatMap { provider in
            provider.roots(env: env).flatMap { root in
                FileWalker(skip: env.exclusions).files(under: root, minSize: minSize)
                    .filter { isLocal($0.url) }
                    .map { CloudFile(entry: $0, provider: provider) }
            }
        }
        .sorted { $0.entry.size > $1.entry.size }
    }

    public static let isDownloaded: @Sendable (URL) -> Bool = { url in
        let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
        if v?.isUbiquitousItem == true { return v?.ubiquitousItemDownloadingStatus == .current }
        return true // non-iCloud providers: a file with allocated blocks is local
    }

    /// Frees the local copy; the file stays in the cloud.
    public static func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
