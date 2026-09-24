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

    @Test("Each permission state has the strip, the path and the button that works (M28)")
    func strips() throws {
        #expect(AgentNotifications.strip(for: .allowed) == nil)
        #expect(AgentNotifications.strip(for: .muted) == nil)
        let ask = try #require(AgentNotifications.strip(for: .notDetermined))
        #expect(ask.action == .askPermission)
        #expect(ask.button == "Allow Notifications")
        #expect(ask.title.contains("hasn't asked yet"))
        let denied = try #require(AgentNotifications.strip(for: .denied))
        #expect(denied.action == .openSettings)
        #expect(denied.button == "Open System Settings")
        for strip in [ask, denied] {
            #expect(strip.detail == "Turn on: System Settings → Notifications → Beaver → Allow Notifications (style: Banners)")
        }
        #expect(AgentNotifications.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.applicaster.LoggerNext")
        #expect(AgentNotifications.menuTitle(for: .denied) == "Agent Notifications: Off — Turn On…")
        #expect(AgentNotifications.menuTitle(for: .notDetermined) == "Agent Notifications: Off — Turn On…")
        #expect(AgentNotifications.menuTitle(for: .allowed) == "Agent Notifications: On")
        #expect(AgentNotifications.menuTitle(for: .muted) == "Agent Notifications: Muted in Beaver")
    }

    @Test("What journal_note tells the agent, per state")
    func outcomes() {
        #expect(AgentNotifications.outcome(state: .allowed, frontmost: false, held: false) == NotifyOutcome(notified: true))
        #expect(AgentNotifications.outcome(state: .allowed, frontmost: false, held: true).notified)
        // In front, the toast is enough, whatever the permission.
        #expect(AgentNotifications.outcome(state: .denied, frontmost: true, held: false).notified)
        let denied = AgentNotifications.outcome(state: .denied, frontmost: false, held: false)
        #expect(!denied.notified)
        #expect(denied.howToEnable == AgentNotifications.howToEnable)
        let asked = AgentNotifications.outcome(state: .notDetermined, frontmost: false, held: false)
        #expect(!asked.notified)
        #expect(asked.howToEnable == AgentNotifications.howToEnable)
        let muted = AgentNotifications.outcome(state: .muted, frontmost: false, held: false)
        #expect(!muted.notified)
        #expect(muted.howToEnable == nil)
    }

    @Test("Review focus: at most one notification per 30 s; the rest become one summary")
    func throttle() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var t = NotificationThrottle()
        let admit1 = t.admit(at: t0)
        let admit2 = t.admit(at: t0 + 10)
        let admit3 = t.admit(at: t0 + 20)
        let windowEnds1 = t.windowEnds
        let drain1 = t.drain(at: t0 + 30)
        let windowEnds2 = t.windowEnds
        let admit4 = t.admit(at: t0 + 40)
        let drain2 = t.drain(at: t0 + 60)
        let drain3 = t.drain(at: t0 + 61)
        let admit5 = t.admit(at: t0 + 91)
        #expect(admit1)
        #expect(!admit2)
        #expect(!admit3)
        #expect(windowEnds1 == t0 + 30)
        #expect(drain1 == 2)
        #expect(windowEnds2 == nil)
        #expect(!admit4)      // the summary opened a new window
        #expect(drain2 == 1)
        #expect(drain3 == 0)
        #expect(admit5)
        #expect(AgentNotifications.summary(count: 1) == "1 new finding from the agent")
        #expect(AgentNotifications.summary(count: 3) == "3 new findings from the agent")
    }

    @Test("discardHeld drops what's held without opening a new window")
    func discardHeld() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var t = NotificationThrottle()
        let admit1 = t.admit(at: t0)
        let admit2 = t.admit(at: t0 + 10)
        let windowEnds1 = t.windowEnds
        t.discardHeld()
        let windowEnds2 = t.windowEnds
        // Unlike drain(), discardHeld() never opens a new window: the next
        // note still has to wait out the original 30 s from t0.
        let admit3 = t.admit(at: t0 + 20)
        #expect(admit1)
        #expect(!admit2)
        #expect(windowEnds1 == t0 + 30)
        #expect(windowEnds2 == nil)
        #expect(!admit3)
    }
}
