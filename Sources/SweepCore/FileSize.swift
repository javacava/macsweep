import Foundation

public enum FileSize {
    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Space a file or folder takes on disk. Symlinks are not followed.
    public static func of(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return single(values) }
        guard let e = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                             errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in e {
            guard let v = try? child.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            total += single(v)
        }
        return total
    }

    static func single(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public extension URL {
    var isDirectoryURL: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    var modificationDate: Date? { try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    var accessDate: Date? { try? resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }

    /// True when `self` equals `other` or lies inside it.
    func isInside(_ other: URL) -> Bool {
        let a = standardizedFileURL.path, b = other.standardizedFileURL.path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}

extension FileManager {
    func children(of url: URL) -> [URL] {
        (try? contentsOfDirectory(at: url, includingPropertiesForKeys: FileSize.keys, options: [])) ?? []
    }
}
