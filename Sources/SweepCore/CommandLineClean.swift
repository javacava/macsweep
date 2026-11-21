import Foundation

/// `MyOpenCleaner --clean`: cleans system junk from the terminal. Without `--yes` it only prints the plan
/// (a dry run). With `--yes` it moves the planned items to the Trash; nothing is ever deleted outright
/// except what already sits in the Trash.
public enum CommandLineClean {
    public struct Options: Equatable, Sendable {
        public var categories: Set<JunkCategory>?
        public var includeUnselected = false
        public var execute = false
        public var json = false
    }

    public static let usage = """
    Usage: MyOpenCleaner --clean [--category NAME[,NAME…]] [--all] [--yes] [--json]

      Without --yes nothing is removed: the command prints what it would clean (a dry run).
      --yes            move the planned items to the Trash
      --category       limit to some categories: \(JunkCategory.allCases.map(\.rawValue).joined(separator: ", "))
      --all            also include items that are not selected by default (iOS backups, installers…)
      --json           print the plan or the result as JSON
    """

    /// Parses the arguments that follow `--clean`.
    public static func parse(_ args: [String]) -> Result<Options, CleanError> {
        var o = Options()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--yes": o.execute = true
            case "--dry-run": o.execute = false
            case "--json": o.json = true
            case "--all": o.includeUnselected = true
            case "--category":
                guard i + 1 < args.count else { return .failure(.message("--category needs a value")) }
                var set = Set<JunkCategory>()
                for name in args[i + 1].split(separator: ",") {
                    guard let c = JunkCategory(rawValue: String(name)) else {
                        return .failure(.message("Unknown category \"\(name)\""))
                    }
                    set.insert(c)
                }
                o.categories = set
                i += 1
            case "--help", "-h": return .failure(.help)
            default: return .failure(.message("Unknown option \"\(args[i])\""))
            }
            i += 1
        }
        return .success(o)
    }

    public enum CleanError: Error, Equatable {
        case help
        case message(String)
    }

    /// Runs the clean and returns what to print and the exit code.
    public static func run(_ o: Options, env: SweepEnvironment, remover: FileRemoving = SystemFileRemover()) -> (output: String, status: Int32) {
        let scan = JunkScanner(env: env).scan(categories: o.categories ?? Set(JunkCategory.allCases))
        let items = scan.items.filter { o.includeUnselected || $0.selectedByDefault }
        let report = o.execute ? Cleaner(env: env, remover: remover, mode: .trash).remove(items) : nil
        let text = o.json ? json(items, report, env: env) : plain(items, report, env: env)
        return (text, (report?.failed.isEmpty ?? true) ? 0 : 1)
    }

    static func plain(_ items: [JunkItem], _ report: CleanReport?, env: SweepEnvironment) -> String {
        var lines: [String] = []
        let total = items.reduce(0) { $0 + $1.size }
        for c in JunkCategory.allCases {
            let group = items.filter { $0.category == c }
            guard !group.isEmpty else { continue }
            lines.append("\(c.title): \(FileSize.format(group.reduce(0) { $0 + $1.size })) (\(group.count))")
            for item in group.prefix(10) { lines.append("    \(FileSize.format(item.size))\t\(env.displayPath(item.url))") }
            if group.count > 10 { lines.append("    …and \(group.count - 10) more") }
        }
        if let report {
            lines.append("Moved to the Trash: \(report.removed.count) items, \(FileSize.format(report.freedBytes)).")
            for f in report.failed { lines.append("Failed: \(env.displayPath(f.url)): \(f.reason)") }
        } else {
            lines.append(items.isEmpty ? "Nothing to clean." : "Dry run: \(FileSize.format(total)) in \(items.count) items. Add --yes to move them to the Trash.")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ items: [JunkItem], _ report: CleanReport?, env: SweepEnvironment) -> String {
        var root: [String: Any] = [
            "dryRun": report == nil,
            "totalBytes": items.reduce(0) { $0 + $1.size },
            "items": items.map { ["path": $0.url.path, "category": $0.category.rawValue, "bytes": $0.size] as [String: Any] },
        ]
        if let report {
            root["removed"] = report.removed.map(\.path)
            root["freedBytes"] = report.freedBytes
            root["failed"] = report.failed.map { ["path": $0.url.path, "reason": $0.reason] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
