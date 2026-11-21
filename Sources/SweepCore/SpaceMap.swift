import Foundation

/// A folder-size tree for the Space Map view.
public final class DiskNode: Identifiable, @unchecked Sendable {
    public let url: URL
    public let isDirectory: Bool
    public private(set) var size: Int64
    public private(set) var children: [DiskNode]

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, size: Int64, children: [DiskNode]) {
        self.url = url; self.isDirectory = isDirectory; self.size = size; self.children = children
    }

    /// Share of the parent, 0...1.
    public func fraction(of parent: DiskNode) -> Double { parent.size > 0 ? Double(size) / Double(parent.size) : 0 }
}

public enum SpaceMap {
    /// Builds the tree. Folders deeper than `depth` are summed but not expanded.
    public static func build(_ url: URL, depth: Int = 2, cancelled: () -> Bool = { false }) -> DiskNode {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        let isDir = values?.isDirectory == true && values?.isSymbolicLink != true
        guard isDir, values?.isPackage != true, depth > 0, !cancelled() else {
            return DiskNode(url: url, isDirectory: isDir, size: FileSize.of(url), children: [])
        }
        let kids = fm.children(of: url).map { build($0, depth: depth - 1, cancelled: cancelled) }
            .sorted { $0.size > $1.size }
        return DiskNode(url: url, isDirectory: true, size: kids.reduce(0) { $0 + $1.size }, children: kids)
    }

    /// The biggest children, the rest lumped into one "other" bucket of the given size.
    public static func top(_ node: DiskNode, limit: Int) -> (shown: [DiskNode], otherSize: Int64) {
        let shown = Array(node.children.prefix(limit))
        let other = node.children.dropFirst(limit).reduce(Int64(0)) { $0 + $1.size }
        return (shown, other)
    }
}
