import Foundation

// MARK: - Language versions

/// Versions installed by version managers (pyenv, rbenv, nvm, fnm, asdf, mise). One row per version.
/// The default version of each tool is listed as kept; when the default cannot be read, the newest is kept.
public struct ToolVersionScanner: Sendable {
    public let env: SweepEnvironment
    public init(env: SweepEnvironment) { self.env = env }

    /// A folder whose children are versions of one runtime.
    struct Source {
        let manager: String
        let runtime: String
        let dir: URL
        /// Versions named as the default; matched exactly or as a prefix ("20" keeps "v20.11.1").
        let defaults: [String]
    }

    static let managers = ["pyenv", "rbenv", "nvm", "fnm", "asdf", "mise"]

    public func scan() -> [DevItem] {
        sources().flatMap(items)
    }

    func sources() -> [Source] {
        var out: [Source] = []
        let fm = FileManager.default
        out.append(Source(manager: "pyenv", runtime: "Python", dir: env.resolve("~/.pyenv/versions"),
                          defaults: Self.words(env.resolve("~/.pyenv/version"))))
        out.append(Source(manager: "rbenv", runtime: "Ruby", dir: env.resolve("~/.rbenv/versions"),
                          defaults: Self.words(env.resolve("~/.rbenv/version"))))
        out.append(Source(manager: "nvm", runtime: "Node", dir: env.resolve("~/.nvm/versions/node"),
                          defaults: Self.words(env.resolve("~/.nvm/alias/default"))))
        for root in ["~/.local/share/fnm", "~/Library/Application Support/fnm"].map(env.resolve) {
            let link = root.appendingPathComponent("aliases/default")
            let target = (try? fm.destinationOfSymbolicLink(atPath: link.path))
                .map { URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL }
            // aliases/default → …/node-versions/v20.11.1/installation
            let version = target?.pathComponents.first { $0.hasPrefix("v") && $0.first(where: \.isNumber) != nil }
            out.append(Source(manager: "fnm", runtime: "Node", dir: root.appendingPathComponent("node-versions"),
                              defaults: version.map { [$0] } ?? []))
        }
        // asdf and mise: installs/<tool>/<version>, defaults in ~/.tool-versions and mise's global config.
        let toolVersions = Self.toolVersionsFile(env.resolve("~/.tool-versions"))
        for tool in fm.children(of: env.resolve("~/.asdf/installs")) where tool.isDirectoryURL {
            out.append(Source(manager: "asdf", runtime: tool.lastPathComponent, dir: tool,
                              defaults: toolVersions[tool.lastPathComponent] ?? []))
        }
        var mise = toolVersions
        mise.merge(Self.miseConfig(env.resolve("~/.config/mise/config.toml"))) { _, new in new }
        for tool in fm.children(of: env.resolve("~/.local/share/mise/installs")) where tool.isDirectoryURL {
            out.append(Source(manager: "mise", runtime: tool.lastPathComponent, dir: tool,
                              defaults: mise[tool.lastPathComponent] ?? []))
        }
        return out
    }

    func items(_ source: Source) -> [DevItem] {
        let fm = FileManager.default
        // Version managers keep aliases ("20", "latest", "lts") as symlinks next to the real folders: skip those.
        let versions = fm.children(of: source.dir).filter { url in
            !url.lastPathComponent.hasPrefix(".") && url.isDirectoryURL
                && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
        guard !versions.isEmpty else { return [] }
        let names = versions.map(\.lastPathComponent)
        var kept = Set(names.filter { Self.matches($0, any: source.defaults) })
        if kept.isEmpty, let newest = names.max(by: { VersionCompare.compare($0, $1) == .orderedAscending }) {
            kept.insert(newest)
        }
        return versions.compactMap { v in
            guard !env.isExcluded(v) else { return nil }
            let size = FileSize.of(v)
            guard size > 0 else { return nil }
            let name = v.lastPathComponent
            let isKept = kept.contains(name)
            let why = source.defaults.isEmpty ? "newest" : "default"
            return DevItem(id: v.path, group: .toolVersions, title: "\(source.runtime) \(name)",
                           detail: source.manager + (isKept ? " · \(why) version" : ""), size: size, removal: .files([v]),
                           location: v, lastUsed: v.modificationDate, safetyOverride: isKept ? .kept : nil, tool: source.manager)
        }
    }

    /// "v20.11.1" matches "20", "v20", "20.11" and "20.11.1"; "3.12.4" matches "3.12".
    static func matches(_ version: String, any defaults: [String]) -> Bool {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return defaults.contains { d in
            let d = d.hasPrefix("v") ? String(d.dropFirst()) : d
            return !d.isEmpty && (v == d || v.hasPrefix(d + "."))
        }
    }

    static func words(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.hasPrefix("#") }
    }

    /// `~/.tool-versions`: "nodejs 20.11.1 18.19.0" per line.
    static func toolVersionsFile(_ file: URL) -> [String: [String]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
            out[parts[0]] = Array(parts.dropFirst())
        }
        return out
    }

    /// The `[tools]` table of mise's config: `node = "20"` or `python = ["3.12", "3.11"]`.
    static func miseConfig(_ file: URL) -> [String: [String]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: [String]] = [:]
        var inTools = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTools = line == "[tools]"; continue }
            guard inTools, let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = line[line.index(after: eq)...]
            let versions = value.split(whereSeparator: { "[],\"' ".contains($0) }).map(String.init).filter { !$0.isEmpty }
            if !key.isEmpty, !versions.isEmpty { out[key] = versions }
        }
        return out
    }
}

// MARK: - Virtual machine disks

/// Disks of container and VM tools. They hold the user's containers, images and VMs, so they are only shown,
/// with the command that shrinks them.
public struct VirtualMachineDisks: Sendable {
    public let env: SweepEnvironment
    public init(env: SweepEnvironment) { self.env = env }

    static let disks: [(tool: String, path: String, how: String)] = [
        ("Docker Desktop", "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
         "shrink it with the Docker section below or `docker system prune`"),
        ("OrbStack", "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", "remove machines with `orb delete NAME`"),
        ("Colima", "~/.colima", "remove a profile with `colima delete`"),
        ("Podman", "~/.local/share/containers/podman/machine", "remove a machine with `podman machine rm NAME`"),
    ]

    public func scan() -> [DevItem] {
        var out: [DevItem] = []
        for d in Self.disks {
            let url = env.resolve(d.path)
            guard FileManager.default.fileExists(atPath: url.path), !env.isExcluded(url) else { continue }
            let size = FileSize.of(url)
            guard size > 0 else { continue }
            out.append(DevItem(id: url.path, group: .virtualMachines, title: d.tool, detail: "Kept · " + d.how,
                               size: size, removal: .files([url]), location: url, safetyOverride: .kept, tool: d.tool))
        }
        // Lima: one folder per instance; folders starting with "_" are its own config and cache.
        for vm in FileManager.default.children(of: env.resolve("~/.lima")) where vm.isDirectoryURL
            && !vm.lastPathComponent.hasPrefix("_") && !vm.lastPathComponent.hasPrefix(".") && !env.isExcluded(vm) {
            let size = FileSize.of(vm)
            guard size > 0 else { continue }
            out.append(DevItem(id: vm.path, group: .virtualMachines, title: "Lima · \(vm.lastPathComponent)",
                               detail: "Kept · remove it with `limactl delete \(vm.lastPathComponent)`", size: size,
                               removal: .files([vm]), location: vm, safetyOverride: .kept, tool: "Lima"))
        }
        return out
    }
}
