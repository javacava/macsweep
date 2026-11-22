import Foundation

/// Every tool and app MyOpenCleaner knows, built from the scanners' own rules, so the list on the
/// website (docs/tools) can never promise more than the app does. A test keeps the page in step.
public enum SupportedTools {
    public enum Area: String, CaseIterable, Codable, Sendable {
        case ai, developer, projects, apps, macOS

        public var title: String {
            switch self {
            case .ai: "AI tools and models"
            case .developer: "Developer tools"
            case .projects: "Inside your projects"
            case .apps: "Apps and browsers"
            case .macOS: "macOS"
            }
        }
    }

    public struct Entry: Equatable, Codable, Sendable {
        public let what: String
        public let safety: Safety
    }

    public struct Tool: Equatable, Codable, Sendable {
        public let name: String
        public let area: Area
        public var entries: [Entry]
    }

    public static var catalog: [Tool] {
        var tools: [Tool] = []
        func add(_ name: String, _ area: Area, _ what: String, _ safety: Safety) {
            let entry = Entry(what: what, safety: safety)
            if let i = tools.firstIndex(where: { $0.name == name && $0.area == area }) {
                if !tools[i].entries.contains(entry) { tools[i].entries.append(entry) }
            } else {
                tools.append(Tool(name: name, area: area, entries: [entry]))
            }
        }

        for rule in DevFolderScanner.rules {
            let area: Area = [.aiTools, .aiModels].contains(rule.group) ? .ai : .developer
            add(rule.tool, area, Self.plainWhat(rule.title, tool: rule.tool), rule.safety ?? rule.group.safety)
        }
        for folder in AIModelScanner.folders { add(folder.app, .ai, "Downloaded models, one by one", .review) }
        add("Ollama", .ai, "Downloaded models, one by one (layers shared with other models stay)", .review)
        add("Hugging Face", .ai, "Downloaded models and datasets, one by one", .review)
        add("Claude Code", .ai, "Older versions (the one in use and the newest are kept)", .safe)
        add("Xcode", .developer, "Simulators", .review)
        add("Xcode", .developer, "Simulator runtimes", .safe)
        add("Xcode", .developer, "Metal toolchain", .safe)
        add("Android Studio", .developer, "Virtual devices", .review)
        add("Android Studio", .developer, "System images", .safe)
        add("Java", .developer, "Heap dumps (.hprof)", .safe)
        add("Bazel", .developer, "Output base", .safe)
        add("Docker", .developer, "Build cache, unused images, stopped containers, unused volumes (with docker's own commands)", .review)
        for manager in ToolVersionScanner.managers {
            add(manager, .developer, "Installed language versions (the default is kept)", .review)
        }
        for disk in VirtualMachineDisks.disks { add(disk.tool, .developer, "Virtual machine disk (shown, never removed)", .kept) }
        add("Lima", .developer, "Virtual machine disks (shown, never removed)", .kept)
        for kind in BuildArtifactFinder.kinds {
            add(kind.title, .projects, kind.folder, .safe)
        }
        for rule in JunkRules.all {
            let safety = rule.safety ?? rule.category.safety
            if let tool = rule.tool {
                let area: Area = rule.category == .appCaches || rule.category == .browserCache || rule.category == .mailAttachments
                    ? .apps : .developer
                add(tool, area, rule.category == .appCaches ? "Chromium caches" : rule.category.title, safety)
            } else {
                add(rule.category.title, .macOS, Self.plainPath(rule.path), safety)
            }
        }
        return tools.sorted { ($0.area.rawValue, $0.name.lowercased()) < ($1.area.rawValue, $1.name.lowercased()) }
    }

    /// "VS Code old versions data" under VS Code reads better as "old versions data".
    static func plainWhat(_ title: String, tool: String) -> String {
        guard title.hasPrefix(tool + " "), title.count > tool.count + 1 else { return title }
        let rest = title.dropFirst(tool.count + 1)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    static func plainPath(_ path: String) -> String { path }

    // MARK: Output

    public static func json(_ tools: [Tool] = catalog) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(tools)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The part of docs/tools/index.html between the `tools:start` and `tools:end` markers.
    public static func htmlFragment(_ tools: [Tool] = catalog) -> String {
        let total = tools.reduce(0) { $0 + $1.entries.count }
        var out = "<p class=\"tools-count\">\(tools.count) tools and places · \(total) kinds of files</p>\n"
        for area in Area.allCases {
            let inArea = tools.filter { $0.area == area }
            guard !inArea.isEmpty else { continue }
            out += "<section class=\"tool-area\" id=\"\(area.rawValue)\">\n<h2>\(escape(area.title)) <span>\(inArea.count)</span></h2>\n<ul class=\"tool-list\">\n"
            for tool in inArea {
                out += "<li><strong>\(escape(tool.name))</strong><ul>"
                for e in tool.entries {
                    out += "<li><span class=\"mark \(e.safety.rawValue)\">\(escape(e.safety.title))</span>\(escape(e.what))</li>"
                }
                out += "</ul></li>\n"
            }
            out += "</ul>\n</section>\n"
        }
        return out
    }
}
