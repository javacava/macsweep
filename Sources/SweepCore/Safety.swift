import Foundation

/// How much thought an item needs before it goes. Every row on the cleanup pages shows one.
public enum Safety: String, CaseIterable, Codable, Sendable, Comparable {
    /// Nothing of yours: the tool rebuilds it, downloads it again, or never needed it (caches, logs, build files).
    case safe
    /// Look before removing: it may hold your own work, settings or history, or it cannot be brought back as it was.
    case review
    /// Shown so you know where the space went, never removed by MyOpenCleaner (the version in use, a VM disk…).
    case kept

    public var title: String {
        switch self {
        case .safe: "Safe to remove"
        case .review: "Check first"
        case .kept: "Kept"
        }
    }

    /// One line for the legend and tooltips.
    public var explanation: String {
        switch self {
        case .safe: "Rebuilt or downloaded again when needed, or never needed at all."
        case .review: "May hold your own work or history, or cannot be brought back as it was. Never selected for you."
        case .kept: "Shown so you know where the space went. MyOpenCleaner does not remove it; the reason is next to it."
        }
    }

    public var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .review: "hand.raised"
        case .kept: "lock"
        }
    }

    public static func < (a: Safety, b: Safety) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public extension DevItem.Group {
    /// The safety of an item in this group unless the item says otherwise.
    var safety: Safety {
        switch self {
        case .runtimes, .firmware, .xcode, .packageCaches, .ideCaches, .oldVersions, .aiTools, .heapDumps, .builds:
            .safe
        case .simulators, .android, .aiModels, .toolVersions, .virtualMachines:
            .review
        }
    }
}

public extension JunkCategory {
    /// The safety of an item in this category unless its rule says otherwise.
    var safety: Safety {
        switch self {
        case .userCache, .systemCache, .userLogs, .systemLogs, .browserCache, .xcode, .devTools, .containerCaches,
             .brokenDownloads, .appCaches:
            .safe
        // Mail Downloads holds copies made when you opened an attachment; the original stays in the message.
        case .mailAttachments: .safe
        // You put these in the Trash yourself.
        case .trash: .safe
        case .iosBackups, .installers: .review
        }
    }
}
