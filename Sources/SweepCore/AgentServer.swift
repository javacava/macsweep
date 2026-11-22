import Foundation

// MARK: - JSON for scripts and agents

/// Scan results as plain JSON objects, shared by `--scan --json`, `--dev-scan --json` and the MCP server.
public enum ScanJSON {
    /// `limit`: at most this many items per category or group (the biggest); nil lists all.
    public static func junk(_ r: JunkScanResult, env: SweepEnvironment, limit: Int? = nil) -> [String: Any] {
        var categories: [[String: Any]] = []
        for c in r.categories {
            let items = r.items(in: c)
            categories.append([
                "id": c.rawValue, "title": c.title, "bytes": r.size(of: c), "count": items.count,
                "items": items.prefix(limit ?? .max).map { i -> [String: Any] in
                    ["path": env.displayPath(i.url), "bytes": i.size, "safety": i.safety.rawValue,
                     "selectedByDefault": i.selectedByDefault]
                },
            ])
        }
        return ["totalBytes": r.totalSize, "unreadableFolders": r.unreadable.count, "categories": categories,
                "safety": safetyLegend]
    }

    public static func developer(_ items: [DevItem], env: SweepEnvironment, limit: Int? = nil) -> [String: Any] {
        var groups: [[String: Any]] = []
        for g in DevItem.Group.allCases {
            let rows = items.filter { $0.group == g }.sorted { $0.size > $1.size }
            guard !rows.isEmpty else { continue }
            groups.append([
                "id": g.rawValue, "title": g.title, "hint": g.hint, "count": rows.count,
                "removableBytes": rows.filter(\.isRemovable).reduce(0) { $0 + $1.size },
                "items": rows.prefix(limit ?? .max).map { i -> [String: Any] in
                    var o: [String: Any] = ["title": i.title, "detail": i.detail, "bytes": i.size, "safety": i.safety.rawValue,
                                            "selectedByDefault": i.selectedByDefault]
                    if let u = i.location { o["path"] = env.displayPath(u) }
                    if let d = i.lastUsed { o["lastUsed"] = ISO8601DateFormatter().string(from: d) }
                    return o
                },
            ])
        }
        let removable = items.filter(\.isRemovable)
        return ["removableBytes": removable.reduce(0) { $0 + $1.size },
                "safeBytes": removable.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size },
                "groups": groups, "safety": safetyLegend]
    }

    public static func status(memory: MemoryStats?, swap: SwapStats?, disk: DiskStats?) -> [String: Any] {
        var o: [String: Any] = [:]
        if let m = memory {
            o["memory"] = ["totalBytes": m.total, "usedBytes": m.used, "appBytes": m.appMemory, "wiredBytes": m.wired,
                           "compressedBytes": m.compressed, "pressure": m.pressure.rawValue]
        }
        if let s = swap, let m = memory {
            o["swap"] = ["totalBytes": s.total, "usedBytes": s.used, "advice": s.advice(physicalMemory: m.total)]
        }
        if let d = disk {
            o["disk"] = ["totalBytes": d.total, "availableBytes": d.available, "purgeableBytes": d.purgeable]
        }
        return o
    }

    static let safetyLegend: [String: String] = Dictionary(uniqueKeysWithValues: Safety.allCases.map { ($0.rawValue, $0.explanation) })

    public static func string(_ object: Any, pretty: Bool = true) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - MCP server

/// A Model Context Protocol server on stdin/stdout (`MyOpenCleaner --mcp`), so an AI agent such as Claude Code,
/// Claude Desktop, Codex or Cursor can read what MyOpenCleaner finds. It is read-only: no tool removes anything.
public struct MCPServer {
    public struct Tool {
        public let name: String
        public let description: String
        public let inputSchema: [String: Any]
        public let run: ([String: Any]) -> String
    }

    public let tools: [Tool]
    public let version: String
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public static let instructions = """
    MyOpenCleaner reports what takes space on this Mac and how safe each item is to remove: \
    "safe" (rebuilt or downloaded again), "review" (may hold the user's work; ask first) and "kept" (never removed). \
    The server is read-only and removes nothing. Suggest a cleanup and let the user do it in the MyOpenCleaner app, \
    or with `MyOpenCleaner --clean` for system junk. Never say files were removed.
    """

    public init(tools: [Tool], version: String) { self.tools = tools; self.version = version }

    /// The server with MyOpenCleaner's scanners.
    public static func standard(env: SweepEnvironment, runner: CommandRunning = ProcessRunner(), version: String) -> MCPServer {
        let empty: [String: Any] = ["type": "object", "properties": [String: Any]()]
        return MCPServer(tools: [
            Tool(name: "scan_junk",
                 description: "Scan system junk (caches, logs, browser and app caches, Trash, Mail downloads, iOS backups, old installers). Returns sizes per category and the biggest items, each with its safety. Removes nothing.",
                 inputSchema: ["type": "object", "properties": [
                    "categories": ["type": "array", "items": ["type": "string", "enum": JunkCategory.allCases.map(\.rawValue)],
                                   "description": "Limit the scan to these categories"],
                    "limit": ["type": "integer", "description": "Items listed per category, biggest first (default 15)"],
                 ] as [String: Any]]) { args in
                let cats = (args["categories"] as? [String])?.compactMap(JunkCategory.init(rawValue:))
                let r = JunkScanner(env: env).scan(categories: Set(cats?.isEmpty == false ? cats! : JunkCategory.allCases))
                return ScanJSON.string(ScanJSON.junk(r, env: env, limit: args["limit"] as? Int ?? 15))
            },
            Tool(name: "scan_developer",
                 description: "Scan developer and AI tool storage: Xcode, simulators and runtimes, package manager caches, editor caches, AI models (Ollama, LM Studio, Hugging Face…), language versions, VM disks; optionally build folders inside projects. Each item has its safety. Removes nothing.",
                 inputSchema: ["type": "object", "properties": [
                    "include_projects": ["type": "boolean", "description": "Also look for node_modules, .build, target… under the home folder (slower)"],
                    "limit": ["type": "integer", "description": "Items listed per group, biggest first (default 15)"],
                 ] as [String: Any]]) { args in
                var items = DevFolderScanner(env: env).scan() + SimulatorScanner(env: env, runner: runner).scan()
                if args["include_projects"] as? Bool == true { items += BuildArtifactFinder(env: env, runner: runner).find() }
                return ScanJSON.string(ScanJSON.developer(items, env: env, limit: args["limit"] as? Int ?? 15))
            },
            Tool(name: "mac_status",
                 description: "Memory use and pressure, swap, and free disk space right now.",
                 inputSchema: empty) { _ in
                ScanJSON.string(ScanJSON.status(memory: SystemMonitor.memory(), swap: SystemMonitor.swap(), disk: SystemMonitor.disk()))
            },
            Tool(name: "supported_tools",
                 description: "The apps, tools and macOS folders MyOpenCleaner knows, with what it looks for in each and how safe that is.",
                 inputSchema: empty) { _ in SupportedTools.json() },
        ], version: version)
    }

    /// Answers one JSON-RPC message. nil for notifications, which get no reply.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.reply(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let method = message["method"] as? String else {
            return message["id"] == nil ? nil : Self.reply(id: message["id"]!, error: (-32600, "Invalid request"))
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }   // a notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let chosen = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.reply(id: id, result: [
                "protocolVersion": chosen,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "myopencleaner", "title": "MyOpenCleaner", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.reply(id: id, result: [:])
        case "tools/list":
            return Self.reply(id: id, result: ["tools": tools.map { t -> [String: Any] in
                ["name": t.name, "description": t.description, "inputSchema": t.inputSchema,
                 "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return Self.reply(id: id, error: (-32602, "Unknown tool"))
            }
            let text = tool.run(params["arguments"] as? [String: Any] ?? [:])
            return Self.reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
        default:
            return Self.reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    static func reply(id: Any, result: [String: Any]) -> String {
        ScanJSON.string(["jsonrpc": "2.0", "id": id, "result": result], pretty: false)
    }

    static func reply(id: Any, error: (code: Int, message: String)) -> String {
        ScanJSON.string(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]], pretty: false)
    }

    /// Reads one message per line from stdin and writes each reply on its own line to stdout, until stdin closes.
    public func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let out = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((out + "\n").utf8))
        }
    }
}
