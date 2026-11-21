import Foundation
import CryptoKit

public enum FileKind: String, CaseIterable, Sendable, Codable {
    case video, audio, image, archive, diskImage, virtualMachine, document, code, other

    public var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .archive: "Archives"
        case .diskImage: "Disk images"
        case .virtualMachine: "Virtual machines"
        case .document: "Documents"
        case .code: "Code"
        case .other: "Other"
        }
    }

    public static func of(_ url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv": .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg": .audio
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "nef", "dng", "psd": .image
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": .archive
        case "pvm", "utm", "vmwarevm", "vbox", "vmdk", "vdi", "qcow2", "hdd", "macvm", "vmx": .virtualMachine
        case "dmg", "iso", "img", "pkg", "xip", "sparseimage", "sparsebundle": .diskImage
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "epub": .document
        case "swift", "js", "ts", "py", "c", "h", "m", "java", "go", "rs", "json": .code
        default: .other
        }
    }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let modified: Date?
    public let accessed: Date?
    public var kind: FileKind { FileKind.of(url) }
}

/// Walks a folder tree for regular files, skipping hidden items, app bundles' insides and `~/Library`.
public struct FileWalker: Sendable {
    static let vmBundles: Set<String> = ["pvm", "utm", "vmwarevm", "macvm"]

    public var skip: [URL]
    public var includeHidden = false

    public init(skip: [URL] = []) { self.skip = skip }

    public func files(under root: URL, minSize: Int64 = 0, cancelled: () -> Bool = { false }) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
                                      .contentAccessDateKey, .isPackageKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options,
                                                     errorHandler: { _, _ in true }) else { return [] }
        var out: [FileEntry] = []
        for case let url as URL in e {
            if cancelled() { break }
            if skip.contains(where: { url.isInside($0) }) { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size: Int64
            // VM bundles are folders; count them as one item even when their app is not installed.
            if v.isPackage == true || Self.vmBundles.contains(url.pathExtension.lowercased()) {
                e.skipDescendants()
                size = FileSize.of(url)
            } else {
                guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                size = FileSize.single(v)
            }
            guard size >= minSize else { continue }
            out.append(FileEntry(url: url, size: size, modified: v.contentModificationDate, accessed: v.contentAccessDate))
        }
        return out
    }
}

public struct LargeOldFinder: Sendable {
    public let env: SweepEnvironment
    public init(env: SweepEnvironment) { self.env = env }

    /// Files of at least `minSize`, or (when `olderThanDays` is set) also untouched for that many days.
    public func find(minSize: Int64 = 100 * 1_048_576, olderThanDays: Int? = nil,
                     roots: [URL]? = nil, cancelled: () -> Bool = { false }) -> [FileEntry] {
        let walker = FileWalker(skip: env.exclusions + [env.home.appendingPathComponent("Library"),
                                       env.home.appendingPathComponent(".Trash")])
        let scanRoots = roots ?? [env.home]
        let cutoff = olderThanDays.map { env.now().addingTimeInterval(-Double($0) * 86_400) }
        return scanRoots.flatMap { walker.files(under: $0, minSize: minSize, cancelled: cancelled) }
            .filter { f in
                guard let cutoff else { return true }
                let last = [f.accessed, f.modified].compactMap { $0 }.max() ?? .distantPast
                return last < cutoff
            }
            .sorted { $0.size > $1.size }
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let files: [FileEntry]
    public var fileSize: Int64 { files.first?.size ?? 0 }
    /// Space freed by keeping one copy.
    public var wasted: Int64 { fileSize * Int64(max(files.count - 1, 0)) }

    /// Suggests which copies to delete: keeps the oldest one (ties: shortest path).
    public var suggestedRemovals: [FileEntry] {
        let keep = files.min { a, b in
            let da = a.modified ?? .distantFuture, db = b.modified ?? .distantFuture
            return da != db ? da < db : a.url.path.count < b.url.path.count
        }
        return files.filter { $0 != keep }
    }
}

public enum DuplicateFinder {
    /// Groups identical files: by size, then a hash of the first 64 KB, then a full SHA-256.
    public static func find(in files: [FileEntry], minSize: Int64 = 1) -> [DuplicateGroup] {
        // `size > 0` skips cloud-only placeholders (no blocks on disk): hashing them would download every file.
        let candidates = files.filter { $0.size > 0 && !$0.url.isDirectoryURL && logicalSize($0.url) >= minSize }
        let bySize = Dictionary(grouping: candidates) { logicalSize($0.url) }
        var groups: [DuplicateGroup] = []
        for (_, same) in bySize where same.count > 1 {
            let byHead = Dictionary(grouping: same) { hash($0.url, limit: 65_536) ?? UUID().uuidString }
            for (_, candidates) in byHead where candidates.count > 1 {
                let byFull = Dictionary(grouping: candidates) { hash($0.url, limit: nil) ?? UUID().uuidString }
                for (h, dupes) in byFull where dupes.count > 1 {
                    groups.append(DuplicateGroup(hash: h, files: dupes.sorted { $0.url.path < $1.url.path }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func logicalSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = (try? h.read(upToCount: min(1_048_576, remaining))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            sha.update(data: chunk)
            remaining -= chunk.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
