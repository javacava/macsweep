import Foundation

/// Read-only check of the Mac's built-in protections. It never changes a setting; it only reports
/// and points to the place in System Settings where the user can change it.
public struct SecurityCheck: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case good, warning, unknown }

    public let id: String
    public let title: String
    public let state: State
    public let detail: String
    /// What to do when the state is not good.
    public let advice: String?
    /// A System Settings deep link, when there is one.
    public let settingsURL: String?
}

public struct SecurityAudit: Sendable {
    public let env: SweepEnvironment
    public let runner: CommandRunning

    public init(env: SweepEnvironment, runner: CommandRunning = ProcessRunner()) {
        self.env = env; self.runner = runner
    }

    public func run() -> [SecurityCheck] {
        [fileVault(), sip(), gatekeeper(), firewall(), xprotect(), updates()]
    }

    // MARK: - Checks

    func fileVault() -> SecurityCheck {
        let on = Self.parseFileVault(runner.run("/usr/bin/fdesetup", ["status"]).output)
        return SecurityCheck(id: "filevault", title: "FileVault disk encryption",
                             state: on.map { $0 ? .good : .warning } ?? .unknown,
                             detail: on.map { $0 ? "On" : "Off" } ?? "Could not read the status",
                             advice: on == false ? "Turn it on so a lost or stolen Mac does not expose your files." : nil,
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?FileVault")
    }

    func sip() -> SecurityCheck {
        let on = Self.parseSIP(runner.run("/usr/bin/csrutil", ["status"]).output)
        return SecurityCheck(id: "sip", title: "System Integrity Protection",
                             state: on.map { $0 ? .good : .warning } ?? .unknown,
                             detail: on.map { $0 ? "Enabled" : "Disabled" } ?? "Could not read the status",
                             advice: on == false ? "Re-enable it from macOS Recovery with `csrutil enable`, unless you turned it off on purpose." : nil,
                             settingsURL: nil)
    }

    func gatekeeper() -> SecurityCheck {
        let on = Self.parseGatekeeper(runner.run("/usr/sbin/spctl", ["--status"]).output)
        return SecurityCheck(id: "gatekeeper", title: "Gatekeeper",
                             state: on.map { $0 ? .good : .warning } ?? .unknown,
                             detail: on.map { $0 ? "Only signed apps are allowed" : "Apps from anywhere are allowed" } ?? "Could not read the status",
                             advice: on == false ? "Turn it back on with `sudo spctl --master-enable`." : nil,
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?General")
    }

    func firewall() -> SecurityCheck {
        let on = Self.parseFirewall(runner.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).output)
        return SecurityCheck(id: "firewall", title: "Firewall",
                             state: on.map { $0 ? .good : .warning } ?? .unknown,
                             detail: on.map { $0 ? "On" : "Off" } ?? "Could not read the status",
                             advice: on == false ? "Turn it on, especially on public Wi‑Fi." : nil,
                             settingsURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
    }

    func xprotect() -> SecurityCheck {
        var info = Self.parseXProtect(runner.run("/usr/bin/xprotect", ["version"]).output)
        if info == nil {
            // Older systems have no `xprotect` tool: read the bundle's version and date instead.
            let plist = env.resolve("/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
            if let data = try? Data(contentsOf: plist),
               let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let v = d["CFBundleShortVersionString"] as? String {
                info = (v, plist.modificationDate)
            }
        }
        guard let (version, date) = info else {
            return SecurityCheck(id: "xprotect", title: "XProtect malware definitions", state: .unknown,
                                 detail: "Could not read the version", advice: nil, settingsURL: nil)
        }
        let stale = date.map { env.now().timeIntervalSince($0) > 60 * 86_400 } ?? false
        let when = date.map { " · updated " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return SecurityCheck(id: "xprotect", title: "XProtect malware definitions", state: stale ? .warning : .good,
                             detail: "Version \(version)" + when,
                             advice: stale ? "Definitions are over two months old. Check that security updates install automatically." : nil,
                             settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    }

    func updates() -> SecurityCheck {
        let plist = env.resolve("/Library/Preferences/com.apple.SoftwareUpdate.plist")
        let d = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        guard let d else {
            return SecurityCheck(id: "updates", title: "Automatic security updates", state: .unknown,
                                 detail: "Could not read the settings", advice: nil,
                                 settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        }
        let on = Self.securityUpdatesOn(d)
        return SecurityCheck(id: "updates", title: "Automatic security updates", state: on ? .good : .warning,
                             detail: on ? "Security responses and system files install automatically" : "Not installed automatically",
                             advice: on ? nil : "Turn on \"Install Security Responses and system files\" in Software Update → Automatic Updates.",
                             settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    }

    // MARK: - Parsers

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off."
    public static func parseFileVault(_ s: String) -> Bool? {
        if s.contains("FileVault is On") { return true }
        if s.contains("FileVault is Off") { return false }
        return nil
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." (or "disabled", or a custom configuration).
    public static func parseSIP(_ s: String) -> Bool? {
        guard let r = s.range(of: "status:") else { return nil }
        let rest = s[r.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        if rest.hasPrefix("enabled") { return true }
        if rest.hasPrefix("disabled") || rest.hasPrefix("unknown (custom") { return false }
        return nil
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    public static func parseGatekeeper(_ s: String) -> Bool? {
        if s.contains("assessments enabled") { return true }
        if s.contains("assessments disabled") { return false }
        return nil
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)", "Firewall is blocking all…" or "disabled".
    public static func parseFirewall(_ s: String) -> Bool? {
        let l = s.lowercased()
        if l.contains("firewall is enabled") || l.contains("firewall is blocking") || l.contains("state = 1") || l.contains("state = 2") { return true }
        if l.contains("firewall is disabled") || l.contains("state = 0") { return false }
        return nil
    }

    /// `xprotect version`: "Version: 5377 Installed: 2026-11-21 13:00:53 +0000".
    public static func parseXProtect(_ s: String) -> (String, Date?)? {
        guard let vr = s.range(of: "Version:") else { return nil }
        let afterVersion = s[vr.upperBound...].trimmingCharacters(in: .whitespaces)
        let version = String(afterVersion.prefix { !$0.isWhitespace })
        guard !version.isEmpty else { return nil }
        var date: Date?
        if let ir = s.range(of: "Installed:") {
            let text = s[ir.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            date = f.date(from: String(text.prefix(25)))
        }
        return (version, date)
    }

    /// Both "security responses" (CriticalUpdateInstall) and "system data files" (ConfigDataInstall, which
    /// carries XProtect) must be on. macOS treats a missing key as on.
    public static func securityUpdatesOn(_ d: [String: Any]) -> Bool {
        func flag(_ k: String) -> Bool { (d[k] as? Bool) ?? ((d[k] as? NSNumber)?.boolValue ?? true) }
        return flag("CriticalUpdateInstall") && flag("ConfigDataInstall")
    }
}
