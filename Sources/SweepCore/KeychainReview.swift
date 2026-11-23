import Foundation

/// A saved password in the login keychain, by name only. The secret itself is never read.
public struct KeychainEntry: Identifiable, Hashable, Sendable {
    public var id: String { service + "|" + account }
    public let service: String
    public let account: String
    public let label: String
    public let modified: Date?

    public init(service: String, account: String, label: String = "", modified: Date? = nil) {
        self.service = service; self.account = account; self.label = label; self.modified = modified
    }
}

/// Finds keychain entries that belong to apps which are no longer installed, so the user can review them.
/// Read-only: it runs `security dump-keychain` without `-d`, which lists names and dates but no secrets,
/// and it never deletes anything. Removing an entry is left to Keychain Access.
public struct KeychainReview: Sendable {
    public let runner: CommandRunning
    static let security = "/usr/bin/security"

    public init(runner: CommandRunning = ProcessRunner()) { self.runner = runner }

    /// Entries whose service is the bundle ID of an app that is not installed.
    public func staleEntries(installed: Set<String>) -> [KeychainEntry] {
        let r = runner.run(Self.security, ["dump-keychain"])
        guard r.ok else { return [] }
        return Self.stale(Self.parse(r.output), installed: installed)
    }

    // MARK: Parsing

    /// Generic passwords ("genp") from `security dump-keychain`. Internet passwords and keys are left out.
    public static func parse(_ output: String) -> [KeychainEntry] {
        var out: [KeychainEntry] = []
        var inPassword = false
        var fields: [String: String] = [:]
        func flush() {
            if inPassword, let service = fields["svce"], !service.isEmpty {
                out.append(KeychainEntry(service: service, account: fields["acct"] ?? "",
                                         label: fields["0x00000007"] ?? "", modified: fields["mdat"].flatMap(date)))
            }
            fields = [:]
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("keychain:") { flush(); inPassword = false; continue }
            if line.hasPrefix("class:") { flush(); inPassword = line == #"class: "genp""#; continue }
            guard inPassword, let (key, value) = attribute(line) else { continue }
            fields[key] = value
        }
        flush()
        return out
    }

    /// `"svce"<blob>="name"`, `"svce"<blob>=0x6E616D65  "name"` or `0x00000007 <blob>=<NULL>`.
    static func attribute(_ line: String) -> (String, String)? {
        guard let lt = line.firstIndex(of: "<"), let eq = line[lt...].firstIndex(of: "=") else { return nil }
        let key = line[..<lt].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value == "<NULL>" { return (key, "") }
        if value.hasPrefix("0x") {
            // Hex is exact; the quoted copy after it escapes non-ASCII bytes.
            let hex = value.dropFirst(2).prefix { $0.isHexDigit }
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
                if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
                i = j
            }
            while bytes.last == 0 { bytes.removeLast() }
            return (key, String(decoding: bytes, as: UTF8.self))
        }
        if value.hasPrefix("\""), value.count >= 2, value.hasSuffix("\"") {
            return (key, String(value.dropFirst().dropLast()))
        }
        return (key, value)
    }

    /// "20231001120000Z" (sometimes with a trailing NUL).
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return f.date(from: s.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")))
    }

    // MARK: Matching

    /// A reverse-DNS name like "com.example.App": three or more parts, no spaces.
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, s.count <= 155 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Entries named after an app that is not installed. Apple's own entries never count, and neither does
    /// anything related to an installed app (its helpers "com.x.app.helper", or its team prefix "com.x.app").
    public static func stale(_ entries: [KeychainEntry], installed: Set<String>) -> [KeychainEntry] {
        let ids = installed.map { $0.lowercased() }
        return entries.filter { e in
            let s = e.service.lowercased()
            guard looksLikeBundleID(e.service), !s.hasPrefix("com.apple.") else { return false }
            return !ids.contains { id in s == id || s.hasPrefix(id + ".") || id.hasPrefix(s + ".") }
        }
        .reduce(into: [KeychainEntry]()) { acc, e in if !acc.contains(where: { $0.id == e.id }) { acc.append(e) } }
        .sorted { $0.service.lowercased() < $1.service.lowercased() }
    }
}
