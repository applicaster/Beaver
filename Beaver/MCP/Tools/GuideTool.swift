//
//  GuideTool.swift
//  Beaver
//

import Foundation

/// MCP.md, bundled (design M31): the same file humans read.
enum AgentGuide {
    static var markdown: String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "MCP", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// `### key — heading` sections under `## Recipes`.
    static func topics(in doc: String) -> [(key: String, heading: String, body: String)] {
        guard let start = doc.range(of: "\n## Recipes\n") else { return [] }
        let recipes = doc[start.upperBound...]
        let end = recipes.range(of: "\n## ")?.lowerBound ?? recipes.endIndex
        return recipes[..<end].components(separatedBy: "\n### ").dropFirst().map { chunk in
            let heading = chunk.prefix { $0 != "\n" }
            let key = heading.components(separatedBy: " — ").first ?? String(heading)
            return (key.trimmingCharacters(in: .whitespaces), String(heading), "### " + chunk)
        }
    }
}

enum GuideTool {
    static let tool = MCPTool(
        name: "beaver_guide",
        title: "How to use Beaver",
        description: "Use when unsure how to do something with Beaver: step-by-step recipes with real calls. No topic lists the topics.",
        kind: .read,
        inputSchema: ToolSchema.object(["topic": ToolSchema.string("A topic from the list; omit for the list.")])
    ) { args, _ in
        let topics = AgentGuide.topics(in: AgentGuide.markdown)
        guard !topics.isEmpty else {
            throw ToolError("Beaver's guide is missing from this build. Report it with the Beaver version; meanwhile call beaver_status().")
        }
        guard let wanted = try args.string("topic")?.lowercased() else {
            return ToolResult(
                summary: "\(topics.count) topics.",
                body: topics.map { "- \($0.heading)" }.joined(separator: "\n"),
                structured: ["topics": .array(topics.map { .string($0.key) })],
                next: topics.first.map { ["beaver_guide(topic: \"\($0.key)\")"] } ?? []
            )
        }
        guard let topic = topics.first(where: { $0.key == wanted }) else {
            let exampleKey = topics.first(where: { $0.key == "overview" })?.key ?? topics.first?.key ?? "overview"
            throw ToolError("No topic \"\(wanted)\". Example: beaver_guide(topic: \"\(exampleKey)\"). Topics: \(topics.map(\.key).joined(separator: ", ")).")
        }
        return ToolResult(summary: "Recipe: \(topic.heading).", body: topic.body,
                          structured: ["topic": .string(topic.key), "markdown": .string(topic.body)],
                          next: ["beaver_guide() for the other topics"])
    }
}
