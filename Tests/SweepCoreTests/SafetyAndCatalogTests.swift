import Foundation
import Testing
@testable import SweepCore

/// Safety marks on every row, language versions, VM disks and the tools added to the catalog.

@Suite struct SafetyMarkTests {
    @Test func nothingThatNeedsAThoughtIsPreselected() {
        for rule in DevFolderScanner.rules where (rule.safety ?? rule.group.safety) != .safe {
            #expect(!rule.selected, "\(rule.title) is \(rule.safety ?? rule.group.safety) but preselected")
        }
        for rule in JunkRules.all where (rule.safety ?? rule.category.safety) != .safe {
            #expect(!rule.selectedByDefault, "\(rule.id) is not safe but preselected")
        }
        #expect(DevFolderScanner.rules.allSatisfy { (rule) in (rule.safety ?? rule.group.safety) != .kept },
                "a kept item is never a rule that removes a folder")
    }

    @Test func everyMarkHasTexts() {
        for s in Safety.allCases { #expect(!s.title.isEmpty && !s.explanation.isEmpty && !s.symbol.isEmpty) }
        #expect(Safety.safe < .review && Safety.review < .kept)
    }

    @Test func junkItemsCarryTheirMark() {
        let s = Sandbox(now: Date())
        s.file("~/Library/Caches/com.example.app/cache.db", bytes: 5000)
        s.file("~/Library/Application Support/MobileSync/Backup/abc/Manifest.db", bytes: 5000)
        let r = JunkScanner(env: s.env).scan()
        #expect(r.items.first { $0.category == .userCache }?.safety == .safe)
        let backup = r.items.first { $0.category == .iosBackups }
        #expect(backup?.safety == .review && backup?.selectedByDefault == false)
    }

    @Test func keptItemsAreNeverRemoved() {
        let s = Sandbox()
        let file = s.file("~/.colima/_lima/colima/diffdisk", bytes: 5000)
        let kept = DevItem(id: "x", group: .virtualMachines, title: "Colima", detail: "", size: 5000,
                           removal: .files([file]), safetyOverride: .kept)
        let report = DevCleaner(env: s.env, runner: FakeRunner()).remove([kept])
        #expect(report.removed.isEmpty && report.failed.count == 1)
        #expect(s.exists("~/.colima/_lima/colima/diffdisk"))
    }

    @Test func claudeCodeVersionInUseIsListedAsKept() throws {
        let s = Sandbox()
        for v in ["2.0.1", "2.0.5", "2.0.9"] { s.file("~/.local/share/claude/versions/\(v)", bytes: 5000) }
        try FileManager.default.createDirectory(at: s.env.resolve("~/.local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.env.resolve("~/.local/bin/claude").path,
                                                   withDestinationPath: s.env.resolve("~/.local/share/claude/versions/2.0.5").path)
        let items = DevFolderScanner(env: s.env).oldClaudeCodeVersions()
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        #expect(byName["Claude Code 2.0.5"]?.safety == .kept, "in use")
        #expect(byName["Claude Code 2.0.9"]?.safety == .kept, "newest")
        #expect(byName["Claude Code 2.0.1"]?.safety == .safe && byName["Claude Code 2.0.1"]?.selectedByDefault == true)
    }
}

@Suite struct ToolVersionTests {
    @Test func pyenvKeepsTheGlobalVersion() {
        let s = Sandbox()
        s.file("~/.pyenv/versions/3.11.9/bin/python", bytes: 5000)
        s.file("~/.pyenv/versions/3.12.4/bin/python", bytes: 5000)
        s.file("~/.pyenv/version", data: Data("3.12.4\n".utf8))
        let items = ToolVersionScanner(env: s.env).scan()
        #expect(items.first { $0.title == "Python 3.12.4" }?.safety == .kept)
        let old = items.first { $0.title == "Python 3.11.9" }
        #expect(old?.safety == .review && old?.selectedByDefault == false && old?.group == .toolVersions)
    }

    @Test func nvmDefaultAliasMatchesAMajorVersion() {
        let s = Sandbox()
        s.file("~/.nvm/versions/node/v18.20.0/bin/node", bytes: 5000)
        s.file("~/.nvm/versions/node/v20.11.1/bin/node", bytes: 5000)
        s.file("~/.nvm/alias/default", data: Data("20".utf8))
        let items = ToolVersionScanner(env: s.env).scan()
        #expect(items.first { $0.title == "Node v20.11.1" }?.safety == .kept)
        #expect(items.first { $0.title == "Node v18.20.0" }?.isRemovable == true)
    }

    @Test func withoutADefaultTheNewestIsKept() {
        let s = Sandbox()
        s.file("~/.rbenv/versions/3.2.2/bin/ruby", bytes: 5000)
        s.file("~/.rbenv/versions/3.3.0/bin/ruby", bytes: 5000)
        let items = ToolVersionScanner(env: s.env).scan()
        #expect(items.first { $0.title == "Ruby 3.3.0" }?.safety == .kept)
        #expect(items.first { $0.title == "Ruby 3.3.0" }?.detail.contains("newest") == true)
        #expect(items.first { $0.title == "Ruby 3.2.2" }?.isRemovable == true)
    }

    @Test func asdfAndMiseReadTheirConfigsAndSkipAliasLinks() throws {
        let s = Sandbox()
        s.file("~/.asdf/installs/nodejs/18.19.0/bin/node", bytes: 5000)
        s.file("~/.asdf/installs/nodejs/20.11.1/bin/node", bytes: 5000)
        s.file("~/.tool-versions", data: Data("# comment\nnodejs 18.19.0\n".utf8))
        s.file("~/.local/share/mise/installs/python/3.11.9/bin/python", bytes: 5000)
        s.file("~/.local/share/mise/installs/python/3.12.4/bin/python", bytes: 5000)
        try FileManager.default.createSymbolicLink(atPath: s.env.resolve("~/.local/share/mise/installs/python/3.12").path,
                                                   withDestinationPath: "3.12.4")
        s.file("~/.config/mise/config.toml", data: Data("[env]\nX = \"1\"\n[tools]\npython = [\"3.11\"]\n".utf8))
        let items = ToolVersionScanner(env: s.env).scan()
        #expect(items.first { $0.title == "nodejs 18.19.0" }?.safety == .kept)
        #expect(items.first { $0.title == "nodejs 20.11.1" }?.isRemovable == true)
        #expect(items.first { $0.title == "python 3.11.9" }?.safety == .kept)
        #expect(items.first { $0.title == "python 3.12.4" }?.isRemovable == true)
        #expect(!items.contains { $0.title == "python 3.12" }, "alias symlinks are not versions")
    }

    @Test func versionMatching() {
        #expect(ToolVersionScanner.matches("v20.11.1", any: ["20"]))
        #expect(ToolVersionScanner.matches("v20.11.1", any: ["v20.11"]))
        #expect(!ToolVersionScanner.matches("v2.0.0", any: ["20"]))
        #expect(!ToolVersionScanner.matches("3.12.4", any: ["3.1"]))
        #expect(!ToolVersionScanner.matches("3.12.4", any: [""]))
        #expect(ToolVersionScanner.miseConfig(URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }
}

@Suite struct CatalogAdditionsTests {
    @Test func vmDisksAreShownButKept() {
        let s = Sandbox()
        s.file("~/.colima/_lima/colima/diffdisk", bytes: 5000)
        s.file("~/.lima/default/diffdisk", bytes: 5000)
        s.file("~/.lima/_config/user", bytes: 5000)
        let items = VirtualMachineDisks(env: s.env).scan()
        #expect(Set(items.map(\.title)) == ["Colima", "Lima · default"])
        #expect(items.allSatisfy { $0.safety == .kept && !$0.isRemovable && !$0.selectedByDefault })
    }

    @Test func aiCodingToolsOfferLogsNotHistory() {
        let s = Sandbox()
        for p in ["~/.codex/log/codex-tui.log", "~/.codex/sessions/2026/11/rollout.jsonl", "~/.claude/debug/a.txt",
                  "~/.claude/projects/-x/session.jsonl", "~/.claude/projects/-x/memory/MEMORY.md", "~/.claude/settings.json",
                  "~/Library/Application Support/Windsurf/Cache/data_1", "~/Library/Application Support/Windsurf/User/settings.json"] {
            s.file(p, bytes: 5000)
        }
        let items = DevFolderScanner(env: s.env).scan()
        let byTitle = Dictionary(items.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byTitle["Codex CLI logs"]?.selectedByDefault == true)
        #expect(byTitle["Codex CLI conversation history"]?.safety == .review)
        #expect(byTitle["Codex CLI conversation history"]?.selectedByDefault == false)
        #expect(byTitle["Claude Code debug logs"]?.safety == .safe)
        #expect(byTitle["Windsurf cache"]?.group == .ideCaches)
        for item in items {
            guard case .files(let urls) = item.removal else { continue }
            for u in urls {
                #expect(!u.path.contains("/.claude/projects") && u.lastPathComponent != "settings.json" && !u.path.contains("/User"),
                        "\(u.path) must never be offered")
            }
        }
    }

    @Test func comfyUIModelsAreListedOneByOne() {
        let s = Sandbox()
        s.file("~/Documents/ComfyUI/models/checkpoints/sdxl.safetensors", bytes: 11 * 1_048_576)
        s.file("~/Documents/ComfyUI/models/loras/tiny.safetensors", bytes: 100)
        s.file("~/Documents/ComfyUI/output/my-picture.png", bytes: 11 * 1_048_576)
        let items = AIModelScanner(env: s.env).scan()
        #expect(items.map(\.title) == ["checkpoints/sdxl.safetensors"])
        #expect(items.first?.safety == .review && items.first?.selectedByDefault == false)
    }

    @Test func chatAppCachesAreWholeFoldersAndNothingElse() {
        let s = Sandbox()
        s.file("~/Library/Application Support/Slack/Cache/Cache_Data/f_000001", bytes: 5000)
        s.file("~/Library/Application Support/Slack/Code Cache/js/abc", bytes: 5000)
        s.file("~/Library/Application Support/Slack/Local Storage/leveldb/000003.log", bytes: 5000)
        s.file("~/Library/Application Support/Slack/storage/root-state.json", bytes: 5000)
        let r = JunkScanner(env: s.env).scan(categories: [.appCaches])
        #expect(Set(r.items.map(\.url.lastPathComponent)) == ["Cache", "Code Cache"])
        #expect(r.items.allSatisfy { $0.safety == .safe && $0.selectedByDefault })
    }

    @Test func newRulesDoNotOverlapOrPointAtProtectedFolders() {
        #expect(Set(DevFolderScanner.rules.map(\.path)).count == DevFolderScanner.rules.count)
        #expect(Set(JunkRules.all.map(\.id)).count == JunkRules.all.count)
        let s = Sandbox()
        let g = SafetyGuard(env: s.env)
        for rule in JunkRules.all where rule.mode == .whole {
            #expect(g.check(s.env.resolve(rule.path)) == .allowed, "\(rule.path)")
        }
        #expect(DevFolderScanner.rules.allSatisfy { !$0.tool.isEmpty })
    }
}
