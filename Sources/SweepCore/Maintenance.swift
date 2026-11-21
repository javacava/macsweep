import Foundation

public struct MaintenanceTask: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let details: String
    public let symbol: String
    /// Shell command lines, run in order.
    public let commands: [String]
    public let needsAdmin: Bool
    public let recommendedEveryDays: Int
    /// Light and side-effect free enough to run without the user picking it (Quick Scan, default selection).
    public var automatic = false

    /// The tool each command line starts with.
    public var executables: [String] { commands.map { String($0.split(separator: " ")[0]) } }

    /// Tasks whose tools exist on this macOS (e.g. `periodic` is gone from recent versions).
    public static func available(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [MaintenanceTask] {
        all.filter { $0.executables.allSatisfy(fileExists) }
    }

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "free-ram", title: "Free up RAM",
                        details: "Flushes the disk cache in memory (purge) so apps get more free RAM.",
                        symbol: "memorychip", commands: ["/usr/sbin/purge"], needsAdmin: true, recommendedEveryDays: 1),
        MaintenanceTask(id: "flush-dns", title: "Flush DNS cache",
                        details: "Helps when websites do not open or open an old address.",
                        symbol: "network", commands: ["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"],
                        needsAdmin: true, recommendedEveryDays: 30),
        MaintenanceTask(id: "reindex-spotlight", title: "Reindex Spotlight",
                        details: "Rebuilds the search index when Spotlight misses files or is slow.",
                        symbol: "magnifyingglass", commands: ["/usr/bin/mdutil -E /"], needsAdmin: true, recommendedEveryDays: 90),
        MaintenanceTask(id: "rebuild-launch-services", title: "Rebuild Launch Services database",
                        details: "Removes duplicates from the Open With menu and fixes file associations.",
                        symbol: "square.stack.3d.up",
                        commands: ["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -f -apps system,local,user"],
                        needsAdmin: false, recommendedEveryDays: 90),
        MaintenanceTask(id: "maintenance-scripts", title: "Run maintenance scripts",
                        details: "macOS daily, weekly and monthly scripts: log rotation, temporary file cleanup.",
                        symbol: "gearshape.2", commands: ["/usr/sbin/periodic daily weekly monthly"], needsAdmin: true,
                        recommendedEveryDays: 30),
        MaintenanceTask(id: "thin-snapshots", title: "Thin Time Machine snapshots",
                        details: "Deletes local Time Machine snapshots. Frees space, but you can no longer roll back to them.",
                        symbol: "clock.arrow.circlepath", commands: ["/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"],
                        needsAdmin: true, recommendedEveryDays: 30),
        MaintenanceTask(id: "quicklook-cache", title: "Reset Quick Look cache",
                        details: "Fixes stale or blank thumbnails in Finder.",
                        symbol: "eye", commands: ["/usr/bin/qlmanage -r cache", "/usr/bin/qlmanage -r"],
                        needsAdmin: false, recommendedEveryDays: 90, automatic: true),
        MaintenanceTask(id: "verify-disk", title: "Verify startup disk",
                        details: "Checks the file system for errors. Changes nothing, but takes a few minutes and the Mac may stutter meanwhile.",
                        symbol: "internaldrive", commands: ["/usr/sbin/diskutil verifyVolume /"], needsAdmin: false,
                        recommendedEveryDays: 90),
        MaintenanceTask(id: "font-cache", title: "Clear font cache",
                        details: "Helps when fonts display incorrectly. Restart the Mac afterwards.",
                        symbol: "textformat", commands: ["/usr/bin/atsutil databases -removeUser"], needsAdmin: false,
                        recommendedEveryDays: 180),
    ]
}

public struct MaintenanceRunner: Sendable {
    public let runner: CommandRunning

    public init(runner: CommandRunning = ProcessRunner()) { self.runner = runner }

    /// Admin tasks are joined into one password prompt; the rest run one by one.
    /// Every task gets its own result, also inside the shared admin prompt.
    public func run(_ tasks: [MaintenanceTask]) -> [String: CommandResult] {
        var results: [String: CommandResult] = [:]
        let admin = tasks.filter(\.needsAdmin)
        if !admin.isEmpty {
            let r = runner.runAsAdmin(Self.adminScript(admin))
            let statuses = Self.parseAdminStatuses(r.output)
            for t in admin {
                if let code = statuses[t.id] {
                    results[t.id] = CommandResult(status: code, error: code == 0 ? "" : "Command exited with code \(code)")
                } else {
                    // No marker: the prompt was cancelled or the script never got that far.
                    results[t.id] = r.ok ? CommandResult(status: -1, error: "Did not run") : r
                }
            }
        }
        for t in tasks where !t.needsAdmin {
            var last = CommandResult(status: 0)
            for c in t.commands {
                let parts = c.split(separator: " ").map(String.init)
                last = runner.run(parts[0], Array(parts.dropFirst()))
                if !last.ok { break }
            }
            results[t.id] = last
        }
        return results
    }

    static let marker = "MYOPENCLEANER-STATUS"

    /// One shell line: each task's commands chained with `&&`, followed by a marker carrying its exit code.
    static func adminScript(_ tasks: [MaintenanceTask]) -> String {
        tasks.map { "( \($0.commands.joined(separator: " && ")) ) >/dev/null 2>&1; echo \(marker):\($0.id):$?" }
            .joined(separator: "; ")
    }

    static func parseAdminStatuses(_ output: String) -> [String: Int32] {
        var out: [String: Int32] = [:]
        // `do shell script` returns lines separated by \r.
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: ":")
            if parts.count == 3, parts[0] == marker, let code = Int32(parts[2]) { out[String(parts[1])] = code }
        }
        return out
    }

    /// Tasks not run within their recommended interval. `lastRun` maps task id → date.
    public static func due(lastRun: [String: Date], now: Date, among tasks: [MaintenanceTask] = MaintenanceTask.all) -> [MaintenanceTask] {
        tasks.filter { t in
            guard let d = lastRun[t.id] else { return true }
            return now.timeIntervalSince(d) >= Double(t.recommendedEveryDays) * 86_400
        }
    }
}
