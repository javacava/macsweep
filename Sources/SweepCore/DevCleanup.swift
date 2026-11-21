import Foundation

/// One thing the Developer page can remove: a simulator, a runtime, a firmware file, a cache, a build folder.
public struct DevItem: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case simulators, runtimes, firmware, xcode, android, packageCaches, aiTools, builds

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .simulators: "iOS simulators"
            case .runtimes: "Simulator runtimes"
            case .firmware: "Device firmware and symbols"
            case .xcode: "Xcode builds and caches"
            case .android: "Android emulators"
            case .packageCaches: "npm and other package manager caches"
            case .aiTools: "AI tool logs and caches"
            case .builds: "Builds and dependencies in projects"
            }
        }

        public var symbol: String {
            switch self {
            case .simulators: "iphone"
            case .runtimes: "cpu"
            case .firmware: "square.and.arrow.down.on.square"
            case .xcode: "hammer"
            case .android: "candybarphone"
            case .packageCaches: "shippingbox"
            case .aiTools: "brain"
            case .builds: "folder.badge.gearshape"
            }
        }

        public var hint: String {
            switch self {
            case .simulators: "Deletes the simulated device with every app and all data installed in it."
            case .runtimes: "iOS/watchOS/tvOS images for simulators. Download one again in Xcode → Settings → Components."
            case .firmware: "IPSW update files and the symbols Xcode copies from connected devices (copied again on the next connection)."
            case .xcode: "Intermediate build files. Xcode rebuilds them; the first build takes longer."
            case .android: "Android Studio virtual devices and downloaded system images."
            case .packageCaches: "Downloaded packages. The package manager fetches them again when needed."
            case .aiTools: "Logs and caches of local AI apps such as Ollama and LM Studio. Downloaded models and chat history are never offered."
            case .builds: "node_modules, .build, target, Pods and so on. Restored by the project's install or build command."
            }
        }
    }

    public enum Removal: Hashable, Sendable {
        /// Removed like any other file, through the safety guard (Trash or permanent).
        case files([URL])
        /// Removed by a tool, run directly without a shell: `xcrun simctl delete <udid>`.
        case command([String])
    }

    public let id: String
    public let group: Group
    public let title: String
    public let detail: String
    public let size: Int64
    public let removal: Removal
    public var selectedByDefault = false
    /// Where it lives, for "Reveal in Finder".
    public var location: URL? = nil
    public var lastUsed: Date? = nil
}

// MARK: - Folders (firmware, Xcode, Android, package caches)

struct DevFolderRule {
    enum Mode: Equatable { case children, whole }
    let group: DevItem.Group
    let title: String
    let path: String
    var mode: Mode = .whole
    var selected = true
}

public struct DevFolderScanner: Sendable {
    public let env: SweepEnvironment
    public init(env: SweepEnvironment) { self.env = env }

    static let rules: [DevFolderRule] = [
        // Firmware
        .init(group: .firmware, title: "iPhone firmware", path: "~/Library/iTunes/iPhone Software Updates", mode: .children),
        .init(group: .firmware, title: "iPad firmware", path: "~/Library/iTunes/iPad Software Updates", mode: .children),
        .init(group: .firmware, title: "iPod firmware", path: "~/Library/iTunes/iPod Software Updates", mode: .children),
        .init(group: .firmware, title: "Firmware (Apple Configurator)",
              path: "~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware", mode: .children),
        .init(group: .firmware, title: "iOS symbols", path: "~/Library/Developer/Xcode/iOS DeviceSupport", mode: .children),
        .init(group: .firmware, title: "watchOS symbols", path: "~/Library/Developer/Xcode/watchOS DeviceSupport", mode: .children),
        .init(group: .firmware, title: "tvOS symbols", path: "~/Library/Developer/Xcode/tvOS DeviceSupport", mode: .children),
        .init(group: .firmware, title: "visionOS symbols", path: "~/Library/Developer/Xcode/visionOS DeviceSupport", mode: .children),
        // Xcode
        .init(group: .xcode, title: "DerivedData", path: "~/Library/Developer/Xcode/DerivedData", mode: .children),
        .init(group: .xcode, title: "Archive", path: "~/Library/Developer/Xcode/Archives", mode: .children, selected: false),
        .init(group: .xcode, title: "Xcode cache", path: "~/Library/Caches/com.apple.dt.Xcode"),
        .init(group: .xcode, title: "Simulator cache", path: "~/Library/Developer/CoreSimulator/Caches"),
        .init(group: .xcode, title: "SwiftUI Previews simulators", path: "~/Library/Developer/Xcode/UserData/Previews/Simulator Devices"),
        .init(group: .xcode, title: "Device logs", path: "~/Library/Developer/Xcode/iOS Device Logs"),
        .init(group: .xcode, title: "Documentation cache", path: "~/Library/Developer/Xcode/DocumentationCache"),
        .init(group: .xcode, title: "XCTest devices", path: "~/Library/Developer/XCTestDevices", mode: .children),
        // Package managers
        .init(group: .packageCaches, title: "npm", path: "~/.npm/_cacache"),
        .init(group: .packageCaches, title: "npx", path: "~/.npm/_npx"),
        .init(group: .packageCaches, title: "Yarn", path: "~/Library/Caches/Yarn"),
        .init(group: .packageCaches, title: "Yarn Berry", path: "~/.yarn/berry/cache"),
        .init(group: .packageCaches, title: "pnpm (store)", path: "~/Library/pnpm/store", selected: false),
        .init(group: .packageCaches, title: "Bun", path: "~/.bun/install/cache"),
        .init(group: .packageCaches, title: "node-gyp", path: "~/Library/Caches/node-gyp"),
        .init(group: .packageCaches, title: "Electron", path: "~/Library/Caches/electron"),
        .init(group: .packageCaches, title: "pip", path: "~/Library/Caches/pip"),
        .init(group: .packageCaches, title: "CocoaPods", path: "~/Library/Caches/CocoaPods"),
        .init(group: .packageCaches, title: "Swift Package Manager", path: "~/Library/Caches/org.swift.swiftpm"),
        .init(group: .packageCaches, title: "Carthage", path: "~/Library/Caches/org.carthage.CarthageKit"),
        .init(group: .packageCaches, title: "Gradle", path: "~/.gradle/caches"),
        .init(group: .packageCaches, title: "Cargo", path: "~/.cargo/registry/cache"),
        .init(group: .packageCaches, title: "Go (build cache)", path: "~/Library/Caches/go-build"),
        .init(group: .packageCaches, title: "Homebrew", path: "~/Library/Caches/Homebrew"),
        .init(group: .packageCaches, title: "Maven (repository)", path: "~/.m2/repository", selected: false),
        .init(group: .packageCaches, title: "Flutter / Dart pub", path: "~/.pub-cache", selected: false),
        .init(group: .packageCaches, title: "Playwright (browsers)", path: "~/Library/Caches/ms-playwright", selected: false),
        .init(group: .packageCaches, title: "Cypress", path: "~/Library/Caches/Cypress", selected: false),
        .init(group: .packageCaches, title: "Yarn (~/.cache)", path: "~/.cache/yarn"),
        .init(group: .packageCaches, title: "pnpm (~/.local/share)", path: "~/.local/share/pnpm/store", selected: false),
        .init(group: .packageCaches, title: "pnpm (~/.pnpm-store)", path: "~/.pnpm-store", selected: false),
        .init(group: .packageCaches, title: "uv", path: "~/.cache/uv"),
        .init(group: .packageCaches, title: "uv (Library)", path: "~/Library/Caches/uv"),
        .init(group: .packageCaches, title: "Poetry", path: "~/Library/Caches/pypoetry"),
        .init(group: .packageCaches, title: "Deno", path: "~/Library/Caches/deno"),
        .init(group: .packageCaches, title: "Puppeteer (browsers)", path: "~/.cache/puppeteer", selected: false),
        .init(group: .packageCaches, title: "Go (modules)", path: "~/go/pkg/mod", selected: false),
        .init(group: .packageCaches, title: "Gradle (wrapper distributions)", path: "~/.gradle/wrapper/dists", selected: false),
        .init(group: .packageCaches, title: "Cargo (git checkouts)", path: "~/.cargo/git/checkouts"),
        .init(group: .packageCaches, title: "Cargo (git database)", path: "~/.cargo/git/db", selected: false),
        .init(group: .packageCaches, title: "NuGet", path: "~/.nuget/packages", selected: false),
        // Local AI apps: logs and caches only, never models or conversations.
        .init(group: .aiTools, title: "Ollama logs", path: "~/.ollama/logs"),
        .init(group: .aiTools, title: "Ollama cache", path: "~/Library/Caches/ollama"),
        .init(group: .aiTools, title: "Ollama app cache", path: "~/Library/Caches/com.electron.ollama"),
        .init(group: .aiTools, title: "LM Studio server logs", path: "~/.lmstudio/server-logs"),
    ]

    public func scan() -> [DevItem] {
        let fm = FileManager.default
        var out: [DevItem] = []
        for rule in Self.rules {
            let dir = env.resolve(rule.path)
            guard dir.isDirectoryURL, !env.isExcluded(dir) || rule.mode == .children else { continue }
            switch rule.mode {
            case .whole:
                let size = FileSize.of(dir)
                guard size > 0 else { continue }
                out.append(DevItem(id: dir.path, group: rule.group, title: rule.title, detail: env.displayPath(dir),
                                   size: size, removal: .files([dir]), selectedByDefault: rule.selected, location: dir))
            case .children:
                for child in fm.children(of: dir) where !child.lastPathComponent.hasPrefix(".") && !env.isExcluded(child) {
                    let size = FileSize.of(child)
                    guard size > 0 else { continue }
                    out.append(DevItem(id: child.path, group: rule.group, title: child.lastPathComponent,
                                       detail: rule.title, size: size, removal: .files([child]),
                                       selectedByDefault: rule.selected, location: child, lastUsed: child.modificationDate))
                }
            }
        }
        out += androidItems()
        return out
    }

    /// Android virtual devices (`Name.avd` folder plus its `Name.ini`) and downloaded system images.
    func androidItems() -> [DevItem] {
        let fm = FileManager.default
        var out: [DevItem] = []
        let avdDir = env.resolve("~/.android/avd")
        for avd in fm.children(of: avdDir) where avd.pathExtension == "avd" && !env.isExcluded(avd) {
            let ini = avd.deletingPathExtension().appendingPathExtension("ini")
            let files = [avd] + (fm.fileExists(atPath: ini.path) ? [ini] : [])
            out.append(DevItem(id: avd.path, group: .android, title: avd.deletingPathExtension().lastPathComponent,
                               detail: "Virtual device", size: FileSize.of(avd), removal: .files(files),
                               location: avd, lastUsed: avd.modificationDate))
        }
        // system-images/<api>/<tag>/<abi>
        let images = env.resolve("~/Library/Android/sdk/system-images")
        for api in fm.children(of: images) where api.isDirectoryURL {
            for tag in fm.children(of: api) where tag.isDirectoryURL {
                for abi in fm.children(of: tag) where abi.isDirectoryURL {
                    let size = FileSize.of(abi)
                    guard size > 0 else { continue }
                    out.append(DevItem(id: abi.path, group: .android,
                                       title: "\(api.lastPathComponent) · \(tag.lastPathComponent) · \(abi.lastPathComponent)",
                                       detail: "System image", size: size, removal: .files([abi]), location: abi))
                }
            }
        }
        return out
    }
}

// MARK: - iOS simulators and runtimes

public struct SimulatorScanner: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    static let xcrun = "/usr/bin/xcrun"

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner()) {
        self.env = env; self.runner = runner
    }

    public func scan() -> [DevItem] {
        let devices = runner.run(Self.xcrun, ["simctl", "list", "devices", "-j"])
        let runtimes = runner.run(Self.xcrun, ["simctl", "runtime", "list", "-j"])
        let deviceItems = devices.ok ? Self.parseDevices(Data(devices.output.utf8)) : []
        let usage = devices.ok ? Self.devicesPerRuntime(Data(devices.output.utf8)) : [:]
        return deviceItems + (runtimes.ok ? Self.parseRuntimes(Data(runtimes.output.utf8), devicesPerRuntime: usage) : [])
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5".
    static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        guard let dash = tail.firstIndex(of: "-") else { return tail }
        return tail[..<dash] + " " + tail[tail.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    static func date(_ s: Any?) -> Date? {
        (s as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Parses `xcrun simctl list devices -j`. Booted simulators are left out; unavailable ones
    /// (their runtime is gone, so they cannot start) are pre-selected.
    public static func parseDevices(_ json: Data) -> [DevItem] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [DevItem] = []
        for (runtime, devices) in byRuntime {
            for d in devices {
                // The UDID goes on a command line: accept nothing that is not a UUID.
                guard let udid = d["udid"] as? String, UUID(uuidString: udid) != nil,
                      let name = d["name"] as? String, (d["state"] as? String) != "Booted" else { continue }
                let available = d["isAvailable"] as? Bool ?? true
                let dataPath = (d["dataPath"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                let size = (d["dataPathSize"] as? NSNumber)?.int64Value ?? dataPath.map { FileSize.of($0) } ?? 0
                let used = date(d["lastUsedAt"])
                var detail = runtimeName(runtime)
                if !available { detail += " · unavailable (runtime deleted)" }
                else if used == nil { detail += " · never launched" }
                out.append(DevItem(id: "sim-" + udid, group: .simulators, title: name, detail: detail, size: size,
                                   removal: .command([xcrun, "simctl", "delete", udid]),
                                   selectedByDefault: !available, location: dataPath, lastUsed: used))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func devicesPerRuntime(_ json: Data) -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [:] }
        return byRuntime.mapValues(\.count)
    }

    /// Parses `xcrun simctl runtime list -j`. Never pre-selected: re-downloading one is 7+ GB.
    public static func parseRuntimes(_ json: Data, devicesPerRuntime: [String: Int] = [:]) -> [DevItem] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] else { return [] }
        var out: [DevItem] = []
        for (_, r) in root {
            guard let id = r["identifier"] as? String, UUID(uuidString: id) != nil,
                  r["deletable"] as? Bool == true else { continue }
            let runtimeID = r["runtimeIdentifier"] as? String ?? ""
            let name = runtimeID.isEmpty ? "Runtime \(r["version"] as? String ?? "")" : runtimeName(runtimeID)
            let used = date(r["lastUsedAt"])
            let devices = devicesPerRuntime[runtimeID] ?? 0
            var detail = "build \(r["build"] as? String ?? "?")"
            detail += devices > 0 ? " · simulators on it: \(devices)" : " · no simulators"
            if used == nil { detail += " · never used" }
            out.append(DevItem(id: "runtime-" + id, group: .runtimes, title: name, detail: detail,
                               size: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                               removal: .command([xcrun, "simctl", "runtime", "delete", id]), lastUsed: used))
        }
        return out.sorted { $0.size > $1.size }
    }
}

// MARK: - Build folders inside projects

public struct BuildArtifactFinder: Sendable {
    public let env: SweepEnvironment
    public var maxDepth = 7
    public init(env: SweepEnvironment) { self.env = env }

    struct Kind {
        let folder: String
        /// The folder counts only next to one of these (a `*.ext` entry matches by extension).
        let markers: [String]
        let title: String
    }

    static let kinds: [Kind] = [
        Kind(folder: "node_modules", markers: ["package.json"], title: "Node dependencies"),
        Kind(folder: ".next", markers: ["package.json"], title: "Next.js build"),
        Kind(folder: ".nuxt", markers: ["package.json"], title: "Nuxt build"),
        Kind(folder: ".turbo", markers: ["package.json"], title: "Turborepo cache"),
        Kind(folder: ".parcel-cache", markers: ["package.json"], title: "Parcel cache"),
        Kind(folder: ".angular", markers: ["package.json"], title: "Angular cache"),
        Kind(folder: ".svelte-kit", markers: ["package.json"], title: "SvelteKit build"),
        Kind(folder: ".expo", markers: ["package.json"], title: "Expo cache"),
        Kind(folder: ".build", markers: ["Package.swift"], title: "SwiftPM build"),
        Kind(folder: "DerivedData", markers: ["*.xcodeproj", "*.xcworkspace", "Package.swift"], title: "Project DerivedData"),
        Kind(folder: "Pods", markers: ["Podfile"], title: "CocoaPods"),
        Kind(folder: "build", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                                        "pubspec.yaml", "CMakeLists.txt", "*.xcodeproj", "*.xcworkspace"], title: "build folder"),
        Kind(folder: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], title: "Project Gradle cache"),
        Kind(folder: "target", markers: ["Cargo.toml", "pom.xml"], title: "Rust/Maven build"),
        Kind(folder: ".dart_tool", markers: ["pubspec.yaml"], title: "Dart cache"),
    ]

    static let skippedTopLevel: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "Public"]
    static let packageExtensions: Set<String> = ["app", "xcodeproj", "xcworkspace", "framework", "bundle", "photoslibrary",
                                                 "xcarchive", "playground", "musiclibrary", "tvlibrary"]

    static func matches(_ kind: Kind, siblings: Set<String>) -> Bool {
        kind.markers.contains { m in
            m.hasPrefix("*.") ? siblings.contains { $0.hasSuffix(String(m.dropFirst())) } : siblings.contains(m)
        }
    }

    /// Finds re-creatable build folders under `roots` (default: the home folder).
    public func find(roots: [URL]? = nil, cancelled: () -> Bool = { false }) -> [DevItem] {
        var out: [DevItem] = []
        for root in roots ?? [env.home] { visit(root, depth: 0, isHome: root.path == env.home.path, into: &out, cancelled: cancelled) }
        return out.sorted { $0.size > $1.size }
    }

    func visit(_ dir: URL, depth: Int, isHome: Bool, into out: inout [DevItem], cancelled: () -> Bool) {
        if cancelled() { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return }
        let names = Set(children.map(\.lastPathComponent))
        let artifactNames = Set(Self.kinds.map(\.folder))
        for child in children {
            let name = child.lastPathComponent
            guard let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            if env.isExcluded(child) { continue }
            if let kind = Self.kinds.first(where: { $0.folder == name }) {
                // An artifact name without its project marker (a random folder called "build") is left
                // alone, and never entered: a stray node_modules is not walked either.
                guard Self.matches(kind, siblings: names) else {
                    if !name.hasPrefix("."), name != "node_modules", depth < maxDepth {
                        visit(child, depth: depth + 1, isHome: false, into: &out, cancelled: cancelled)
                    }
                    continue
                }
                let size = FileSize.of(child)
                guard size > 0 else { continue }
                // Project activity: the newest change among the project's other top-level entries (incl. .git).
                let activity = children.filter { !artifactNames.contains($0.lastPathComponent) }
                    .compactMap(\.modificationDate).max()
                let days = activity.map { Int(env.now().timeIntervalSince($0) / 86_400) }
                out.append(DevItem(id: child.path, group: .builds, title: "\(dir.lastPathComponent)/\(name)",
                                   detail: kind.title + " · " + env.displayPath(dir) + (days.map { " · unchanged for \($0) days" } ?? ""),
                                   size: size, removal: .files([child]), location: child, lastUsed: activity))
                continue
            }
            if name.hasPrefix(".") || Self.packageExtensions.contains(child.pathExtension.lowercased()) { continue }
            if isHome, Self.skippedTopLevel.contains(name) { continue }
            if depth < maxDepth { visit(child, depth: depth + 1, isHome: false, into: &out, cancelled: cancelled) }
        }
    }
}

// MARK: - Removing

public struct DevCleaner: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    public let cleaner: Cleaner

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(), cleaner: Cleaner? = nil) {
        self.env = env; self.runner = runner
        self.cleaner = cleaner ?? Cleaner(env: env)
    }

    /// The only command shapes this type will ever run.
    static func isAllowed(_ argv: [String]) -> Bool {
        guard argv.first == SimulatorScanner.xcrun, argv.count >= 4, argv[1] == "simctl",
              let id = argv.last, UUID(uuidString: id) != nil else { return false }
        return Array(argv[2..<argv.count - 1]) == ["delete"] || Array(argv[2..<argv.count - 1]) == ["runtime", "delete"]
    }

    public func remove(_ items: [DevItem]) -> CleanReport {
        var targets: [(url: URL, size: Int64)] = []
        var report = CleanReport()
        for item in items {
            switch item.removal {
            case .files(let urls):
                // The item's size is counted once, on its first file.
                targets += urls.enumerated().map { ($1, $0 == 0 ? item.size : 0) }
            case .command(let argv):
                let label = item.location ?? URL(fileURLWithPath: "/" + item.title)
                guard Self.isAllowed(argv) else {
                    report.failed.append((label, "Command not allowed"))
                    continue
                }
                let r = runner.run(argv[0], Array(argv.dropFirst()))
                if r.ok {
                    report.removed.append(label)
                    report.freedBytes += item.size
                } else {
                    let why = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    report.failed.append((label, why.isEmpty ? "Exit code \(r.status)" : why))
                }
            }
        }
        let files = cleaner.remove(targets)
        report.removed += files.removed
        report.failed += files.failed
        report.freedBytes += files.freedBytes
        return report
    }
}

// MARK: - Docker

public struct DockerUsage: Equatable, Sendable, Identifiable {
    public var id: String { type }
    public let type: String
    public let total: Int
    public let active: Int
    public let size: Int64
    public let reclaimable: Int64
}

public enum DockerPrune: String, CaseIterable, Sendable, Identifiable {
    case buildCache, containers, danglingImages, unusedImages, volumes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buildCache: "Build cache"
        case .containers: "Stopped containers"
        case .danglingImages: "Dangling images"
        case .unusedImages: "All images without containers"
        case .volumes: "Unused volumes"
        }
    }

    public var details: String {
        switch self {
        case .buildCache: "Intermediate build layers. The next image build takes longer."
        case .containers: "Containers that are not running. Data inside them (outside volumes) is lost."
        case .danglingImages: "Old layers left behind after images were rebuilt."
        case .unusedImages: "Every image no container uses right now. They have to be pulled again."
        case .volumes: "Anonymous volumes with no container. Databases live in volumes: what is removed cannot be restored."
        }
    }

    public var arguments: [String] {
        switch self {
        case .buildCache: ["builder", "prune", "-f"]
        case .containers: ["container", "prune", "-f"]
        case .danglingImages: ["image", "prune", "-f"]
        case .unusedImages: ["image", "prune", "-a", "-f"]
        case .volumes: ["volume", "prune", "-f"]
        }
    }

    /// Loses data that cannot be downloaded or rebuilt again.
    public var dangerous: Bool { self == .volumes || self == .containers }
    public var selectedByDefault: Bool { self == .buildCache || self == .danglingImages }
}

public struct DockerCleaner: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case notRunning
        case ready([DockerUsage])
    }

    public let runner: CommandRunning
    public let binary: String?

    public static let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                    "/Applications/Docker.app/Contents/Resources/bin/docker"]

    public init(runner: CommandRunning = ProcessRunner(),
                binary: String? = DockerCleaner.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner; self.binary = binary
    }

    public func state() -> State {
        guard let binary else { return .notInstalled }
        let r = runner.run(binary, ["system", "df", "--format", "{{json .}}"])
        return r.ok ? .ready(Self.parseUsage(r.output)) : .notRunning
    }

    /// Runs the chosen prunes; returns each result and the space Docker says it reclaimed.
    public func prune(_ kinds: [DockerPrune]) -> (results: [DockerPrune: CommandResult], reclaimed: Int64) {
        guard let binary else { return ([:], 0) }
        var results: [DockerPrune: CommandResult] = [:]
        var total: Int64 = 0
        for k in kinds {
            let r = runner.run(binary, k.arguments)
            results[k] = r
            if r.ok { total += Self.parseReclaimed(r.output) }
        }
        return (results, total)
    }

    /// Parses `docker system df --format '{{json .}}'`: one JSON object per line.
    public static func parseUsage(_ output: String) -> [DockerUsage] {
        output.split(separator: "\n").compactMap { line in
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = d["Type"] as? String else { return nil }
            func int(_ k: String) -> Int { Int("\(d[k] ?? "0")") ?? 0 }
            return DockerUsage(type: type, total: int("TotalCount"), active: int("Active"),
                               size: parseSize("\(d["Size"] ?? "0B")"), reclaimable: parseSize("\(d["Reclaimable"] ?? "0B")"))
        }
    }

    /// "1.5GB (46%)" → bytes. Docker uses decimal units: kB, MB, GB, TB.
    public static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let number = token.prefix { $0.isNumber || $0 == "." }
        let unit = token.dropFirst(number.count).lowercased()
        guard let value = Double(number) else { return 0 }
        let factor: Double = switch unit {
        case "kb": 1e3
        case "mb": 1e6
        case "gb": 1e9
        case "tb": 1e12
        default: 1
        }
        return Int64(value * factor)
    }

    /// Finds "Total reclaimed space: 1.2GB" (or "Total: 1.2GB" from the builder) in prune output.
    public static func parseReclaimed(_ output: String) -> Int64 {
        for line in output.split(separator: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Total reclaimed space:", "Total:"] where l.hasPrefix(prefix) {
                return parseSize(l.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return 0
    }
}
