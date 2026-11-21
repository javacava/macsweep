import Foundation
import Testing
@testable import SweepCore

/// Features added after comparing with PureMac: more caches, exclusions, Full Disk Access check,
/// protection audit, purgeable space and the command-line clean.

@Suite struct MoreCachesTests {
    @Test func newDeveloperCachesAreFound() {
        let s = Sandbox()
        for p in ["~/.cache/uv/wheels/x", "~/Library/Caches/pypoetry/cache/x", "~/Library/Caches/deno/deps/x",
                  "~/.cache/puppeteer/chrome/x", "~/go/pkg/mod/cache/x", "~/.gradle/wrapper/dists/gradle-8/x",
                  "~/.cargo/git/checkouts/x", "~/.nuget/packages/x", "~/.cache/yarn/v6/x",
                  "~/Library/Developer/XCTestDevices/0000-AAAA/data"] {
            s.file(p, bytes: 5000)
        }
        let items = DevFolderScanner(env: s.env).scan()
        let titles = Set(items.map(\.title))
        for t in ["uv", "Poetry", "Deno", "Puppeteer (browsers)", "Go (modules)", "Gradle (wrapper distributions)",
                  "Cargo (git checkouts)", "NuGet", "Yarn (~/.cache)", "0000-AAAA"] {
            #expect(titles.contains(t), "\(t) missing")
        }
        // Big re-downloads start unselected.
        for t in ["Go (modules)", "Gradle (wrapper distributions)", "NuGet", "Puppeteer (browsers)"] {
            #expect(items.first { $0.title == t }?.selectedByDefault == false, "\(t) should be opt-in")
        }
    }

    @Test func aiToolsOfferLogsAndCachesButNeverModelsOrChats() {
        let s = Sandbox()
        s.file("~/.ollama/logs/server.log", bytes: 5000)
        s.file("~/.ollama/models/blobs/sha256-abc", bytes: 50_000)
        s.file("~/.ollama/history", bytes: 500)
        s.file("~/Library/Caches/ollama/x", bytes: 5000)
        s.file("~/.lmstudio/server-logs/2024-11.log", bytes: 5000)
        s.file("~/.lmstudio/conversations/chat.json", bytes: 5000)
        let ai = DevFolderScanner(env: s.env).scan().filter { $0.group == .aiTools }
        #expect(Set(ai.map(\.title)) == ["Ollama logs", "Ollama cache", "LM Studio server logs"])
        let paths: [String] = ai.flatMap { (item: DevItem) -> [String] in
            if case .files(let u) = item.removal { return u.map(\.path) }
            return []
        }
        #expect(!paths.contains { $0.contains("models") || $0.contains("history") || $0.contains("conversations") })
    }

    @Test func newRulePathsAreUniqueAndRemovable() {
        let s = Sandbox()
        let g = SafetyGuard(env: s.env)
        #expect(Set(DevFolderScanner.rules.map(\.path)).count == DevFolderScanner.rules.count)
        for rule in DevFolderScanner.rules where rule.mode == .whole {
            #expect(g.check(s.env.resolve(rule.path)) == .allowed, "\(rule.path)")
        }
        for group in DevItem.Group.allCases { #expect(!group.hint.isEmpty) }
    }

    @Test func sandboxContainerCachesAreFound() {
        let s = Sandbox()
        s.file("~/Library/Containers/com.acme.Editor/Data/Library/Caches/com.acme.Editor/Cache.db", bytes: 700_000)
        s.file("~/Library/Containers/com.acme.Editor/Data/Library/Caches/tiny.db", bytes: 1000)       // below the floor
        s.file("~/Library/Containers/com.acme.Editor/Data/Library/Application Support/doc.db", bytes: 900_000) // not a cache
        s.file("~/Library/Group Containers/TEAM.com.acme.shared/Library/Caches/shared.db", bytes: 800_000)
        s.file("~/Library/Containers/com.acme.Other/Data/Library/Caches/CloudKit/db", bytes: 900_000) // excluded name
        let r = JunkScanner(env: s.env).scan(categories: [.containerCaches])
        #expect(Set(r.items.map { $0.url.lastPathComponent }) == ["com.acme.Editor", "shared.db"])
        #expect(r.items.allSatisfy { $0.url.path.contains("/Caches/") })
        #expect(r.items.allSatisfy { $0.selectedByDefault })
    }

    @Test func containerCachesCanBeCleanedButTheirCachesFolderStays() {
        let s = Sandbox()
        s.file("~/Library/Containers/com.acme.Editor/Data/Library/Caches/blob", bytes: 700_000)
        let r = JunkScanner(env: s.env).scan(categories: [.containerCaches])
        let report = Cleaner(env: s.env, remover: RecordingRemover()).remove(r.items)
        #expect(report.removed.count == 1)
        #expect(s.exists("~/Library/Containers/com.acme.Editor/Data/Library/Caches"))
    }
}

@Suite struct ExclusionTests {
    @Test func excludedPathsAreNeverOffered() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.keep.me/x", bytes: 5000)
        s.file("~/Library/Caches/com.drop.me/x", bytes: 5000)
        s.file("~/Code/app/package.json")
        s.file("~/Code/app/node_modules/x", bytes: 5000)
        s.file("~/Movies/keep.mov", bytes: 300_000)
        s.file("~/.npm/_cacache/x", bytes: 5000)
        var env = s.env
        env.exclusions = [env.resolve("~/Library/Caches/com.keep.me"), env.resolve("~/Code/app"),
                          env.resolve("~/Movies/keep.mov"), env.resolve("~/.npm")]
        #expect(JunkScanner(env: env).scan().items.map { $0.url.lastPathComponent } == ["com.drop.me"])
        #expect(BuildArtifactFinder(env: env).find().isEmpty)
        #expect(LargeOldFinder(env: env).find(minSize: 100_000).isEmpty)
        #expect(!DevFolderScanner(env: env).scan().contains { $0.title == "npm" })
    }

    @Test func guardRefusesExcludedPathsInsideAndAround() {
        let s = Sandbox()
        var env = s.env
        env.exclusions = [env.resolve("~/Library/Caches/com.keep.me/important")]
        let g = SafetyGuard(env: env)
        #expect(g.check(env.resolve("~/Library/Caches/com.keep.me/important")) == .denied("Excluded in Settings"))
        #expect(g.check(env.resolve("~/Library/Caches/com.keep.me/important/sub")) != .allowed)
        // The parent would take the excluded path with it.
        #expect(g.check(env.resolve("~/Library/Caches/com.keep.me")) != .allowed)
        #expect(g.check(env.resolve("~/Library/Caches/com.other")) == .allowed)
        // A name that merely starts the same is not inside.
        #expect(g.check(env.resolve("~/Library/Caches/com.keep.me/important-not")) == .allowed)
    }

    @Test func cleanerKeepsExcludedFilesEvenIfAskedDirectly() {
        let s = Sandbox()
        let keep = s.file("~/Library/Caches/keep/x", bytes: 100)
        var env = s.env
        env.exclusions = [keep]
        let r = Cleaner(env: env, remover: RecordingRemover()).remove([(keep, 100)])
        #expect(r.removed.isEmpty)
        #expect(s.exists("~/Library/Caches/keep/x"))
    }

    @Test func leftoversAndPrivacyHonourExclusions() {
        let s = Sandbox()
        let app = AppInfo(bundle: s.app("/Applications/Foo.app", id: "com.acme.foo", name: "Foo"))!
        s.file("~/Library/Preferences/com.acme.foo.plist")
        s.file("~/Library/Caches/com.acme.foo/c", bytes: 100)
        s.file("~/Library/Preferences/com.gone.app.plist")
        s.file("~/Library/Safari/History.db", bytes: 100)
        var env = s.env
        env.exclusions = [env.resolve("~/Library/Preferences")]
        #expect(LeftoverFinder(env: env).leftovers(for: app).map { $0.url.lastPathComponent } == ["com.acme.foo"])
        #expect(LeftoverFinder(env: env).orphans(installed: [app]).isEmpty)
        env.exclusions = [env.resolve("~/Library/Safari")]
        #expect(PrivacyScanner(env: env).scan().filter { $0.owner == "Safari" }.isEmpty)
    }

    @Test func noExclusionsMeansNothingExcluded() {
        let s = Sandbox()
        #expect(!s.env.isExcluded(s.env.resolve("~/anything")))
    }
}

@Suite struct FullDiskAccessTests {
    @Test func readableProbeMeansGranted() {
        let s = Sandbox()
        s.file("~/Library/Application Support/com.apple.TCC/TCC.db", bytes: 10)
        #expect(FullDiskAccess.check(env: s.env) == .granted)
    }

    @Test func unreadableProbeMeansDenied() throws {
        let s = Sandbox()
        let db = s.file("~/Library/Application Support/com.apple.TCC/TCC.db", bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db.path) }
        #expect(FullDiskAccess.check(env: s.env) == .denied)
    }

    @Test func unreadableFolderProbeMeansDenied() throws {
        let s = Sandbox()
        let mail = s.dir("~/Library/Mail")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.path) }
        #expect(FullDiskAccess.check(env: s.env) == .denied)
    }

    @Test func nothingToProbeMeansUnknown() {
        #expect(FullDiskAccess.check(env: Sandbox().env) == .unknown)
    }
}

@Suite struct SecurityAuditTests {
    @Test func parsers() {
        #expect(SecurityAudit.parseFileVault("FileVault is On.") == true)
        #expect(SecurityAudit.parseFileVault("FileVault is Off.") == false)
        #expect(SecurityAudit.parseFileVault("") == nil)
        #expect(SecurityAudit.parseSIP("System Integrity Protection status: enabled.") == true)
        #expect(SecurityAudit.parseSIP("System Integrity Protection status: disabled.") == false)
        #expect(SecurityAudit.parseSIP("System Integrity Protection status: unknown (Custom Configuration).") == false)
        #expect(SecurityAudit.parseSIP("garbage") == nil)
        #expect(SecurityAudit.parseGatekeeper("assessments enabled\n") == true)
        #expect(SecurityAudit.parseGatekeeper("assessments disabled\n") == false)
        #expect(SecurityAudit.parseFirewall("Firewall is enabled. (State = 1)") == true)
        #expect(SecurityAudit.parseFirewall("Firewall is blocking all non-essential incoming connections. (State = 2)") == true)
        #expect(SecurityAudit.parseFirewall("Firewall is disabled. (State = 0)") == false)
        #expect(SecurityAudit.parseFirewall("") == nil)
    }

    @Test func xprotectVersionAndDate() throws {
        let (v, d) = try #require(SecurityAudit.parseXProtect("Version: 5377 Installed: 2026-11-21 13:00:53 +0000\n"))
        #expect(v == "5377")
        #expect(d == ISO8601DateFormatter().date(from: "2026-11-21T13:00:53Z"))
        #expect(SecurityAudit.parseXProtect("nothing") == nil)
    }

    @Test func securityUpdatesNeedBothFlags() {
        #expect(SecurityAudit.securityUpdatesOn([:]), "missing keys mean on")
        #expect(SecurityAudit.securityUpdatesOn(["CriticalUpdateInstall": true, "ConfigDataInstall": true]))
        #expect(!SecurityAudit.securityUpdatesOn(["CriticalUpdateInstall": false]))
        #expect(!SecurityAudit.securityUpdatesOn(["ConfigDataInstall": 0 as NSNumber]))
    }

    @Test func fullRunWithCannedTools() {
        let s = Sandbox(now: ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z")!)
        s.plist("/Library/Preferences/com.apple.SoftwareUpdate.plist", ["CriticalUpdateInstall": true, "ConfigDataInstall": false])
        let runner = FakeRunner()
        runner.responses["/usr/bin/fdesetup status"] = CommandResult(status: 0, output: "FileVault is On.")
        runner.responses["/usr/bin/csrutil status"] = CommandResult(status: 0, output: "System Integrity Protection status: enabled.")
        runner.responses["/usr/sbin/spctl --status"] = CommandResult(status: 0, output: "assessments enabled")
        runner.responses["/usr/libexec/ApplicationFirewall/socketfilterfw"] = CommandResult(status: 0, output: "Firewall is disabled. (State = 0)")
        runner.responses["/usr/bin/xprotect version"] = CommandResult(status: 0, output: "Version: 5377 Installed: 2026-11-21 13:00:53 +0000")
        let checks = SecurityAudit(env: s.env, runner: runner).run()
        func state(_ id: String) -> SecurityCheck.State? { checks.first { $0.id == id }?.state }
        #expect(checks.count == 6)
        #expect(state("filevault") == .good)
        #expect(state("sip") == .good)
        #expect(state("gatekeeper") == .good)
        #expect(state("firewall") == .warning)
        #expect(state("xprotect") == .good)
        #expect(state("updates") == .warning)
        #expect(checks.filter { $0.state == .warning }.allSatisfy { $0.advice != nil })
        // Read-only: only status queries were run.
        #expect(runner.calls.allSatisfy { ["status", "--status", "--getglobalstate", "version"].contains($0.last ?? "") })
    }

    @Test func staleXProtectFromBundlePlistIsAWarning() throws {
        let s = Sandbox()
        let plist = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        s.plist(plist, ["CFBundleShortVersionString": "2190"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * day)],
                                              ofItemAtPath: s.env.resolve(plist).path)
        let check = SecurityAudit(env: s.env, runner: FakeRunner()).xprotect()
        #expect(check.state == .warning)
        #expect(check.detail.contains("2190"))
    }

    @Test func unknownWhenToolsSayNothing() {
        let checks = SecurityAudit(env: Sandbox().env, runner: FakeRunner()).run()
        #expect(checks.allSatisfy { $0.state == .unknown })
    }
}

@Suite struct PurgeableTests {
    @Test func purgeableIsTheGapBetweenTheTwoFreeFigures() {
        #expect(DiskStats(total: 1000, available: 400, strictlyFree: 300).purgeable == 100)
        #expect(DiskStats(total: 1000, available: 400, strictlyFree: 450).purgeable == 0)
        #expect(DiskStats(total: 1000, available: 400).purgeable == 0)
    }

    @Test func liveDiskReportsBothFigures() throws {
        let d = try #require(SystemMonitor.disk())
        #expect(d.strictlyFree != nil)
        #expect(d.purgeable >= 0)
    }
}

@Suite struct CommandLineCleanTests {
    @Test func parsesOptions() throws {
        let o = try CommandLineClean.parse(["--category", "trash,userLogs", "--yes", "--json", "--all"]).get()
        #expect(o.categories == [.trash, .userLogs])
        #expect(o.execute && o.json && o.includeUnselected)
        #expect(try CommandLineClean.parse([]).get() == CommandLineClean.Options())
        #expect(throws: CommandLineClean.CleanError.message("Unknown category \"bogus\"")) {
            try CommandLineClean.parse(["--category", "bogus"]).get()
        }
        #expect(throws: CommandLineClean.CleanError.self) { try CommandLineClean.parse(["--rm-rf"]).get() }
        #expect(throws: CommandLineClean.CleanError.help) { try CommandLineClean.parse(["--help"]).get() }
        #expect(CommandLineClean.usage.contains("--yes"))
    }

    @Test func dryRunRemovesNothing() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo/x", bytes: 9000)
        let remover = RecordingRemover()
        let (out, status) = CommandLineClean.run(.init(), env: s.env, remover: remover)
        #expect(status == 0)
        #expect(out.contains("Dry run"))
        #expect(out.contains("~/Library/Caches/com.foo"))
        #expect(remover.trashed.isEmpty && remover.deleted.isEmpty)
        #expect(s.exists("~/Library/Caches/com.foo/x"))
    }

    @Test func yesMovesDefaultSelectionToTrash() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo/x", bytes: 9000)
        s.file("~/Library/Application Support/MobileSync/Backup/abc/Manifest.db", bytes: 9000)   // not selected by default
        let remover = RecordingRemover()
        let (out, status) = CommandLineClean.run(.init(execute: true), env: s.env, remover: remover)
        #expect(status == 0)
        #expect(out.contains("Moved to the Trash: 1 items"))
        #expect(remover.trashed.map(\.lastPathComponent) == ["com.foo"])
        #expect(remover.deleted.isEmpty)
        #expect(s.exists("~/Library/Application Support/MobileSync/Backup/abc/Manifest.db"))
    }

    @Test func categoryFilterAndJSON() throws {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo/x", bytes: 9000)
        s.file("~/Library/Logs/app.log", bytes: 9000)
        let (out, _) = CommandLineClean.run(.init(categories: [.userLogs], json: true), env: s.env, remover: RecordingRemover())
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["dryRun"] as? Bool == true)
        let items = try #require(obj["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["category"] as? String == "userLogs")
        #expect((obj["totalBytes"] as? Int ?? 0) > 0)
    }

    @Test func failuresGiveExitCodeOne() {
        let s = Sandbox()
        s.file("~/Library/Caches/locked/x", bytes: 9000)
        let remover = RecordingRemover()
        remover.failOn = ["locked"]
        let (out, status) = CommandLineClean.run(.init(execute: true), env: s.env, remover: remover)
        #expect(status == 1)
        #expect(out.contains("Failed:"))
    }

    @Test func emptyMacSaysNothingToClean() {
        let (out, status) = CommandLineClean.run(.init(), env: Sandbox().env, remover: RecordingRemover())
        #expect(status == 0)
        #expect(out == "Nothing to clean.")
    }
}
