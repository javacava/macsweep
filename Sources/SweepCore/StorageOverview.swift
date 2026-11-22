import Foundation

/// Everything the System Junk and Developer scanners found, grouped by area (AI, developer tools, projects,
/// apps, macOS) and by the tool, app or project that made it. The Storage page draws it as rings.
public struct StorageOverview: Sendable {
    /// One thing that can be shown and removed: a junk item or a developer item.
    public enum Item: Identifiable, Hashable, Sendable {
        case junk(JunkItem)
        case dev(DevItem)

        public var id: String {
            switch self { case .junk(let j): "junk:" + j.id; case .dev(let d): "dev:" + d.id }
        }
        public var size: Int64 { switch self { case .junk(let j): j.size; case .dev(let d): d.size } }
        public var safety: Safety { switch self { case .junk(let j): j.safety; case .dev(let d): d.safety } }
        public var selectedByDefault: Bool {
            switch self { case .junk(let j): j.selectedByDefault; case .dev(let d): d.selectedByDefault && d.isRemovable }
        }
        public var isRemovable: Bool { safety != .kept }
        public var location: URL? { switch self { case .junk(let j): j.url; case .dev(let d): d.location } }
        public var title: String {
            switch self { case .junk(let j): j.url.lastPathComponent; case .dev(let d): d.title }
        }
        public var paths: [URL] {
            switch self {
            case .junk(let j): return [j.url]
            case .dev(let d): if case .files(let u) = d.removal { return u }; return d.location.map { [$0] } ?? []
            }
        }
    }

    /// One tool, app or project and what it holds.
    public struct Owner: Identifiable, Sendable {
        public var id: String { area.rawValue + "/" + name }
        public let name: String
        public let area: SupportedTools.Area
        public var items: [Item]

        public var size: Int64 { items.reduce(0) { $0 + $1.size } }
        public func size(_ safety: Safety) -> Int64 { items.filter { $0.safety == safety }.reduce(0) { $0 + $1.size } }
    }

    public var owners: [Owner]

    public init(owners: [Owner]) { self.owners = owners }

    public var size: Int64 { owners.reduce(0) { $0 + $1.size } }
    public func size(_ safety: Safety) -> Int64 { owners.reduce(0) { $0 + $1.size(safety) } }
    public func owners(in area: SupportedTools.Area) -> [Owner] { owners.filter { $0.area == area } }
    public func size(of area: SupportedTools.Area) -> Int64 { owners(in: area).reduce(0) { $0 + $1.size } }
    /// Areas that hold anything, biggest first.
    public var areas: [SupportedTools.Area] {
        SupportedTools.Area.allCases.filter { size(of: $0) > 0 }.sorted { size(of: $0) > size(of: $1) }
    }

    public static func area(of item: DevItem) -> SupportedTools.Area {
        switch item.group {
        case .aiTools, .aiModels: .ai
        case .builds: .projects
        default: .developer
        }
    }

    public static func area(of item: JunkItem) -> SupportedTools.Area {
        switch item.category {
        case .appCaches, .browserCache, .mailAttachments, .containerCaches: .apps
        case .xcode, .devTools: .developer
        default: .macOS
        }
    }

    public static func owner(of item: JunkItem) -> String {
        JunkRules.all.first { $0.id == item.ruleID }?.tool ?? item.category.title
    }

    /// Builds the overview. A junk item that overlaps a developer item (the same folder, or one inside the
    /// other) is left out: the developer page knows the tool better, and nothing is counted twice.
    public static func build(junk: [JunkItem], dev: [DevItem]) -> StorageOverview {
        let devPaths = dev.flatMap { d -> [String] in
            if case .files(let urls) = d.removal { return urls.map(\.standardizedFileURL.path) }
            return d.location.map { [$0.standardizedFileURL.path] } ?? []
        }
        let devSet = Set(devPaths)
        func overlaps(_ path: String) -> Bool {
            if devSet.contains(path) { return true }
            let prefix = path + "/"
            return devPaths.contains { $0.hasPrefix(prefix) || path.hasPrefix($0 + "/") }
        }
        var byOwner: [String: Owner] = [:]
        func add(_ name: String, _ area: SupportedTools.Area, _ item: Item) {
            let key = area.rawValue + "/" + name
            byOwner[key, default: Owner(name: name, area: area, items: [])].items.append(item)
        }
        for d in dev where d.size > 0 { add(d.owner, area(of: d), .dev(d)) }
        for j in junk where j.size > 0 && !overlaps(j.url.standardizedFileURL.path) {
            add(owner(of: j), area(of: j), .junk(j))
        }
        let owners = byOwner.values.map { o -> Owner in
            var o = o
            o.items.sort { $0.size > $1.size }
            return o
        }
        return StorageOverview(owners: owners.sorted { $0.size > $1.size })
    }

    /// For the rings: owners smaller than `minShare` of their area are folded into one "Other" slice.
    public func ringOwners(in area: SupportedTools.Area, minShare: Double = 0.03) -> [Owner] {
        let all = owners(in: area)
        let total = Double(max(size(of: area), 1))
        let big = all.filter { Double($0.size) / total >= minShare }
        let small = all.filter { Double($0.size) / total < minShare }
        guard small.count > 1 else { return all }
        return big + [Owner(name: "Other", area: area, items: small.flatMap(\.items).sorted { $0.size > $1.size })]
    }
}
