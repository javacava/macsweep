import Foundation

/// Which running programs have files open inside the paths about to be removed. Removing files a
/// program is using can make it misbehave, or the files come straight back.
public struct OpenFileHolder: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let path: String
}

public enum OpenFiles {
    /// Parses `lsof -F pcn` output: `p<pid>`, `c<command>`, then `n<path>` lines for that process.
    public static func parse(_ output: String) -> [OpenFileHolder] {
        var out: [OpenFileHolder] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0; command = ""
            case "c": command = value
            case "n" where value.hasPrefix("/"): out.append(OpenFileHolder(pid: pid, command: command, path: value))
            default: break
            }
        }
        return out
    }

    /// For each target that something has open (the target itself or anything inside it),
    /// the names of the programs holding it. One `lsof` run covers all targets.
    public static func holders(of targets: [URL], runner: CommandRunning = ProcessRunner(),
                               excludingPID: Int32 = getpid()) -> [URL: [String]] {
        guard !targets.isEmpty else { return [:] }
        let result = runner.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F", "pcn"])
        let open = parse(result.output).filter { $0.pid != excludingPID }
        var map: [URL: Set<String>] = [:]
        // lsof prints /private/var/…, Foundation often /var/…: compare one spelling.
        let paths = targets.map { ($0, SafetyGuard.canonical($0.resolvingSymlinksInPath().standardizedFileURL.path)) }
        for holder in open {
            let held = SafetyGuard.canonical(holder.path)
            for (url, p) in paths where held == p || held.hasPrefix(p + "/") {
                map[url, default: []].insert(holder.command)
            }
        }
        return map.mapValues { $0.sorted() }
    }

    /// "Open in Safari and Xcode." or nil when nothing is open.
    public static func warning(for holders: [URL: [String]]) -> String? {
        let apps = Array(Set(holders.values.flatMap { $0 })).sorted()
        guard !apps.isEmpty else { return nil }
        let list = apps.count <= 3 ? apps.joined(separator: ", ") : apps.prefix(3).joined(separator: ", ") + " and \(apps.count - 3) more"
        let n = holders.count
        return "\(n) of the selected items \(n == 1 ? "is" : "are") open in \(list). Quit \(apps.count == 1 ? "it" : "them") first, or files may come back and the app may misbehave."
    }
}
