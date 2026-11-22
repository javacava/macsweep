import Foundation
import ImageIO
import Testing

/// The disk image layout lives in two files: make_dmg.sh places the icons, make_dmg_background.swift
/// draws the arrow and label plates around them. These tests keep the two in step.
@Suite struct ReleasePackagingTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// First number after `name` followed by `=` or `: CGFloat =`.
    static func number(_ name: String, in text: String) -> Int? {
        let pattern = "\\b\(name)(?::\\s*CGFloat)?\\s*=\\s*(\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    @Test func iconPositionsMatchTheBackground() throws {
        let script = try Self.read("scripts/make_dmg.sh")
        let background = try Self.read("scripts/make_dmg_background.swift")
        for (sh, swift) in [("APP_X", "appX"), ("APPS_X", "appsX"), ("ICON_Y", "iconY"), ("WIN_W", "W"), ("WIN_H", "H")] {
            let a = Self.number(sh, in: script), b = Self.number(swift, in: background)
            #expect(a != nil && a == b, "\(sh) in make_dmg.sh (\(String(describing: a))) differs from \(swift) in the background (\(String(describing: b)))")
        }
    }

    @Test func backgroundImageIsCommittedAtRetinaSize() throws {
        let url = Self.repo.appendingPathComponent("Resources/dmg-background.tiff")
        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        // tiffutil -cathidpicheck stores the 1x and the 2x image in one file.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        let widths = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width }
        #expect(Set(widths) == [640, 1280])
    }

    @Test func releaseScriptsAreValidShell() throws {
        for script in ["build.sh", "scripts/make_dmg.sh", "scripts/release_notes.sh"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", Self.repo.appendingPathComponent(script).path]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(script) has a syntax error")
            #expect(FileManager.default.isExecutableFile(atPath: Self.repo.appendingPathComponent(script).path), "\(script) is not executable")
        }
    }
}
