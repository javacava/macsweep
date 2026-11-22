import Foundation
import Testing
@testable import SweepCore

/// The Storage page's model: owners, areas, no double counting, and the "Other" slice.
@Suite struct StorageOverviewTests {
    func junk(_ path: String, _ size: Int64, _ category: JunkCategory, rule: String = "user-caches", safety: Safety = .safe) -> JunkItem {
        JunkItem(url: URL(fileURLWithPath: path), size: size, category: category, ruleID: rule, selectedByDefault: true, safety: safety)
    }

    func dev(_ path: String, _ size: Int64, _ group: DevItem.Group, tool: String?, safety: Safety? = nil) -> DevItem {
        let url = URL(fileURLWithPath: path)
        return DevItem(id: path, group: group, title: url.lastPathComponent, detail: "", size: size, removal: .files([url]),
                       location: url, safetyOverride: safety, tool: tool)
    }

    @Test func itemsAreGroupedByToolAndArea() {
        let o = StorageOverview.build(
            junk: [junk("/h/Library/Caches/com.example.app", 100, .userCache),
                   junk("/h/Library/Application Support/Slack/Cache", 300, .appCaches, rule: "app-cache:~/Library/Application Support/Slack/Cache")],
            dev: [dev("/h/.ollama/logs", 50, .aiTools, tool: "Ollama"), dev("/h/.ollama/models/m", 500, .aiModels, tool: "Ollama"),
                  dev("/h/code/app/node_modules", 200, .builds, tool: "app"), dev("/h/.npm/_cacache", 70, .packageCaches, tool: "npm")])
        let byName = Dictionary(uniqueKeysWithValues: o.owners.map { ($0.name, $0) })
        #expect(byName["Ollama"]?.area == .ai && byName["Ollama"]?.size == 550 && byName["Ollama"]?.items.count == 2)
        #expect(byName["Slack"]?.area == .apps, "app cache rules name their app")
        #expect(byName["User cache"]?.area == .macOS, "a macOS location without a tool is named after its category")
        #expect(byName["app"]?.area == .projects && byName["npm"]?.area == .developer)
        #expect(o.size == 1220)
        #expect(o.areas.first == .ai, "areas are sorted biggest first")
        #expect(o.owners.first?.name == "Ollama")
    }

    @Test func nothingIsCountedTwice() {
        // The same folder from both pages, a junk folder that holds dev items, and one inside a dev folder.
        let o = StorageOverview.build(
            junk: [junk("/h/Library/Caches/ccache", 100, .userCache),
                   junk("/h/Library/Caches/JetBrains", 400, .userCache),
                   junk("/h/Library/Caches/Yarn/v6", 10, .devTools),
                   junk("/h/Library/Caches/other", 7, .userCache)],
            dev: [dev("/h/Library/Caches/ccache", 100, .packageCaches, tool: "ccache"),
                  dev("/h/Library/Caches/JetBrains/IntelliJIdea2025.1", 380, .ideCaches, tool: "JetBrains"),
                  dev("/h/Library/Caches/Yarn", 10, .packageCaches, tool: "Yarn")])
        #expect(o.size == 100 + 380 + 10 + 7)
        #expect(o.owners.first { $0.name == "User cache" }?.items.count == 1)
    }

    @Test func safetySizesAddUp() {
        let o = StorageOverview.build(junk: [junk("/h/Library/Caches/a", 10, .userCache)],
                                      dev: [dev("/h/.pyenv/versions/3.11", 40, .toolVersions, tool: "pyenv"),
                                            dev("/h/.pyenv/versions/3.12", 60, .toolVersions, tool: "pyenv", safety: .kept)])
        #expect(o.size(.safe) == 10 && o.size(.review) == 40 && o.size(.kept) == 60)
        let pyenv = o.owners.first { $0.name == "pyenv" }
        #expect(pyenv?.size(.kept) == 60)
        #expect(pyenv?.items.first { $0.safety == .kept }?.isRemovable == false)
        #expect(pyenv?.items.first { $0.safety == .kept }?.selectedByDefault == false)
    }

    @Test func smallToolsFoldIntoOtherForTheRings() {
        var devItems = [dev("/h/big", 1000, .packageCaches, tool: "Big")]
        for i in 0..<5 { devItems.append(dev("/h/s\(i)", 5, .packageCaches, tool: "Small \(i)")) }
        let o = StorageOverview.build(junk: [], dev: devItems)
        let ring = o.ringOwners(in: .developer)
        #expect(ring.map(\.name) == ["Big", "Other"])
        #expect(ring.last?.items.count == 5 && ring.last?.size == 25)
        #expect(o.owners(in: .developer).count == 6, "the list still shows every tool")
    }

    @Test func scannersNameTheirTools() {
        let s = Sandbox()
        s.file("~/.npm/_cacache/x", bytes: 5000)
        s.file("~/.pyenv/versions/3.11.9/bin/python", bytes: 5000)
        s.file("~/.colima/_lima/colima/diffdisk", bytes: 5000)
        let items = DevFolderScanner(env: s.env).scan()
        #expect(items.first { $0.title == "npm" }?.owner == "npm")
        #expect(items.first { $0.group == .toolVersions }?.owner == "pyenv")
        #expect(items.first { $0.group == .virtualMachines }?.owner == "Colima")
        #expect(SimulatorScanner.parseRuntimes(Data("{}".utf8)).isEmpty)
    }
}
