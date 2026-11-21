import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    public var ok: Bool { status == 0 }

    public init(status: Int32, output: String = "", error: String = "") {
        self.status = status; self.output = output; self.error = error
    }
}

/// Runs external tools. Tests substitute a recorder.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

public extension CommandRunning {
    /// Runs a shell command with the admin password prompt from macOS (via AppleScript).
    func runAsAdmin(_ shellCommand: String) -> CommandResult {
        run("/usr/bin/osascript", ["-e", AdminScript.make(shellCommand)])
    }
}

public enum AdminScript {
    /// `do shell script "..." with administrator privileges`, with the command escaped for AppleScript.
    public static func make(_ shellCommand: String) -> String {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Single-quotes an argument for /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return CommandResult(status: -1, error: error.localizedDescription) }
        // Drain both pipes at once: reading them one after the other deadlocks when the child fills the second.
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errBox.data = err.fileHandleForReading.readDataToEndOfFile() }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus,
                             output: String(decoding: o, as: UTF8.self), error: String(decoding: errBox.data, as: UTF8.self))
    }
}
