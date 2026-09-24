import Testing
import Foundation
@testable import BeaverCore

@Suite("MCP.md drift and guide")
struct MCPDocTests {

    private static let repoDoc: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Beaver/Resources/MCP.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    private func section(_ heading: String, in doc: String) -> String {
        guard let start = doc.range(of: "\n## \(heading)\n") else { return "" }
        let rest = doc[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
    }

    @Test("Every registered tool is in MCP.md's Tools table, and nothing else is")
    func drift() {
        let rows = section("Tools", in: Self.repoDoc).split(separator: "\n")
            .compactMap { $0.firstMatch(of: /^\| `([a-z_]+)` \|/).map { String($0.1) } }
        #expect(Set(rows) == Set(BeaverTools.all.map(\.name)))
        #expect(rows.count == BeaverTools.all.count)
    }

    @Test("The bundled guide is the repo file")
    func bundled() {
        #expect(!Self.repoDoc.isEmpty)
        #expect(AgentGuide.markdown == Self.repoDoc)
    }

    @Test("Every tool appears in at least one recipe")
    func recipesCoverTools() {
        let recipes = section("Recipes", in: Self.repoDoc)
        for tool in BeaverTools.all {
            #expect(recipes.contains(tool.name), "no recipe mentions \(tool.name)")
        }
    }

    @Test("beaver_guide lists topics and returns one")
    func guide() async throws {
        let ctx = makeContext(try LogStore(source: .inMemory))
        let list = try await GuideTool.tool.run(ToolArguments(), ctx)
        #expect(list.body.contains("overview"))
        let one = try await GuideTool.tool.run(ToolArguments(["topic": "investigate"]), ctx)
        #expect(one.body.contains("logs_facets"))
        do {
            _ = try await GuideTool.tool.run(ToolArguments(["topic": "nope"]), ctx)
            #expect(Bool(false), "Expected ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("Example: beaver_guide(topic:"))
        }
    }

    @Test("Every tool description starts with Use")
    func descriptions() {
        for tool in BeaverTools.all { #expect(tool.description.hasPrefix("Use "), "\(tool.name)") }
    }
}
