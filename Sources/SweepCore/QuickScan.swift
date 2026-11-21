import Foundation

/// One-click scan across modules: junk, threats, maintenance, leftovers.
public struct QuickScanReport: Sendable {
    public var junk: JunkScanResult
    public var threats: [Threat]
    public var dueTasks: [MaintenanceTask]
    public var orphanLeftovers: [Leftover]

    /// Junk selected by default plus threats (no orphans: those need a human look).
    public var reclaimable: Int64 { junk.items.filter(\.selectedByDefault).reduce(0) { $0 + $1.size } }
    public var isClean: Bool { reclaimable == 0 && threats.filter { $0.level != .broken }.isEmpty }
}

public struct QuickScanResult: Sendable {
    public var cleaned: CleanReport
    public var tasksRun: [String: CommandResult]
}

public struct QuickScan: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    public let remover: FileRemoving
    public let malware: MalwareScanner

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(),
                remover: FileRemoving = SystemFileRemover(), malware: MalwareScanner? = nil) {
        self.env = env; self.runner = runner; self.remover = remover
        self.malware = malware ?? MalwareScanner(env: env)
    }

    public func scan(lastMaintenance: [String: Date] = [:], installedApps: [AppInfo]? = nil,
                     progress: ((String) -> Void)? = nil) -> QuickScanReport {
        progress?("Looking for system junk…")
        let junk = JunkScanner(env: env).scan()
        progress?("Checking launch items…")
        let items = LaunchItemsManager(env: env, runner: runner).items()
        let threats = malware.scan(items)
        progress?("Looking for leftovers of removed apps…")
        let apps = installedApps ?? AppScanner.installedApps(env: env)
        let orphans = LeftoverFinder(env: env).orphans(installed: apps)
        // Only light tasks that need no password run from here; the rest are picked by hand in Maintenance.
        let due = MaintenanceRunner.due(lastRun: lastMaintenance, now: env.now(), among: MaintenanceTask.available())
            .filter { $0.automatic && !$0.needsAdmin }
        return QuickScanReport(junk: junk, threats: threats, dueTasks: due, orphanLeftovers: orphans)
    }

    /// Cleans default-selected junk and runs the due light tasks.
    /// Threats are only reported: heuristics can be wrong, so removing one is always a human decision
    /// (Malware page), never a side effect of a one-click clean.
    public func run(_ report: QuickScanReport, mode: RemovalMode = .trash) -> QuickScanResult {
        let cleaner = Cleaner(env: env, remover: remover, mode: mode)
        let cleaned = cleaner.remove(report.junk.items.filter(\.selectedByDefault))
        let tasks = MaintenanceRunner(runner: runner).run(report.dueTasks.filter { $0.automatic && !$0.needsAdmin })
        return QuickScanResult(cleaned: cleaned, tasksRun: tasks)
    }
}
