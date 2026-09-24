// BeaverTests/AgentSignalTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Agent signals")
struct AgentSignalTests {

    private func entry(_ kind: AgentActivity.Kind, level: String? = nil, isError: Bool = false,
                       links: [JournalLink] = []) -> AgentActivity {
        AgentActivity(id: 1, at: Date(), client: "claude-code", tool: "t", kind: kind,
                      summary: "Deleted session #12", level: level, isError: isError,
                      error: isError ? "boom" : nil, linksJSON: JournalLink.encode(links),
                      sessionId: nil, seen: false)
    }

    @Test("Only destructive calls and attention notes toast (design §7.2)")
    func toasts() {
        #expect(entry(.read).toast == nil)
        #expect(entry(.change).toast == nil)
        #expect(entry(.system).toast == nil)
        #expect(entry(.note, level: "info").toast == nil)
        #expect(entry(.destructive, isError: true).toast == nil)
        #expect(entry(.destructive).toast == AgentToast(message: "Agent: Deleted session #12", button: .journal))
        #expect(entry(.note, level: "attention", links: [.event(5), .network(2)]).toast?.button == .show(.event(5)))
        #expect(entry(.note, level: "attention").toast?.button == .journal)
    }

    @Test("Idempotent tools say so; only reads are read-only")
    func hints() {
        let tool = MCPTool(name: "x_set", title: "X", description: "Use x", kind: .change, idempotent: true,
                           inputSchema: ToolSchema.object([:])) { _, _ in ToolResult(summary: "ok") }
        #expect(tool.listing["annotations"]?["idempotentHint"] == true)
        #expect(tool.listing["annotations"]?["readOnlyHint"] == false)
        #expect(tool.listing["annotations"]?["destructiveHint"] == false)
    }
}
