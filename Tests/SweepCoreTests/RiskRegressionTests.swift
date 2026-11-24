import Foundation
import Testing
@testable import SweepCore

/// Each test here reproduces a risk found in the safety audit.
@Suite struct SafetyGuardAuditTests {
    let s = Sandbox()
    var g: SafetyGuard { SafetyGuard(env: s.env) }

    @Test func protectedFoldersMatchCaseInsensitively() {
        // APFS is case-insensitive by default: ~/documents IS ~/Documents.
        #expect(g.check(s.home.appendingPathComponent("documents")) != .allowed)
        #expect(g.check(s.home.appendingPathComponent("LIBRARY")) != .allowed)
        #expect(g.check(s.home.appendingPathComponent("library/keychains/login.keychain-db")) != .allowed)
        #expect(g.check(s.root.appendingPathComponent("Library/apple/System/x")) != .allowed)
    }

    @Test func mediaLibrariesAreNeverRemoved() {
        #expect(g.check(s.env.resolve("~/Pictures/Photos Library.photoslibrary")) != .allowed)
        #expect(g.check(s.env.resolve("~/Pictures/Photos Library.photoslibrary/originals/1/a.heic")) != .allowed)
        #expect(g.check(s.env.resolve("~/Music/Music/Music Library.musiclibrary")) != .allowed)
    }

    @Test func personalDataFoldersAreProtected() {
        for p in ["~/.ssh", "~/Library/Safari", "~/Library/Messages", "~/Library/Mobile Documents/com~apple~CloudDocs",
                  "~/Library/CloudStorage", "~/Library/Application Support/AddressBook", "~/Library/Calendars"] {
            #expect(g.check(s.env.resolve(p)) != .allowed, "\(p)")
        }
        // ...but single files inside (history, an old key the user picked) can still go.
        #expect(g.check(s.env.resolve("~/Library/Safari/History.db")) == .allowed)
    }
}

@Suite struct MalwareAuditTests {
    func item(_ s: Sandbox, label: String, program: String) -> LaunchItem {
        s.file(program, bytes: 50)
        s.plist("~/Library/LaunchAgents/\(label).plist", ["Label": label, "Program": program])
        return LaunchItem(plist: s.env.resolve("~/Library/LaunchAgents/\(label).plist"), scope: .userAgent)!
    }

    @Test(arguments: [
        ("ch.protonvpn.mac.OpenVPN", "/Applications/ProtonVPN.app/Contents/MacOS/ProtonVPN"),
        ("ch.protonmail.bridge", "/Applications/Proton Mail Bridge.app/Contents/MacOS/bridge"),
        ("org.spigotmc.server", "/Applications/Spigot.app/Contents/MacOS/Spigot"),
        ("com.conduit.app.helper", "/Applications/Conduit.app/Contents/MacOS/helper"),
        ("com.weknowtech.agent", "/Applications/WeKnow.app/Contents/MacOS/agent"),
    ])
    func legitimateSoftwareIsNotKnownMalware(_ c: (String, String)) {
        let s = Sandbox()
        let t = MalwareScanner(env: s.env, codeSignatureCheck: { _ in true }).evaluate(item(s, label: c.0, program: c.1))
        #expect(t == nil, "\(c.0) flagged: \(t?.reasons ?? [])")
    }

    @Test func programInsideAppBundleIsNotDeletedPiecemeal() {
        let s = Sandbox()
        let t = MalwareScanner(env: s.env, codeSignatureCheck: { _ in true })
            .evaluate(item(s, label: "com.genieo.engine", program: "/Applications/Genieo.app/Contents/MacOS/Genieo"))!
        #expect(t.files == [t.item.plist], "an app is removed whole via the Uninstaller, not by its binary")
    }

    @Test func appleSoftwareInLibraryAppleIsNotImpersonation() {
        let s = Sandbox()
        let t = MalwareScanner(env: s.env, codeSignatureCheck: { _ in true })
            .evaluate(item(s, label: "com.apple.mobiledeviceupdater", program: "/Library/Apple/System/Library/x/MobileDeviceUpdater"))
        #expect(t == nil)
    }
}

@Suite struct QuickScanAuditTests {
    @Test func quickScanNeverDeletesThreatsOnItsOwn() {
        let s = Sandbox()
        // A developer's own agent in a hidden folder: suspicious by heuristics, but perfectly legitimate.
        s.file("~/.local/bin/sync.sh", bytes: 50)
        s.plist("~/Library/LaunchAgents/me.dev.sync.plist", ["Label": "me.dev.sync", "Program": "/Users/x/.local/bin/sync.sh"])
        s.file("/Users/x/.local/bin/sync.sh", bytes: 50)
        let runner = FakeRunner()
        let care = QuickScan(env: s.env, runner: runner, remover: RecordingRemover(),
                             malware: MalwareScanner(env: s.env, codeSignatureCheck: { _ in false }))
        let report = care.scan(installedApps: [])
        #expect(report.threats.count == 1)
        _ = care.run(report)
        #expect(s.exists("~/Library/LaunchAgents/me.dev.sync.plist"))
        #expect(s.exists("/Users/x/.local/bin/sync.sh"))
        #expect(!runner.calls.contains { $0.contains("bootout") })
    }
}

@Suite struct LeftoverAuditTests {
    @Test func twoPartBundleIDDoesNotSwallowSiblingApps() {
        #expect(LeftoverFinder.matches(name: "com.acme.plist", bundleID: "com.acme", appName: "Acme Tool"))
        #expect(!LeftoverFinder.matches(name: "com.acme.other-app", bundleID: "com.acme", appName: "Acme Tool"))
    }

    @Test func sharedVendorFoldersAreNotMatchedByAppName() {
        // An app merely called "Google" must not claim ~/Library/Application Support/Google (Chrome's data).
        #expect(!LeftoverFinder.matches(name: "Google", bundleID: "com.someone.google-search", appName: "Google"))
        #expect(!LeftoverFinder.matches(name: "Microsoft", bundleID: "com.x.microsoft", appName: "Microsoft"))
    }
}

@Suite struct DuplicateAuditTests {
    @Test func cloudOnlyPlaceholdersAreNotHashed() throws {
        // Files with no blocks on disk (iCloud "dataless" placeholders look like this): reading them
        // would download everything. A sparse file reproduces it locally.
        let s = Sandbox()
        for name in ["a.bin", "b.bin"] {
            let url = s.file("~/Docs/\(name)", data: Data())
            let fd = open(url.path, O_WRONLY); ftruncate(fd, 2_000_000); close(fd)
        }
        let files = FileWalker().files(under: s.home)
        #expect(files.allSatisfy { $0.size == 0 }, "sparse files take no disk blocks")
        #expect(DuplicateFinder.find(in: files).isEmpty)
    }
}

@Suite struct MaintenanceAuditTests {
    @Test func tasksWithMissingToolsAreHidden() {
        // `periodic` no longer ships with recent macOS.
        let present = MaintenanceTask.available { $0 != "/usr/sbin/periodic" }
        #expect(!present.contains { $0.id == "maintenance-scripts" })
        #expect(present.count == MaintenanceTask.all.count - 1)
        #expect(MaintenanceTask.available { _ in false }.isEmpty)
    }

    @Test func onlyQuickLookRunsAutomatically() {
        #expect(MaintenanceTask.all.filter(\.automatic).map(\.id) == ["quicklook-cache"])
        #expect(MaintenanceTask.all.filter { $0.automatic && $0.needsAdmin }.isEmpty)
    }

    @Test func eachAdminTaskReportsItsOwnResult() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 0, output: "MYOPENCLEANER-STATUS:free-ram:0\rMYOPENCLEANER-STATUS:flush-dns:1")
        let tasks = MaintenanceTask.all.filter { ["free-ram", "flush-dns", "reindex-spotlight"].contains($0.id) }
        let r = MaintenanceRunner(runner: runner).run(tasks)
        #expect(r["free-ram"]?.ok == true)
        #expect(r["flush-dns"]?.ok == false, "a failed task must not be shown as done")
        #expect(r["reindex-spotlight"]?.ok == false, "no marker means it never ran")
        #expect(runner.calls.count == 1, "still one password prompt")
    }

    @Test func cancelledPasswordPromptFailsEveryAdminTask() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 1, error: "User canceled.")
        let tasks = MaintenanceTask.all.filter(\.needsAdmin)
        let r = MaintenanceRunner(runner: runner).run(tasks)
        #expect(r.values.allSatisfy { !$0.ok })
    }

    @Test func adminScriptChainsCommandsPerTask() {
        let dns = MaintenanceTask.all.first { $0.id == "flush-dns" }!
        let script = MaintenanceRunner.adminScript([dns])
        #expect(script == "( /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder ) >/dev/null 2>&1; echo MYOPENCLEANER-STATUS:flush-dns:$?")
    }

    @Test func noCommandUsesRemovedLsregisterFlags() {
        let all = MaintenanceTask.all.flatMap(\.commands).joined(separator: " ")
        #expect(!all.contains("-kill"))
        #expect(!all.contains("-domain"))
    }
}

@Suite struct MiscAuditTests {
    @Test func appcastDownloadLinkMustBeHttps() {
        func item(_ u: String) -> AppcastItem { AppcastItem(downloadURL: URL(string: u)) }
        #expect(item("https://acme.com/Foo.zip").safeDownloadURL != nil)
        #expect(item("http://acme.com/Foo.zip").safeDownloadURL == nil)
        #expect(item("file:///Applications/Evil.app").safeDownloadURL == nil)
        #expect(item("ssh://host/x").safeDownloadURL == nil)
        #expect(item("x-apple.systempreferences:foo").safeDownloadURL == nil)
        #expect(AppcastItem().safeDownloadURL == nil)
    }

    @Test func spotlightIDsKeepAppsOutsideApplicationsFromBeingOrphans() {
        let out = """
        /Applications/Foo.app   kMDItemCFBundleIdentifier = com.acme.foo
        /Volumes/Ext/Tools/Bar.app   kMDItemCFBundleIdentifier = com.ext.bar
        /Users/x/broken.app   kMDItemCFBundleIdentifier = (null)
        """
        let ids = AppScanner.parseSpotlight(out)
        #expect(ids == ["com.acme.foo", "com.ext.bar"])

        let s = Sandbox()
        s.file("~/Library/Preferences/com.ext.bar.plist", bytes: 100)
        s.file("~/Library/Preferences/com.gone.app.plist", bytes: 100)
        let finder = LeftoverFinder(env: s.env)
        #expect(finder.orphans(installed: []).count == 2)
        #expect(finder.orphans(installed: [], extraBundleIDs: ids).map { $0.url.lastPathComponent } == ["com.gone.app.plist"])
    }

    @Test func recentMailAttachmentsAreKept() {
        let now = Date()
        let s = Sandbox(now: now)
        let dir = "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        s.file("\(dir)/A/contract.pdf", bytes: 5000)
        s.file("\(dir)/B/old.pdf", bytes: 5000)
        try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60 * day)],
                                               ofItemAtPath: s.env.resolve("\(dir)/B").path)
        let r = JunkScanner(env: s.env).scan(categories: [.mailAttachments])
        #expect(r.items.map { $0.url.lastPathComponent } == ["B"])
    }

    @Test func runnerSurvivesLargeOutputOnBothPipes() {
        // 300 KB to stderr and stdout: more than a pipe buffer, which used to deadlock.
        let r = ProcessRunner().run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' e >&2; head -c 300000 /dev/zero | tr '\\0' o"])
        #expect(r.ok)
        #expect(r.output.count == 300_000)
        #expect(r.error.count == 300_000)
    }

    @Test func runnerDoesNotNeedAFreeDispatchThread() {
        // On a busy Mac (or a 3-core CI machine running tests in parallel) every global-queue thread can be taken.
        // The runner must still drain stderr, or a child that fills it blocks forever.
        let release = DispatchSemaphore(value: 0)
        let blockers = 256
        for _ in 0..<blockers { DispatchQueue.global().async { release.wait(); release.signal() } }
        defer { release.signal() }
        Thread.sleep(forTimeInterval: 0.3) // let the blockers occupy the pool

        final class Box: @unchecked Sendable { var result: CommandResult? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            box.result = ProcessRunner().run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' e >&2; echo done"])
            finished.signal()
        }
        worker.start()
        let completed = finished.wait(timeout: .now() + 20) == .success
        #expect(completed, "ProcessRunner deadlocked while the dispatch pool was busy")
        #expect(box.result?.error.count == 300_000)
        #expect(box.result?.output == "done\n")
    }

    @Test func shredderRefusesItemsOnAnotherVolume() throws {
        let s = Sandbox()
        let url = s.file("~/mounted/data.bin", bytes: 500)
        var st = stat()
        lstat(url.path, &st)
        // Pretend the walk started on a different device, as when a disk is mounted inside the dropped folder.
        #expect(throws: Shredder.ShredError.self) {
            try Shredder(env: s.env).shredItem(url, device: st.st_dev &+ 1, progress: nil)
        }
        #expect(try Data(contentsOf: url) == Data(repeating: 0x41, count: 500), "untouched")
    }

    @Test func privacyAutofillLabelMentionsCards() {
        #expect(PrivacyKind.autofill.title.contains("cards"))
    }
}

@Suite struct OrphanAuditTests {
    @Test func helpersOfInstalledVendorsAreNotOrphans() {
        let s = Sandbox()
        let chrome = AppInfo(url: s.env.resolve("/Applications/Google Chrome.app"), name: "Google Chrome",
                             bundleID: "com.google.Chrome", version: "1")
        s.file("~/Library/HTTPStorages/com.google.Keystone/x", bytes: 100)   // Chrome's updater
        s.file("~/Library/Preferences/com.gone.app.plist", bytes: 100)
        let found = LeftoverFinder(env: s.env).orphans(installed: [chrome]).map { $0.url.lastPathComponent }
        #expect(found == ["com.gone.app.plist"])
    }
}

@Suite struct PrivatePrefixAuditTests {
    /// The real `/`: `/private/var/log` and `/var/log` are one folder and must get one verdict.
    let g = SafetyGuard(env: SweepEnvironment(home: URL(fileURLWithPath: "/Users/someone")))

    @Test func bothSpellingsOfSystemLogsAreAllowed() {
        #expect(g.check(URL(fileURLWithPath: "/private/var/log/system.log.0.gz")) == .allowed)
        #expect(g.check(URL(fileURLWithPath: "/var/log/system.log.0.gz")) == .allowed)
        #expect(g.check(URL(fileURLWithPath: "/private/tmp/junk")) == .allowed)
    }

    @Test func bothSpellingsOfSystemDataAreDenied() {
        for p in ["/private/etc/hosts", "/etc/hosts", "/private/var/db/receipts/x.bom", "/var/db/receipts/x.bom",
                  "/private/var/log", "/var/log", "/private/var/root/x", "/var/folders/zz/x"] {
            #expect(g.check(URL(fileURLWithPath: p)) != .allowed, "\(p)")
        }
    }

    @Test func canonicalOnlyTouchesTheThreeAliases() {
        #expect(SafetyGuard.canonical("/private/var/log") == "/var/log")
        #expect(SafetyGuard.canonical("/private/tmp") == "/tmp")
        #expect(SafetyGuard.canonical("/private/variable/x") == "/private/variable/x")
        #expect(SafetyGuard.canonical("/Users/a/private/var") == "/Users/a/private/var")
    }
}

/// Apps installed by a .pkg belong to root: the user may not move them, so macOS asks for an administrator's password.
@Suite struct AdminTrashTests {
    @Test func onlyAppsRefusedForPermissionsNeedThePassword() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000)])
        let posix = NSError(domain: NSCocoaErrorDomain, code: 512,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let app = URL(fileURLWithPath: "/Applications/Some Tool.app")
        #expect(AdminTrash.isNeeded(for: app, after: denied), "what trashItem really returns for a root-owned folder")
        #expect(AdminTrash.isNeeded(for: app, after: posix))
        #expect(!AdminTrash.isNeeded(for: app, after: missing), "a missing file is not a permission problem")
        #expect(!AdminTrash.isNeeded(for: URL(fileURLWithPath: "/Library/Caches/x"), after: denied), "never for other files")
    }

    @Test func commandQuotesEveryPathAndHandsTheAppToTheUser() {
        let c = AdminTrash.command(URL(fileURLWithPath: "/Applications/It's \"odd\".app"),
                                   trash: URL(fileURLWithPath: "/Users/me/.Trash"), owner: "me", stamp: "21.10.00")
        #expect(c.contains(#"/bin/mv '/Applications/It'\''s "odd".app' "$d""#))
        #expect(c.contains(#"d='/Users/me/.Trash/It'\''s "odd".app'"#))
        #expect(c.contains(#"'/Users/me/.Trash/It'\''s "odd" 21.10.00.app'"#), "a free name when the Trash has one already")
        #expect(c.contains("/usr/sbin/chown -R 'me'"))
        #expect(c.contains("2>/dev/null; printf"), "a protected App Store bundle may refuse chown; the move still counts")
        #expect(!c.contains("rm "), "it moves, never deletes")
    }

    @Test func reportsWhereTheAppLandedAndWhyItFailed() throws {
        let runner = FakeRunner()
        let admin = AdminTrash(runner: runner, home: URL(fileURLWithPath: "/Users/x"))
        runner.defaultResult = CommandResult(status: 0, output: "/Users/x/.Trash/Some Tool.app")
        let landed = try admin.trash(URL(fileURLWithPath: "/Applications/Some Tool.app"))
        #expect(landed?.path == "/Users/x/.Trash/Some Tool.app")
        #expect(runner.calls.first?.first == "/usr/bin/osascript")
        #expect(runner.calls.first?.last?.contains("with administrator privileges") == true)

        runner.defaultResult = CommandResult(status: 1, error: "execution error: User canceled. (-128)")
        do { _ = try admin.trash(URL(fileURLWithPath: "/Applications/X.app")); Issue.record("should throw") } catch {
            #expect(error.localizedDescription.contains("Cancelled"))
        }
    }

    @Test func aLockedAppAsksForThePassword() throws {
        let s = Sandbox()
        let app = s.file("~/Locked/Tool.app/Contents/Info.plist", bytes: 10).deletingLastPathComponent().deletingLastPathComponent()
        let parent = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 0, output: s.home.appendingPathComponent(".Trash/Tool.app").path)
        let landed = try SystemFileRemover(runner: runner, home: s.home).moveToTrash(app)
        #expect(landed?.lastPathComponent == "Tool.app")
        #expect(runner.calls.count == 1, "asked once")
    }
}

/// Other apps' containers are protected by macOS; the report says how to allow it instead of a bare error.
@Suite struct ProtectedDataTests {
    @Test func containerRefusalsPointToFullDiskAccess() throws {
        let s = Sandbox()
        let item = s.file("~/Library/Containers/com.example.Other/Data/Library/Caches/x", bytes: 10).deletingLastPathComponent()
        let parent = item.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let report = Cleaner(env: s.env, remover: SystemFileRemover(runner: FakeRunner(), home: s.home), mode: .trash)
            .remove([(item, 10)])
        #expect(report.failed.first?.reason == ProtectedData.reason)
    }

    @Test func onlyPermissionErrorsInContainersCount() {
        let home = URL(fileURLWithPath: "/Users/x")
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(ProtectedData.isProtected(URL(fileURLWithPath: "/Users/x/Library/Group Containers/G.com.x/a"), error: denied, home: home))
        #expect(!ProtectedData.isProtected(URL(fileURLWithPath: "/Users/x/Library/Containers/com.x/a"), error: missing, home: home))
        #expect(!ProtectedData.isProtected(URL(fileURLWithPath: "/Users/x/Library/Caches/a"), error: denied, home: home))
    }
}
