import Foundation
import Testing
@testable import SweepCore

/// Item 11 of the survey: more developer caches, editor caches, old tool versions,
/// the Metal toolchain, Java heap dumps and virtual machines.

@Suite struct MoreDeveloperCachesTests {
    @Test func newCacheLocationsAreFound() {
        let s = Sandbox()
        for p in ["~/.gem/specs/rubygems.org/x", "~/.bundle/cache/compact_index/x", "~/Library/Caches/composer/files/x",
                  "~/.cache/bazel/_bazel_me/cache/x", "~/miniconda3/pkgs/numpy-1.26/x",
                  "~/Library/Application Support/Code/CachedData/abc/x", "~/Library/Application Support/Code/logs/x",
                  "~/Library/Application Support/Cursor/Cache/x", "~/Library/Caches/JetBrains/IntelliJIdea2024.3/index/x"] {
            s.file(p, bytes: 5000)
        }
        let items = DevFolderScanner(env: s.env).scan()
        let titles = Set(items.map(\.title))
        for t in ["Ruby gems (spec cache)", "Bundler", "Composer", "Bazel (disk cache)", "Conda packages (miniconda)",
                  "VS Code old versions data", "VS Code logs", "Cursor cache", "IntelliJIdea2024.3"] {
            #expect(titles.contains(t), "\(t) missing")
        }
        #expect(items.first { $0.title == "Conda packages (miniconda)" }?.selectedByDefault == false,
                "conda environments hard-link into the package cache")
        #expect(items.filter { $0.title.hasPrefix("VS Code") || $0.title.hasPrefix("Cursor") || $0.title.hasPrefix("IntelliJ") }
                .allSatisfy { $0.group == .ideCaches })
    }

    @Test func editorSettingsAndExtensionsAreNeverOffered() {
        let s = Sandbox()
        s.file("~/Library/Application Support/Code/User/settings.json", bytes: 5000)
        s.file("~/Library/Application Support/Code/User/globalStorage/state.vscdb", bytes: 5000)
        s.file("~/.vscode/extensions/ms-python.python/x", bytes: 5000)
        #expect(DevFolderScanner(env: s.env).scan().isEmpty)
    }

    @Test func bazelOutputBaseOutsideHome() throws {
        let s = Sandbox()
        s.file("/private/var/tmp/_bazel_tester/execroot/x", bytes: 5000)
        let items = DevFolderScanner(env: s.env).bazelOutput(user: "tester")
        let item = try #require(items.first)
        #expect(item.title == "Bazel (output base)")
        #expect(!item.selectedByDefault)
        // The safety guard allows /private/var/tmp, but not /private/var itself.
        let g = SafetyGuard(env: s.env)
        #expect(g.check(s.env.resolve("/private/var/tmp/_bazel_tester")) == .allowed)
        #expect(g.check(s.env.resolve("/private/var/tmp")) != .allowed)
        #expect(DevFolderScanner(env: s.env).bazelOutput(user: "nobody").isEmpty)
    }
}

@Suite struct OldVersionsTests {
    @Test func oldClaudeCodeVersionsKeepTheOneInUseAndTheNewest() throws {
        let s = Sandbox()
        for v in ["2.0.9", "2.1.200", "2.1.310", "2.1.40"] { s.file("~/.local/share/claude/versions/\(v)", bytes: 5000) }
        s.dir("~/.local/bin")
        // The user pinned an older version on purpose.
        try FileManager.default.createSymbolicLink(atPath: s.env.resolve("~/.local/bin/claude").path,
                                                   withDestinationPath: s.env.resolve("~/.local/share/claude/versions/2.1.200").path)
        let items = DevFolderScanner(env: s.env).oldClaudeCodeVersions()
        #expect(Set(items.filter(\.isRemovable).map(\.title)) == ["Claude Code 2.0.9", "Claude Code 2.1.40"])
        #expect(Set(items.filter { !$0.isRemovable }.map(\.title)) == ["Claude Code 2.1.200", "Claude Code 2.1.310"],
                "in use and newest are listed as kept")
    }

    @Test func singleVersionIsNeverOffered() {
        let s = Sandbox()
        s.file("~/.local/share/claude/versions/2.1.310", bytes: 5000)
        #expect(DevFolderScanner(env: s.env).oldClaudeCodeVersions().isEmpty)
    }

    @Test func claudeDataIsNeverTouched() {
        let s = Sandbox()
        s.file("~/.claude/projects/p/session.jsonl", bytes: 5000)
        s.file("~/.claude/settings.json", bytes: 5000)
        s.file("~/.claude/debug/log.txt", bytes: 5000)
        // Only debug logs and shell snapshots may go; conversations, memory and settings never.
        let allowed = ["/.claude/debug", "/.claude/shell-snapshots"]
        #expect(!DevFolderScanner(env: s.env).scan().contains { item in
            if case .files(let urls) = item.removal {
                return urls.contains { u in u.path.contains("/.claude/") && !allowed.contains { u.path.hasSuffix($0) } }
            }
            return false
        })
    }

    @Test func metalToolchainOnlyWhenInstalled() throws {
        let s = Sandbox()
        s.file("/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/x/toolchain", bytes: 5000)
        let runner = FakeRunner()
        runner.responses["/usr/bin/xcodebuild -showComponent metaltoolchain"] =
            CommandResult(status: 0, output: "Asset Path: /System/Library/AssetsV2/x\nBuild Version: 17A1\nStatus: installed\n")
        let item = try #require(SimulatorScanner(env: s.env, runner: runner).metalToolchain().first)
        #expect(item.group == .oldVersions && !item.selectedByDefault && item.size > 0)
        #expect(item.removal == .command(["/usr/bin/xcodebuild", "-deleteComponent", "metaltoolchain"]))
        #expect(DevCleaner.isAllowed(["/usr/bin/xcodebuild", "-deleteComponent", "metaltoolchain"]))
        #expect(!DevCleaner.isAllowed(["/usr/bin/xcodebuild", "-deleteComponent", "devicesupport"]))

        runner.responses["/usr/bin/xcodebuild -showComponent metaltoolchain"] =
            CommandResult(status: 0, output: "Build Version: 27B47\nStatus: uninstalled\n")
        #expect(SimulatorScanner(env: s.env, runner: runner).metalToolchain().isEmpty)
        #expect(!SimulatorScanner.componentInstalled("Status: uninstalled"))
        #expect(SimulatorScanner.componentInstalled("Status: installed"))
    }

    @Test func removingMetalRunsOnlyThatCommand() {
        let runner = FakeRunner()
        let item = DevItem(id: "metal", group: .oldVersions, title: "Metal Toolchain", detail: "", size: 1000,
                           removal: .command(["/usr/bin/xcodebuild", "-deleteComponent", "metaltoolchain"]))
        let r = DevCleaner(env: Sandbox().env, runner: runner).remove([item])
        #expect(r.freedBytes == 1000)
        #expect(runner.calls == [["/usr/bin/xcodebuild", "-deleteComponent", "metaltoolchain"]])
    }
}

@Suite struct HeapDumpTests {
    @Test func findsHprofOutsideLibraryWithinDepth() {
        let s = Sandbox()
        s.file("~/java_pid1234.hprof", bytes: 5000)
        s.file("~/Code/service/java_pid99.hprof", bytes: 5000)
        s.file("~/Library/Logs/x.hprof", bytes: 5000)               // Library is skipped
        s.file("~/a/b/c/d/e/f/deep.hprof", bytes: 5000)             // too deep
        s.file("~/Code/service/notes.txt", bytes: 5000)
        let titles = Set(DevFolderScanner(env: s.env).heapDumps().map(\.title))
        #expect(titles == ["java_pid1234.hprof", "java_pid99.hprof"])
        #expect(DevFolderScanner(env: s.env).heapDumps().allSatisfy { $0.group == .heapDumps && $0.selectedByDefault })
    }
}

@Suite struct VirtualMachineTests {
    @Test func vmFilesHaveTheirOwnKind() {
        for ext in ["pvm", "utm", "vmwarevm", "vmdk", "qcow2", "vdi", "hdd"] {
            #expect(FileKind.of(URL(fileURLWithPath: "/x/disk.\(ext)")) == .virtualMachine, "\(ext)")
        }
        #expect(FileKind.of(URL(fileURLWithPath: "/x/a.dmg")) == .diskImage)
        #expect(FileKind.virtualMachine.title == "Virtual machines")
    }

    @Test func vmBundleCountsAsOneLargeItem() {
        let s = Sandbox()
        s.file("~/Parallels/Windows 11.pvm/harddisk.hdd/disk.hds", bytes: 300_000)
        s.file("~/Parallels/Windows 11.pvm/config.pvs", bytes: 100)
        s.file("~/VMs/Ubuntu.utm/Data/disk.qcow2", bytes: 300_000)
        let found = LargeOldFinder(env: s.env).find(minSize: 200_000)
        #expect(Set(found.map { $0.url.lastPathComponent }) == ["Windows 11.pvm", "Ubuntu.utm"])
        #expect(found.allSatisfy { $0.kind == .virtualMachine })
    }
}
