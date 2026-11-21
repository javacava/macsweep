import Foundation

/// One thing the Developer page can remove: a simulator, a runtime, a firmware file, a cache, a build folder.
public struct DevItem: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case simulators, runtimes, firmware, xcode, android, packageCaches, ideCaches, oldVersions, aiTools, aiModels,
             heapDumps, builds

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
            case .ideCaches: "Editor and IDE caches"
            case .oldVersions: "Old tool versions"
            case .heapDumps: "Java heap dumps"
            case .aiModels: "Downloaded AI models"
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
            case .ideCaches: "chevron.left.forwardslash.chevron.right"
            case .oldVersions: "clock.arrow.circlepath"
            case .heapDumps: "memorychip"
            case .aiModels: "cube.box"
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
            case .ideCaches: "Caches of VS Code, Cursor and JetBrains IDEs. Quit the editor first; it rebuilds them on the next start."
            case .oldVersions: "Earlier versions that tools keep after an update, and Xcode's optional Metal toolchain. The version in use is never offered."
            case .heapDumps: ".hprof files Java writes when a program runs out of memory. Useful only while you investigate that crash."
            case .aiTools: "Logs and caches of local AI apps such as Ollama and LM Studio. Downloaded models and chat history are never offered."
            case .aiModels: "Models you downloaded for local AI apps. Nothing here is preselected: remove only models you no longer use; the app downloads them again if you need them."
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
        .init(group: .packageCaches, title: "Ruby gems (spec cache)", path: "~/.gem/specs"),
        .init(group: .packageCaches, title: "Ruby gems (spec cache)", path: "~/.local/share/gem/specs"),
        .init(group: .packageCaches, title: "Bundler", path: "~/.bundle/cache"),
        .init(group: .packageCaches, title: "Composer", path: "~/Library/Caches/composer"),
        .init(group: .packageCaches, title: "Composer", path: "~/.composer/cache"),
        .init(group: .packageCaches, title: "Composer", path: "~/.cache/composer"),
        .init(group: .packageCaches, title: "Bazel (disk cache)", path: "~/.cache/bazel", selected: false),
        // Conda's package cache: environments hard-link into it, so removing it frees less than it shows.
        .init(group: .packageCaches, title: "Conda packages (miniconda)", path: "~/miniconda3/pkgs", selected: false),
        .init(group: .packageCaches, title: "Conda packages (anaconda)", path: "~/anaconda3/pkgs", selected: false),
        .init(group: .packageCaches, title: "Conda packages (miniforge)", path: "~/miniforge3/pkgs", selected: false),
        .init(group: .packageCaches, title: "Conda packages", path: "~/.conda/pkgs", selected: false),
        // Editors and IDEs
        .init(group: .ideCaches, title: "VS Code cache", path: "~/Library/Application Support/Code/Cache"),
        .init(group: .ideCaches, title: "VS Code old versions data", path: "~/Library/Application Support/Code/CachedData"),
        .init(group: .ideCaches, title: "VS Code extension downloads", path: "~/Library/Application Support/Code/CachedExtensionVSIXs"),
        .init(group: .ideCaches, title: "VS Code code cache", path: "~/Library/Application Support/Code/Code Cache"),
        .init(group: .ideCaches, title: "VS Code GPU cache", path: "~/Library/Application Support/Code/GPUCache"),
        .init(group: .ideCaches, title: "VS Code logs", path: "~/Library/Application Support/Code/logs"),
        .init(group: .ideCaches, title: "Cursor cache", path: "~/Library/Application Support/Cursor/Cache"),
        .init(group: .ideCaches, title: "Cursor old versions data", path: "~/Library/Application Support/Cursor/CachedData"),
        .init(group: .ideCaches, title: "Cursor code cache", path: "~/Library/Application Support/Cursor/Code Cache"),
        .init(group: .ideCaches, title: "Cursor logs", path: "~/Library/Application Support/Cursor/logs"),
        .init(group: .ideCaches, title: "JetBrains", path: "~/Library/Caches/JetBrains", mode: .children),
        .init(group: .ideCaches, title: "JetBrains logs", path: "~/Library/Logs/JetBrains", mode: .children),
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
        out += AIModelScanner(env: env).scan()
        out += oldClaudeCodeVersions()
        out += bazelOutput()
        out += heapDumps()
        return out
    }

    /// Claude Code's native installer keeps every version it downloaded in `~/.local/share/claude/versions`.
    /// The one `~/.local/bin/claude` points to, and the newest, are kept.
    func oldClaudeCodeVersions() -> [DevItem] {
        let dir = env.resolve("~/.local/share/claude/versions")
        let versions = FileManager.default.children(of: dir).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard versions.count > 1 else { return [] }
        let link = env.resolve("~/.local/bin/claude")
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            .map { URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.lastPathComponent }
        let newest = versions.map(\.lastPathComponent).max { VersionCompare.compare($0, $1) == .orderedAscending }
        return versions.filter { $0.lastPathComponent != current && $0.lastPathComponent != newest && !env.isExcluded($0) }
            .compactMap { v in
                let size = FileSize.of(v)
                guard size > 0 else { return nil }
                return DevItem(id: v.path, group: .oldVersions, title: "Claude Code \(v.lastPathComponent)",
                               detail: "Older version · in use: \(current ?? newest ?? "?")", size: size,
                               removal: .files([v]), selectedByDefault: true, location: v, lastUsed: v.modificationDate)
            }
    }

    /// Bazel's output base lives outside the home folder: /private/var/tmp/_bazel_<user>.
    func bazelOutput(user: String = NSUserName()) -> [DevItem] {
        let dir = env.resolve("/private/var/tmp/_bazel_\(user)")
        guard dir.isDirectoryURL, !env.isExcluded(dir) else { return [] }
        let size = FileSize.of(dir)
        guard size > 0 else { return [] }
        return [DevItem(id: dir.path, group: .packageCaches, title: "Bazel (output base)", detail: env.displayPath(dir),
                        size: size, removal: .files([dir]), selectedByDefault: false, location: dir)]
    }

    /// Java heap dumps (`*.hprof`) in the home folder, a few levels deep, outside ~/Library.
    func heapDumps(maxDepth: Int = 4) -> [DevItem] {
        var out: [DevItem] = []
        let skip = [env.home.appendingPathComponent("Library"), env.home.appendingPathComponent(".Trash")]
        guard let e = FileManager.default.enumerator(at: env.home, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsPackageDescendants]) else { return [] }
        for case let url as URL in e {
            if e.level > maxDepth || skip.contains(where: { url.isInside($0) }) { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "hprof", !env.isExcluded(url) else { continue }
            let size = FileSize.of(url)
            guard size > 0 else { continue }
            out.append(DevItem(id: url.path, group: .heapDumps, title: url.lastPathComponent,
                               detail: env.displayPath(url.deletingLastPathComponent()), size: size,
                               removal: .files([url]), selectedByDefault: true, location: url, lastUsed: url.modificationDate))
        }
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

// MARK: - Local AI models

/// Models downloaded by local AI apps. One item per model, never preselected.
public struct AIModelScanner: Sendable {
    public let env: SweepEnvironment
    /// Files smaller than this are configs, not models.
    static let minSize: Int64 = 10 * 1_048_576

    public init(env: SweepEnvironment) { self.env = env }

    /// Folders where each child is one model (file or folder).
    static let folders: [(app: String, path: String)] = [
        ("LM Studio", "~/.lmstudio/models"),
        ("LM Studio", "~/.cache/lm-studio/models"),
        ("GPT4All", "~/Library/Application Support/nomic.ai/GPT4All"),
        ("Jan", "~/jan/models"),
        ("Jan", "~/Library/Application Support/Jan/data/models"),
        ("Draw Things", "~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models"),
        ("DiffusionBee", "~/.diffusionbee/downloads"),
        ("MacWhisper", "~/Library/Application Support/MacWhisper/models"),
        ("Whisper", "~/.cache/whisper"),
        ("PyTorch Hub", "~/.cache/torch/hub/checkpoints"),
    ]

    public func scan() -> [DevItem] {
        var out = ollama() + huggingFace()
        let fm = FileManager.default
        for (app, path) in Self.folders {
            let dir = env.resolve(path)
            // LM Studio keeps models as <publisher>/<model>; list the models, not the publishers.
            let nested = app == "LM Studio"
            let entries = nested ? fm.children(of: dir).filter(\.isDirectoryURL).flatMap { fm.children(of: $0) } : fm.children(of: dir)
            for model in entries where !model.lastPathComponent.hasPrefix(".") && !env.isExcluded(model) {
                let size = FileSize.of(model)
                guard size >= Self.minSize else { continue }
                let title = nested ? model.deletingLastPathComponent().lastPathComponent + "/" + model.lastPathComponent
                                   : model.lastPathComponent
                out.append(DevItem(id: model.path, group: .aiModels, title: title, detail: app, size: size,
                                   removal: .files([model]), location: model, lastUsed: model.accessDate))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Hugging Face cache: `~/.cache/huggingface/hub/models--org--name`.
    func huggingFace() -> [DevItem] {
        let hub = env.resolve("~/.cache/huggingface/hub")
        return FileManager.default.children(of: hub).compactMap { dir in
            let name = dir.lastPathComponent
            guard name.hasPrefix("models--") || name.hasPrefix("datasets--"), !env.isExcluded(dir) else { return nil }
            let size = FileSize.of(dir)
            guard size >= Self.minSize else { return nil }
            let kind = name.hasPrefix("models--") ? "Hugging Face model" : "Hugging Face dataset"
            let title = name.split(separator: "-", omittingEmptySubsequences: true).isEmpty ? name
                : name.components(separatedBy: "--").dropFirst().joined(separator: "/")
            return DevItem(id: dir.path, group: .aiModels, title: title, detail: kind, size: size,
                           removal: .files([dir]), location: dir, lastUsed: dir.modificationDate)
        }
    }

    /// Ollama stores models as manifests that point at shared, content-addressed blobs. A model's
    /// removal takes its manifest and only the blobs no other model uses.
    func ollama() -> [DevItem] {
        let root = env.resolve("~/.ollama/models")
        let manifestsDir = root.appendingPathComponent("manifests")
        let blobsDir = root.appendingPathComponent("blobs")
        guard let walker = FileManager.default.enumerator(at: manifestsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var manifests: [(url: URL, name: String, digests: [String])] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let digests = Self.ollamaDigests(url) else { continue }
            // manifests/<host>/<namespace>/<model>/<tag>
            let parts = Array(url.pathComponents.suffix(3))
            guard parts.count == 3 else { continue }
            let name = (parts[0] == "library" ? "" : parts[0] + "/") + parts[1] + ":" + parts[2]
            manifests.append((url, name, digests))
        }
        var refs: [String: Int] = [:]
        for m in manifests { for d in Set(m.digests) { refs[d, default: 0] += 1 } }
        return manifests.compactMap { m in
            guard !env.isExcluded(m.url) else { return nil }
            let blobs = Set(m.digests).map { blobsDir.appendingPathComponent($0.replacingOccurrences(of: ":", with: "-")) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let own = blobs.filter { refs[$0.lastPathComponent.replacingOccurrences(of: "sha256-", with: "sha256:")] == 1 }
            let size = blobs.reduce(Int64(0)) { $0 + FileSize.of($1) }
            let freed = own.reduce(Int64(0)) { $0 + FileSize.of($1) }
            guard size >= Self.minSize else { return nil }
            let shared = size - freed
            let detail = "Ollama" + (shared > 0 ? " · \(FileSize.format(shared)) shared with other models stays" : "")
            return DevItem(id: m.url.path, group: .aiModels, title: m.name, detail: detail, size: freed,
                           removal: .files([m.url] + own), location: m.url, lastUsed: m.url.modificationDate)
        }
    }

    /// Layer and config digests listed in an Ollama manifest.
    static func ollamaDigests(_ manifest: URL) -> [String]? {
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var digests: [String] = []
        if let c = json["config"] as? [String: Any], let d = c["digest"] as? String { digests.append(d) }
        for layer in json["layers"] as? [[String: Any]] ?? [] {
            if let d = layer["digest"] as? String { digests.append(d) }
        }
        return digests.isEmpty ? nil : digests
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

    static let xcodebuild = "/usr/bin/xcodebuild"
    static let metalAsset = "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain"

    /// Xcode's downloadable Metal toolchain, removed with `xcodebuild -deleteComponent metaltoolchain`.
    public func metalToolchain() -> [DevItem] {
        let r = runner.run(Self.xcodebuild, ["-showComponent", "metaltoolchain"])
        guard r.ok, Self.componentInstalled(r.output) else { return [] }
        let size = FileSize.of(env.resolve(Self.metalAsset))
        return [DevItem(id: "metal-toolchain", group: .oldVersions, title: "Metal Toolchain",
                        detail: "Xcode component · needed only to compile Metal shaders; Xcode downloads it again on demand",
                        size: size, removal: .command([Self.xcodebuild, "-deleteComponent", "metaltoolchain"]))]
    }

    /// `xcodebuild -showComponent` prints "Status: installed" or "Status: uninstalled".
    public static func componentInstalled(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("status:") && l.hasSuffix(" installed")
        }
    }

    public func scan() -> [DevItem] {
        let devices = runner.run(Self.xcrun, ["simctl", "list", "devices", "-j"])
        let runtimes = runner.run(Self.xcrun, ["simctl", "runtime", "list", "-j"])
        let deviceItems = devices.ok ? Self.parseDevices(Data(devices.output.utf8)) : []
        let usage = devices.ok ? Self.devicesPerRuntime(Data(devices.output.utf8)) : [:]
        return deviceItems + (runtimes.ok ? Self.parseRuntimes(Data(runtimes.output.utf8), devicesPerRuntime: usage) : [])
            + metalToolchain()
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

/// Finds a usable `git` without triggering the "install command line tools" prompt that the
/// `/usr/bin/git` shim shows on Macs without them.
public enum GitTool {
    public static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                                    "/Library/Developer/CommandLineTools/usr/bin/git",
                                    "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]

    public static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
}

public struct BuildArtifactFinder: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    /// The git binary used to protect tracked files. nil: inside a repository only tool-specific
    /// folders (node_modules, .build…) are offered, never generic ones (build, bin, target…).
    public let git: String?
    public var maxDepth = 7

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(), git: String? = GitTool.path) {
        self.env = env; self.runner = runner; self.git = git
    }

    struct Kind {
        let folder: String
        /// The folder counts only next to one of these. `*.ext` matches by extension, `a/b` must exist as a path.
        let markers: [String]
        let title: String
        /// A common word (build, bin, target…). Inside a git repository such a folder must be git-ignored.
        var generic = false
    }

    static let node = ["package.json"]
    static let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "tox.ini", "Pipfile"]
    static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
    static let dotnet = ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]

    static let kinds: [Kind] = [
        Kind(folder: "node_modules", markers: node, title: "Node dependencies"),
        Kind(folder: ".next", markers: node, title: "Next.js build"),
        Kind(folder: ".nuxt", markers: node, title: "Nuxt build"),
        Kind(folder: ".turbo", markers: node, title: "Turborepo cache"),
        Kind(folder: ".parcel-cache", markers: node, title: "Parcel cache"),
        Kind(folder: ".angular", markers: node, title: "Angular cache"),
        Kind(folder: ".svelte-kit", markers: node, title: "SvelteKit build"),
        Kind(folder: ".expo", markers: node, title: "Expo cache"),
        Kind(folder: ".build", markers: ["Package.swift"], title: "SwiftPM build"),
        Kind(folder: "DerivedData", markers: ["*.xcodeproj", "*.xcworkspace", "Package.swift"], title: "Project DerivedData"),
        Kind(folder: "Pods", markers: ["Podfile"], title: "CocoaPods"),
        Kind(folder: "build", markers: gradle + ["pubspec.yaml", "CMakeLists.txt", "*.xcodeproj", "*.xcworkspace"],
             title: "build folder", generic: true),
        Kind(folder: ".gradle", markers: gradle, title: "Project Gradle cache"),
        Kind(folder: "target", markers: ["Cargo.toml", "pom.xml"], title: "Rust/Maven build", generic: true),
        Kind(folder: ".dart_tool", markers: ["pubspec.yaml"], title: "Dart cache"),
        // Python
        Kind(folder: "__pycache__", markers: python, title: "Python bytecode"),
        Kind(folder: ".mypy_cache", markers: python, title: "mypy cache"),
        Kind(folder: ".pytest_cache", markers: python, title: "pytest cache"),
        Kind(folder: ".ruff_cache", markers: python, title: "Ruff cache"),
        Kind(folder: ".tox", markers: python, title: "tox environments"),
        Kind(folder: ".nox", markers: python, title: "nox environments"),
        Kind(folder: ".venv", markers: python, title: "Python virtual environment"),
        Kind(folder: "venv", markers: python, title: "Python virtual environment", generic: true),
        // Game engines
        Kind(folder: "Library", markers: ["ProjectSettings/ProjectVersion.txt"], title: "Unity library", generic: true),
        Kind(folder: "Temp", markers: ["ProjectSettings/ProjectVersion.txt"], title: "Unity temp", generic: true),
        Kind(folder: "Obj", markers: ["ProjectSettings/ProjectVersion.txt"], title: "Unity obj", generic: true),
        Kind(folder: "Logs", markers: ["ProjectSettings/ProjectVersion.txt"], title: "Unity logs", generic: true),
        Kind(folder: "Binaries", markers: ["*.uproject"], title: "Unreal binaries", generic: true),
        Kind(folder: "Intermediate", markers: ["*.uproject"], title: "Unreal intermediate", generic: true),
        Kind(folder: "DerivedDataCache", markers: ["*.uproject"], title: "Unreal derived data"),
        Kind(folder: ".godot", markers: ["project.godot"], title: "Godot cache"),
        Kind(folder: ".import", markers: ["project.godot"], title: "Godot import cache"),
        // Others
        Kind(folder: "bin", markers: dotnet, title: ".NET bin", generic: true),
        Kind(folder: "obj", markers: dotnet, title: ".NET obj", generic: true),
        Kind(folder: ".terraform", markers: ["*.tf"], title: "Terraform providers"),
        Kind(folder: "zig-cache", markers: ["build.zig"], title: "Zig cache"),
        Kind(folder: ".zig-cache", markers: ["build.zig"], title: "Zig cache"),
        Kind(folder: "_build", markers: ["mix.exs"], title: "Elixir build", generic: true),
        Kind(folder: "deps", markers: ["mix.exs"], title: "Elixir dependencies", generic: true),
        Kind(folder: ".stack-work", markers: ["stack.yaml"], title: "Haskell Stack build"),
    ]

    static let skippedTopLevel: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "Public"]
    static let packageExtensions: Set<String> = ["app", "xcodeproj", "xcworkspace", "framework", "bundle", "photoslibrary",
                                                 "xcarchive", "playground", "musiclibrary", "tvlibrary"]

    static func matches(_ kind: Kind, siblings: Set<String>, in dir: URL? = nil) -> Bool {
        kind.markers.contains { m in
            if m.hasPrefix("*.") { return siblings.contains { $0.hasSuffix(String(m.dropFirst())) } }
            if m.contains("/") {
                guard let dir, siblings.contains(String(m.split(separator: "/")[0])) else { return false }
                return FileManager.default.fileExists(atPath: dir.appendingPathComponent(m).path)
            }
            return siblings.contains(m)
        }
    }

    /// Finds re-creatable build folders under `roots` (default: the home folder).
    public func find(roots: [URL]? = nil, cancelled: () -> Bool = { false }) -> [DevItem] {
        var out: [DevItem] = []
        var repos: [String: URL?] = [:]
        for root in roots ?? [env.home] {
            visit(root, depth: 0, isHome: root.path == env.home.path, into: &out, repos: &repos, cancelled: cancelled)
        }
        return out.sorted { $0.size > $1.size }
    }

    func visit(_ dir: URL, depth: Int, isHome: Bool, into out: inout [DevItem], repos: inout [String: URL?],
               cancelled: () -> Bool) {
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
            let candidates = Self.kinds.filter { $0.folder == name }
            if !candidates.isEmpty {
                // An artifact name without its project marker (a random folder called "build") is left
                // alone, and never entered: a stray node_modules is not walked either.
                guard let kind = candidates.first(where: { Self.matches($0, siblings: names, in: dir) }) else {
                    if !name.hasPrefix("."), name != "node_modules", depth < maxDepth,
                       !(isHome && Self.skippedTopLevel.contains(name)) {
                        visit(child, depth: depth + 1, isHome: false, into: &out, repos: &repos, cancelled: cancelled)
                    }
                    continue
                }
                guard isSafeToOffer(child, kind: kind, repos: &repos) else { continue }
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
            if depth < maxDepth { visit(child, depth: depth + 1, isHome: false, into: &out, repos: &repos, cancelled: cancelled) }
        }
    }

    // MARK: Git safety gate

    /// Inside a git repository a folder is offered only when git agrees it is disposable:
    /// nothing in it is tracked, it is not a nested repository, and generic names must be git-ignored.
    func isSafeToOffer(_ folder: URL, kind: Kind, repos: inout [String: URL?]) -> Bool {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return false }
        guard let repo = repository(containing: folder.deletingLastPathComponent(), cache: &repos) else { return true }
        guard let git else { return !kind.generic }
        let rel = String(folder.standardizedFileURL.path.dropFirst(repo.standardizedFileURL.path.count + 1))
        let tracked = runner.run(git, ["-C", repo.path, "ls-files", "-z", "--", rel])
        guard tracked.ok, tracked.output.isEmpty else { return false }
        if kind.generic {
            return runner.run(git, ["-C", repo.path, "check-ignore", "-q", "--", rel]).status == 0
        }
        return true
    }

    /// The working tree root at or above `dir`.
    func repository(containing dir: URL, cache: inout [String: URL?]) -> URL? {
        var d = dir.standardizedFileURL
        var visited: [String] = []
        // Walk up to the home folder (for projects under it) or to the volume root (for a folder chosen elsewhere).
        while true {
            if let hit = cache[d.path] { visited.forEach { cache[$0] = hit }; return hit }
            visited.append(d.path)
            if FileManager.default.fileExists(atPath: d.appendingPathComponent(".git").path) {
                visited.forEach { cache[$0] = d }
                return d
            }
            if d.path == env.home.path || d.path == env.root.path || d.pathComponents.count <= 1 { break }
            d = d.deletingLastPathComponent()
        }
        visited.forEach { cache[$0] = URL?.none }
        return nil
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
        if argv == [SimulatorScanner.xcodebuild, "-deleteComponent", "metaltoolchain"] { return true }
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
        report.merge(cleaner.remove(targets))
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
