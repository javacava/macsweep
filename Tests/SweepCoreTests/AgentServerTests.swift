import Foundation
import Testing
@testable import SweepCore

/// The read-only MCP server, the JSON it returns, and the catalog of supported tools.

@Suite struct MCPServerTests {
    static func object(_ line: String?) throws -> [String: Any] {
        let data = try #require(line?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let server = MCPServer.standard(env: Sandbox().env, runner: FakeRunner(), version: "9.9.9")

    @Test func initializeAgreesOnAVersion() throws {
        let known = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let result = try #require(known["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "9.9.9")
        #expect((result["instructions"] as? String)?.contains("read-only") == true)
        let unknown = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0])
    }

    @Test func notificationsGetNoReply() {
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func everyToolIsReadOnly() throws {
        let reply = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["scan_junk", "scan_developer", "mac_status", "supported_tools"])
        for t in tools {
            let a = t["annotations"] as? [String: Any]
            #expect(a?["readOnlyHint"] as? Bool == true && a?["destructiveHint"] as? Bool == false)
            #expect((t["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
        #expect(reply["id"] as? String == "a")
    }

    @Test func scanJunkReportsSafetyAndRemovesNothing() throws {
        let s = Sandbox()
        s.file("~/Library/Caches/com.example.app/cache.db", bytes: 5000)
        let server = MCPServer.standard(env: s.env, runner: FakeRunner(), version: "1")
        let reply = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scan_junk","arguments":{"categories":["userCache"]}}}"#))
        let content = try #require(((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        let json = try Self.object(content["text"] as? String)
        let category = try #require((json["categories"] as? [[String: Any]])?.first)
        #expect(category["id"] as? String == "userCache")
        let item = try #require((category["items"] as? [[String: Any]])?.first)
        #expect(item["safety"] as? String == "safe")
        #expect(item["path"] as? String == "~/Library/Caches/com.example.app", "paths are shown with ~, not the full home path")
        #expect(s.exists("~/Library/Caches/com.example.app/cache.db"))
    }

    @Test func errors() throws {
        #expect(try Self.object(server.handle("not json"))["error"] != nil)
        let unknownMethod = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#))
        #expect((unknownMethod["error"] as? [String: Any])?["code"] as? Int == -32601)
        let unknownTool = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_everything"}}"#))
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let ping = try Self.object(server.handle(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#))
        #expect(ping["result"] != nil)
    }
}

@Suite struct ScanJSONTests {
    @Test func keptItemsDoNotCountAsFreeable() throws {
        let s = Sandbox()
        let items = [
            DevItem(id: "a", group: .packageCaches, title: "npm", detail: "", size: 100, removal: .files([]), selectedByDefault: true),
            DevItem(id: "b", group: .toolVersions, title: "Node v20", detail: "", size: 50, removal: .files([])),
            DevItem(id: "c", group: .virtualMachines, title: "Colima", detail: "", size: 1000, removal: .files([]), safetyOverride: .kept),
        ]
        let json = ScanJSON.developer(items, env: s.env)
        #expect(json["removableBytes"] as? Int64 == 150)
        #expect(json["safeBytes"] as? Int64 == 100)
        #expect(ScanJSON.string(json).contains("\"kept\""))
    }

    @Test func limitKeepsTheBiggest() {
        let s = Sandbox()
        for (i, size) in [100, 9000, 500].enumerated() { s.file("~/Library/Caches/app\(i)/x", bytes: size) }
        let r = JunkScanner(env: s.env).scan(categories: [.userCache])
        let json = ScanJSON.junk(r, env: s.env, limit: 1)
        let items = ((json["categories"] as? [[String: Any]])?.first?["items"] as? [[String: Any]]) ?? []
        #expect(items.count == 1 && (items.first?["path"] as? String)?.hasSuffix("app1") == true)
    }
}

@Suite struct SupportedToolsTests {
    @Test func everyRuleIsInTheCatalog() {
        let names = Set(SupportedTools.catalog.map(\.name))
        for rule in DevFolderScanner.rules { #expect(names.contains(rule.tool), "\(rule.tool)") }
        for rule in JunkRules.all { #expect(names.contains(rule.tool ?? rule.category.title)) }
        for app in AIModelScanner.folders { #expect(names.contains(app.app)) }
        #expect(SupportedTools.catalog.count > 120)
    }

    @Test func entriesAreNotRepeated() {
        for tool in SupportedTools.catalog {
            #expect(Set(tool.entries.map(\.what)).count == tool.entries.count || tool.entries.count == Set(tool.entries.map { "\($0.what)\($0.safety)" }).count,
                    "\(tool.name)")
        }
        let keys = SupportedTools.catalog.map { "\($0.area.rawValue)/\($0.name)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func htmlIsEscaped() {
        let html = SupportedTools.htmlFragment([.init(name: "A<b>&\"", area: .apps, entries: [.init(what: "x<y", safety: .kept)])])
        #expect(html.contains("A&lt;b&gt;&amp;&quot;") && html.contains("x&lt;y") && !html.contains("<b>"))
        #expect(html.contains("class=\"mark kept\""))
    }

    @Test func titlesLoseTheirToolPrefix() {
        #expect(SupportedTools.plainWhat("VS Code old versions data", tool: "VS Code") == "Old versions data")
        #expect(SupportedTools.plainWhat("npm", tool: "npm") == "npm")
        #expect(SupportedTools.plainWhat("DerivedData", tool: "Xcode") == "DerivedData")
    }

    /// docs/tools/index.html is generated from the catalog (scripts/update_tools_page.sh); it must match the app.
    @Test func websitePageMatchesTheCatalog() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: repo.appendingPathComponent("docs/tools/index.html"), encoding: .utf8)
        let start = try #require(page.range(of: "<!-- tools:start -->\n"))
        let end = try #require(page.range(of: "<!-- tools:end -->"))
        #expect(String(page[start.upperBound..<end.lowerBound]) == SupportedTools.htmlFragment(),
                "Run scripts/update_tools_page.sh to regenerate docs/tools/index.html")
    }
}
