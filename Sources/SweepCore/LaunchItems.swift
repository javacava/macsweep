import Foundation

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        case userAgent, systemAgent, systemDaemon

        public var title: String {
            switch self {
            case .userAgent: "User agent"
            case .systemAgent: "System agent"
            case .systemDaemon: "System daemon"
            }
        }

        public var folder: String {
            switch self {
            case .userAgent: "~/Library/LaunchAgents"
            case .systemAgent: "/Library/LaunchAgents"
            case .systemDaemon: "/Library/LaunchDaemons"
            }
        }
    }

    public var id: String { plist.path }
    public let plist: URL
    public let label: String
    public let program: String?
    public let scope: Scope
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let disabledInPlist: Bool

    /// Path of the program the item launches, if it says.
    public var programURL: URL? { program.map { URL(fileURLWithPath: $0) } }

    public init?(plist url: URL, scope: Scope) {
        guard let data = try? Data(contentsOf: url),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = d["Label"] as? String else { return nil }
        self.plist = url
        self.label = label
        self.scope = scope
        self.program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        self.runAtLoad = d["RunAtLoad"] as? Bool ?? false
        if let b = d["KeepAlive"] as? Bool { keepAlive = b } else { keepAlive = d["KeepAlive"] is [String: Any] }
        self.disabledInPlist = d["Disabled"] as? Bool ?? false
    }
}

public struct LaunchItemsManager: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning
    public let uid: uid_t

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(), uid: uid_t = getuid()) {
        self.env = env; self.runner = runner; self.uid = uid
    }

    public func items() -> [LaunchItem] {
        LaunchItem.Scope.allCases.flatMap { scope in
            FileManager.default.children(of: env.resolve(scope.folder))
                .filter { $0.pathExtension == "plist" }
                .compactMap { LaunchItem(plist: $0, scope: scope) }
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func domain(_ scope: LaunchItem.Scope) -> String { scope == .systemDaemon ? "system" : "gui/\(uid)" }

    /// Labels launchd has been told to keep off.
    public func disabledLabels() -> Set<String> {
        var labels = Self.parseDisabled(runner.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).output)
        labels.formUnion(Self.parseDisabled(runner.run("/bin/launchctl", ["print-disabled", "system"]).output))
        return labels
    }

    /// Parses `launchctl print-disabled` lines like `"com.foo.bar" => disabled` (or `=> true`).
    public static func parseDisabled(_ output: String) -> Set<String> {
        var out = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            out.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return out
    }

    /// Stops the item and keeps it from starting again. System items ask for the admin password.
    @discardableResult
    public func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> CommandResult {
        let target = "\(domain(item.scope))/\(item.label)"
        let cmds: [[String]] = enabled
            ? [["enable", target], ["bootstrap", domain(item.scope), item.plist.path]]
            : [["bootout", target], ["disable", target]]
        if item.scope == .userAgent {
            let results = cmds.map { runner.run("/bin/launchctl", $0) }
            // enable/disable is what sticks; bootout/bootstrap fail harmlessly when already (un)loaded.
            return enabled ? results[0] : results[1]
        }
        let line = cmds.map { (["/bin/launchctl"] + $0).map(AdminScript.shellQuote).joined(separator: " ") }
            .joined(separator: "; ")
        return runner.runAsAdmin(line)
    }
}
