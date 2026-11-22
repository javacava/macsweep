import SwiftUI
import SweepCore

enum Module: String, CaseIterable, Identifiable, Hashable {
    case quickScan, junk, developer, cloud, malware, privacy, shredder, maintenance, launchItems
    case uninstaller, updater, leftovers, largeOld, duplicates, similar, spaceMap, monitor, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickScan: "Quick Scan"
        case .junk: "System Junk"
        case .developer: "Developer"
        case .cloud: "Cloud Files"
        case .malware: "Malware"
        case .privacy: "Privacy"
        case .shredder: "Shredder"
        case .maintenance: "Maintenance"
        case .launchItems: "Launch Items"
        case .uninstaller: "Uninstaller"
        case .updater: "Updater"
        case .leftovers: "App Leftovers"
        case .largeOld: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .similar: "Similar Media"
        case .spaceMap: "Space Map"
        case .monitor: "Mac Health"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .quickScan: "sparkles"
        case .junk: "trash.circle"
        case .developer: "hammer"
        case .cloud: "icloud"
        case .malware: "shield.lefthalf.filled"
        case .privacy: "hand.raised"
        case .shredder: "scissors"
        case .maintenance: "wrench.and.screwdriver"
        case .launchItems: "power"
        case .uninstaller: "xmark.app"
        case .updater: "arrow.down.app"
        case .leftovers: "puzzlepiece.extension"
        case .largeOld: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .similar: "photo.on.rectangle"
        case .spaceMap: "circle.hexagongrid"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .battery: "battery.75percent"
        }
    }

    var tint: Color {
        switch self {
        case .quickScan: .purple
        case .junk, .developer, .cloud: .green
        case .malware, .privacy, .shredder: .red
        case .maintenance, .launchItems: .orange
        case .uninstaller, .updater, .leftovers: .blue
        case .largeOld, .duplicates, .similar, .spaceMap: .teal
        case .monitor: .pink
        case .battery: .green
        }
    }

    static let sections: [(String, [Module])] = [
        ("", [.quickScan]),
        ("Cleanup", [.junk, .developer, .cloud]),
        ("Protection", [.malware, .privacy, .shredder]),
        ("Performance", [.maintenance, .launchItems, .monitor, .battery]),
        ("Applications", [.uninstaller, .updater, .leftovers]),
        ("Clutter", [.largeOld, .duplicates, .similar, .spaceMap]),
    ]
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let baseEnv: SweepEnvironment
    let activity: ActivityLog
    /// Every clean, with where its items went in the Trash, for undo.
    let history: CleanHistory
    /// The clean that just finished, offered for undo in a toast.
    @Published var lastClean: CleanHistoryEntry?
    @Published var toast: String?
    /// Every external tool the pages call goes through this; the demo Mac swaps in canned answers.
    let runner: CommandRunning
    /// Pages scan as soon as they appear (screenshot mode only).
    let autoScan: Bool

    private init() {
        if let demo = Demo.active {
            baseEnv = demo.env
            activity = ActivityLog(fileURL: demo.activityURL)
            history = CleanHistory(fileURL: demo.base.appendingPathComponent("state/clean-history.json"))
            runner = demo.runner
            autoScan = true
        } else {
            baseEnv = .live
            activity = ActivityLog(fileURL: ActivityLog.defaultURL)
            history = CleanHistory(fileURL: CleanHistory.defaultURL)
            runner = ProcessRunner()
            autoScan = false
        }
    }

    /// The environment for a scan, with the user's current exclusions.
    var env: SweepEnvironment {
        var e = baseEnv
        if Demo.active == nil { e.exclusions = Self.exclusions.map { URL(fileURLWithPath: $0) } }
        return e
    }

    // MARK: Exclusions (Settings)

    nonisolated static let exclusionsKey = "exclusions"

    nonisolated static var exclusions: [String] {
        get { UserDefaults.standard.stringArray(forKey: exclusionsKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: exclusionsKey) }
    }

    /// Adds a path; it is never offered for removal again.
    func exclude(_ url: URL) {
        Self.exclusions.append(url.resolvingSymlinksInPath().standardizedFileURL.path)
        exclusionsVersion += 1
    }

    @Published var exclusionsVersion = 0

    func docker() -> DockerCleaner {
        Demo.active == nil ? DockerCleaner(runner: runner) : DockerCleaner(runner: runner, binary: "/usr/local/bin/docker")
    }
    @Published var selection: Module? = .quickScan
    @Published var activityVersion = 0

    // Settings live in UserDefaults and are bound with @AppStorage in views. Keeping @AppStorage out of this
    // ObservableObject avoids a re-render loop with MenuBarExtra(isInserted:).
    nonisolated static let removalModeKey = "removalMode", showMenuBarKey = "showMenuBar"

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [removalModeKey: RemovalMode.trash.rawValue, showMenuBarKey: true])
    }

    var removalMode: RemovalMode {
        RemovalMode(rawValue: UserDefaults.standard.string(forKey: Self.removalModeKey) ?? "") ?? .trash
    }

    var showMenuBar: Bool { UserDefaults.standard.bool(forKey: Self.showMenuBarKey) }

    func cleaner() -> Cleaner { Cleaner(env: env, mode: removalMode) }

    func record(_ module: Module, _ report: CleanReport) {
        guard !report.removed.isEmpty else { return }
        activity.record(module: module.title, freed: report.freedBytes, items: report.removed.count)
        if let entry = history.record(module: module.title, report: report), !entry.trashed.isEmpty {
            lastClean = entry
            toast = nil
        }
        activityVersion += 1
    }

    /// Puts a clean's Trash items back where they were.
    func undo(_ entry: CleanHistoryEntry) {
        let history = history
        Task {
            let r = await AppState.background { history.restore(entry.id) }
            lastClean = nil
            toast = r.failed.isEmpty
                ? "Restored \(r.restored.count) items."
                : "Restored \(r.restored.count) items; \(r.failed.count) could not be restored (\(r.failed[0].reason))."
            activityVersion += 1
        }
    }

    /// A warning when programs have some of these files open, or nil.
    func inUseWarning(_ urls: [URL]) async -> String? {
        guard !urls.isEmpty else { return nil }
        let runner = runner
        return await AppState.background { OpenFiles.warning(for: OpenFiles.holders(of: urls, runner: runner)) }
    }

    func display(_ url: URL) -> String { env.displayPath(url) }

    /// Runs blocking work off the main thread.
    nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
