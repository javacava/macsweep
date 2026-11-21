import Foundation
import Testing
@testable import SweepCore

@Suite struct AdminScriptTests {
    @Test func escapesQuotesAndBackslashes() {
        let s = AdminScript.make(#"echo "hi" \ there"#)
        #expect(s == #"do shell script "echo \"hi\" \\ there" with administrator privileges"#)
    }

    @Test func shellQuoteHandlesSingleQuotes() {
        #expect(AdminScript.shellQuote("Joe's WiFi") == #"'Joe'\''s WiFi'"#)
        #expect(AdminScript.shellQuote("plain") == "'plain'")
    }

    @Test func processRunnerRunsRealCommands() {
        let r = ProcessRunner().run("/bin/echo", ["hello"])
        #expect(r.ok)
        #expect(r.output == "hello\n")
        #expect(!ProcessRunner().run("/nonexistent/tool", []).ok)
        #expect(ProcessRunner().run("/usr/bin/false", []).status == 1)
    }
}

@Suite struct MaintenanceTests {
    @Test func catalogIsComplete() {
        #expect(MaintenanceTask.all.count >= 8)
        #expect(Set(MaintenanceTask.all.map(\.id)).count == MaintenanceTask.all.count)
        for t in MaintenanceTask.all {
            #expect(!t.commands.isEmpty)
            #expect(t.commands.allSatisfy { $0.hasPrefix("/") }, "\(t.id) uses absolute paths")
        }
    }

    @Test func adminTasksShareOnePasswordPrompt() {
        let runner = FakeRunner()
        let tasks = MaintenanceTask.all.filter { ["flush-dns", "free-ram", "quicklook-cache"].contains($0.id) }
        let results = MaintenanceRunner(runner: runner).run(tasks)
        #expect(results.count == 3)
        let osa = runner.calls.filter { $0[0] == "/usr/bin/osascript" }
        #expect(osa.count == 1)
        #expect(osa[0][2].contains("purge"))
        #expect(osa[0][2].contains("dscacheutil -flushcache"))
        #expect(runner.calls.contains(["/usr/bin/qlmanage", "-r", "cache"]))
    }

    @Test func stopsTaskOnFirstFailingCommand() {
        let runner = FakeRunner()
        runner.responses["/usr/bin/qlmanage -r cache"] = CommandResult(status: 1, error: "nope")
        let task = MaintenanceTask.all.first { $0.id == "quicklook-cache" }!
        let r = MaintenanceRunner(runner: runner).run([task])
        #expect(r["quicklook-cache"]?.ok == false)
        #expect(runner.calls.count == 1)
    }

    @Test func dueTasksDependOnLastRun() {
        let now = Date()
        #expect(MaintenanceRunner.due(lastRun: [:], now: now).count == MaintenanceTask.all.count)
        var last: [String: Date] = [:]
        for t in MaintenanceTask.all { last[t.id] = now }
        #expect(MaintenanceRunner.due(lastRun: last, now: now).isEmpty)
        last["free-ram"] = now.addingTimeInterval(-2 * day)
        #expect(MaintenanceRunner.due(lastRun: last, now: now).map(\.id) == ["free-ram"])
    }
}

@Suite struct LaunchItemTests {
    func agent(_ s: Sandbox, _ path: String, label: String, program: String? = nil, args: [String]? = nil,
               runAtLoad: Bool = true, keepAlive: Any? = nil) {
        var d: [String: Any] = ["Label": label, "RunAtLoad": runAtLoad]
        if let program { d["Program"] = program }
        if let args { d["ProgramArguments"] = args }
        if let keepAlive { d["KeepAlive"] = keepAlive }
        s.plist(path, d)
    }

    @Test func readsAllThreeScopes() {
        let s = Sandbox()
        agent(s, "~/Library/LaunchAgents/com.a.plist", label: "com.a", program: "/Applications/A.app/Contents/MacOS/A")
        agent(s, "/Library/LaunchAgents/com.b.plist", label: "com.b", args: ["/usr/local/bin/b", "--x"], keepAlive: ["SuccessfulExit": false])
        agent(s, "/Library/LaunchDaemons/com.c.plist", label: "com.c", program: "/x", runAtLoad: false)
        s.file("~/Library/LaunchAgents/notes.txt")
        s.file("~/Library/LaunchAgents/broken.plist", bytes: 20)
        let items = LaunchItemsManager(env: s.env, runner: FakeRunner()).items()
        #expect(items.map(\.label) == ["com.a", "com.b", "com.c"])
        #expect(items[0].scope == .userAgent)
        #expect(items[1].program == "/usr/local/bin/b")
        #expect(items[1].keepAlive)
        #expect(items[2].scope == .systemDaemon)
        #expect(!items[2].runAtLoad)
    }

    @Test func parsesPrintDisabled() {
        let out = """
        disabled services = {
            "com.foo.agent" => disabled
            "com.bar.agent" => enabled
            "com.old.style" => true
            "com.old.other" => false
        }
        """
        #expect(LaunchItemsManager.parseDisabled(out) == ["com.foo.agent", "com.old.style"])
    }

    @Test func userAgentToggleUsesLaunchctlWithoutPassword() {
        let s = Sandbox()
        agent(s, "~/Library/LaunchAgents/com.a.plist", label: "com.a", program: "/x")
        let runner = FakeRunner()
        let m = LaunchItemsManager(env: s.env, runner: runner, uid: 501)
        let item = m.items()[0]
        m.setEnabled(item, false)
        #expect(runner.calls == [["/bin/launchctl", "bootout", "gui/501/com.a"], ["/bin/launchctl", "disable", "gui/501/com.a"]])
        m.setEnabled(item, true)
        #expect(runner.calls.suffix(2) == [["/bin/launchctl", "enable", "gui/501/com.a"],
                                           ["/bin/launchctl", "bootstrap", "gui/501", item.plist.path]])
    }

    @Test func daemonToggleAsksForAdmin() {
        let s = Sandbox()
        agent(s, "/Library/LaunchDaemons/com.d.plist", label: "com.d", program: "/x")
        let runner = FakeRunner()
        let m = LaunchItemsManager(env: s.env, runner: runner, uid: 501)
        m.setEnabled(m.items()[0], false)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0][0] == "/usr/bin/osascript")
        #expect(runner.calls[0][2].contains("'bootout' 'system/com.d'"))
    }

    @Test func disabledLabelsCombinesDomains() {
        let runner = FakeRunner()
        runner.responses["/bin/launchctl print-disabled gui/501"] = CommandResult(status: 0, output: #""com.u" => disabled"#)
        runner.responses["/bin/launchctl print-disabled system"] = CommandResult(status: 0, output: #""com.s" => disabled"#)
        let m = LaunchItemsManager(env: Sandbox().env, runner: runner, uid: 501)
        #expect(m.disabledLabels() == ["com.u", "com.s"])
    }
}

@Suite struct MalwareTests {
    func item(_ s: Sandbox, label: String, program: String?, createProgram: Bool = true) -> LaunchItem {
        var d: [String: Any] = ["Label": label]
        if let program {
            d["Program"] = program
            if createProgram { s.file(program, bytes: 100) }
        }
        s.plist("~/Library/LaunchAgents/\(label).plist", d)
        return LaunchItem(plist: s.env.resolve("~/Library/LaunchAgents/\(label).plist"), scope: .userAgent)!
    }

    func scanner(_ s: Sandbox, signed: Bool = false) -> MalwareScanner {
        MalwareScanner(env: s.env, codeSignatureCheck: { _ in signed })
    }

    @Test func knownFamilyBySignature() {
        let s = Sandbox()
        let t = scanner(s).evaluate(item(s, label: "com.pcv.hlpramc", program: "/Library/Application Support/amc/hlp"))
        #expect(t?.level == .known)
        #expect(t?.reasons.first?.contains("Advanced Mac Cleaner") == true)
        #expect(t?.files.count == 2, "plist and program")
    }

    @Test func programInTmpIsSuspicious() {
        let s = Sandbox()
        let t = scanner(s).evaluate(item(s, label: "com.update.service", program: "/private/tmp/updater"))
        #expect(t?.level == .suspicious)
    }

    @Test func hiddenFolderAndAppleImpersonation() {
        let s = Sandbox()
        let t = scanner(s).evaluate(item(s, label: "com.apple.systemhelper", program: "/Users/Shared/.cache/helper"))
        #expect(t?.level == .suspicious)
        #expect(t!.reasons.count >= 3)
    }

    @Test func randomNameOnlyCountsWhenUnsigned() {
        let s = Sandbox()
        let i = item(s, label: "com.xkcdqwrtz.bnmvcxzq", program: "/Library/Application Support/x/agent")
        #expect(scanner(s, signed: true).evaluate(i) == nil)
        #expect(scanner(s, signed: false).evaluate(i)?.level == .suspicious)
    }

    @Test func brokenItemWhenProgramMissing() {
        let s = Sandbox()
        let t = scanner(s, signed: true).evaluate(item(s, label: "com.vendor.updater", program: "/Applications/Gone.app/x", createProgram: false))
        #expect(t?.level == .broken)
        #expect(t?.files.count == 1, "only the plist is removed for broken items")
    }

    @Test func normalSignedItemIsClean() {
        let s = Sandbox()
        #expect(scanner(s, signed: true).evaluate(item(s, label: "com.google.keystone.agent", program: "/Library/Google/ks")) == nil)
        #expect(scanner(s).evaluate(item(s, label: "com.no.program", program: nil)) == nil)
    }

    @Test func scanSortsByLevel() {
        let s = Sandbox()
        let items = [item(s, label: "com.vendor.gone", program: "/Applications/G.app/x", createProgram: false),
                     item(s, label: "com.genieo.engine", program: "/Applications/G2.app/x")]
        #expect(scanner(s).scan(items).map(\.level) == [.known, .broken])
    }

    @Test func randomNameHeuristic() {
        #expect(MalwareScanner.looksRandom("com.xkcdqwrtz"))
        #expect(MalwareScanner.looksRandom("com.a1b2c3d4e5f6"))
        #expect(!MalwareScanner.looksRandom("com.google.keystone.agent"))
        #expect(!MalwareScanner.looksRandom("com.adobe.AdobeCreativeCloud"))
        #expect(!MalwareScanner.looksRandom("com.docker.vmnetd"))
    }

    @Test func realSystemBinaryIsSigned() {
        #expect(MalwareScanner.isValidlySigned(URL(fileURLWithPath: "/bin/ls")))
        let s = Sandbox()
        #expect(!MalwareScanner.isValidlySigned(s.file("~/unsigned.sh", bytes: 10)))
    }
}

@Suite struct PrivacyTests {
    @Test func findsBrowserTracesButNeverPasswords() {
        let s = Sandbox()
        s.file("~/Library/Safari/History.db", bytes: 500)
        s.file("~/Library/Application Support/Google/Chrome/Default/History", bytes: 500)
        s.file("~/Library/Application Support/Google/Chrome/Default/Cookies", bytes: 500)
        s.file("~/Library/Application Support/Google/Chrome/Default/Login Data", bytes: 500)
        s.file("~/Library/Application Support/Google/Chrome/Profile 1/Web Data", bytes: 500)
        s.file("~/Library/Application Support/Firefox/Profiles/abc.default/places.sqlite", bytes: 500)
        s.file("~/Library/Application Support/Firefox/Profiles/abc.default/logins.json", bytes: 500)
        s.file("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3", bytes: 50)
        let items = PrivacyScanner(env: s.env).scan()
        let ids = Set(items.map(\.id))
        #expect(ids.isSuperset(of: ["Safari-history", "Google Chrome-history", "Google Chrome-cookies",
                                    "Google Chrome (Profile 1)-autofill", "Firefox (abc.default)-history", "macOS-recentItems"]))
        let allFiles = items.flatMap(\.files)
        #expect(!allFiles.contains { PrivacyScanner.isProtected($0) }, "passwords are never offered")
        #expect(items.allSatisfy { $0.size > 0 })
    }

    @Test func emptyHomeHasNoTraces() {
        #expect(PrivacyScanner(env: Sandbox().env).scan().isEmpty)
    }

    @Test func wifiParsingAndRemoval() {
        let out = "Preferred networks on en0:\n\tHome WiFi\n\tCafe's Net\n\n"
        #expect(WiFiNetworks.parse(out) == ["Home WiFi", "Cafe's Net"])
        let runner = FakeRunner()
        runner.responses["/usr/sbin/networksetup"] = CommandResult(status: 0, output: out)
        let w = WiFiNetworks(runner: runner)
        #expect(w.list() == ["Home WiFi", "Cafe's Net"])
        _ = w.remove("Cafe's Net")
        #expect(runner.calls.last?[2].contains(#"'Cafe'\\''s Net'"#) == true)
    }
}

@Suite struct MonitorTests {
    @Test func cpuUsageFromTicks() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        #expect(abs(CPUTicks.usage(from: a, to: b) - 0.15) < 0.0001)
        #expect(CPUTicks.usage(from: a, to: a) == 0)
    }

    @Test func memoryUsedAndPressure() {
        let gb: UInt64 = 1 << 30
        let m = MemoryStats(total: 16 * gb, free: 4 * gb, active: 6 * gb, inactive: 2 * gb, wired: 2 * gb,
                            compressed: 1 * gb, purgeable: 1 * gb, external: 1 * gb)
        #expect(m.used == 9 * gb)
        #expect(m.pressure == .normal)
        let tight = MemoryStats(total: 16 * gb, free: 0, active: 9 * gb, inactive: gb / 2, wired: 3 * gb,
                                compressed: 6 * gb, purgeable: 0, external: 0)
        #expect(tight.pressure == .critical)
        #expect(tight.usedFraction <= 1)
    }

    @Test func liveReadersReturnSaneValues() {
        let t = SystemMonitor.cpuTicks()
        #expect(t != nil)
        let m = SystemMonitor.memory()!
        #expect(m.total > 0 && m.used <= m.total)
        let d = SystemMonitor.disk()!
        #expect(d.total > d.available && d.available > 0)
        _ = SystemMonitor.network()
    }

    @Test func parsesPsOutput() {
        let out = "  1   0.3  12345 launchd\n 523  45,5 204800 Google Chrome Helper\nbad line\n"
        let p = SystemMonitor.parseProcesses(out)
        #expect(p.count == 2)
        #expect(p[1].name == "Google Chrome Helper")
        #expect(p[1].cpu == 45.5)
        #expect(p[1].memoryBytes == 204800 * 1024)
    }

    @Test func topProcessesSorts() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 0, output: "1 1.0 100 a\n2 9.0 50 b\n3 5.0 900 c\n")
        #expect(SystemMonitor.topProcesses(limit: 2, runner: runner).map(\.name) == ["b", "c"])
        #expect(SystemMonitor.topProcesses(limit: 1, byMemory: true, runner: runner).map(\.name) == ["c"])
    }

    @Test func diskStatsMath() {
        let d = DiskStats(total: 1000, available: 250)
        #expect(d.used == 750)
        #expect(d.usedFraction == 0.75)
    }
}

@Suite struct ActivityLogTests {
    @Test func persistsAcrossInstances() {
        let s = Sandbox()
        let url = s.env.resolve("~/state/activity.json")
        let log = ActivityLog(fileURL: url)
        let now = Date()
        log.record(module: "cleanup", freed: 1000, items: 3, at: now.addingTimeInterval(-10 * day))
        log.record(module: "uninstaller", freed: 500, items: 1, at: now)
        log.markMaintenance(["flush-dns"], at: now)
        let again = ActivityLog(fileURL: url)
        #expect(again.totalFreed == 1500)
        #expect(again.freed(since: now.addingTimeInterval(-day)) == 500)
        #expect(again.state.lastMaintenance["flush-dns"] != nil)
        #expect(again.state.entries.count == 2)
    }

    @Test func corruptFileStartsFresh() {
        let s = Sandbox()
        let url = s.file("~/state/activity.json", data: Data("{not json".utf8))
        #expect(ActivityLog(fileURL: url).totalFreed == 0)
    }
}

@Suite struct QuickScanTests {
    @Test func scanAndRunCleansJunkAndThreats() {
        let s = Sandbox()
        s.file("~/Library/Caches/com.foo/x", bytes: 9000)
        s.file("~/Library/Developer/Xcode/Archives/2020/old.xcarchive/x", bytes: 9000,
               modified: Date().addingTimeInterval(-400 * day)) // not selected by default
        s.plist("~/Library/LaunchAgents/com.genieo.engine.plist", ["Label": "com.genieo.engine", "Program": "/Applications/G.app/x"])
        let runner = FakeRunner()
        let remover = RecordingRemover()
        let care = QuickScan(env: s.env, runner: runner, remover: remover,
                             malware: MalwareScanner(env: s.env, codeSignatureCheck: { _ in true }))
        let report = care.scan(installedApps: [])
        #expect(report.threats.count == 1)
        #expect(report.reclaimable > 0)
        #expect(!report.isClean)
        #expect(report.dueTasks.allSatisfy { !$0.needsAdmin && $0.automatic }, "only light, password-free tasks")

        let result = care.run(report)
        #expect(result.cleaned.removed.count == 1)
        #expect(!s.exists("~/Library/Caches/com.foo"))
        #expect(s.exists("~/Library/LaunchAgents/com.genieo.engine.plist"), "threats are reported, not removed")
        #expect(s.exists("~/Library/Developer/Xcode/Archives/2020"), "unselected junk kept")
        #expect(!runner.calls.contains { $0[0] == "/bin/launchctl" })
        #expect(!runner.calls.contains { $0[0] == "/usr/bin/osascript" })
        #expect(!runner.calls.contains { $0[0].contains("diskutil") || $0[0].contains("atsutil") }, "no heavy tasks")
    }

    @Test func cleanMacReportsClean() {
        let s = Sandbox()
        let care = QuickScan(env: s.env, runner: FakeRunner(), remover: RecordingRemover())
        #expect(care.scan(installedApps: []).isClean)
    }
}
