// BeaverTests/StatusToolsTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Status and sessions tools")
struct StatusToolsTests {

    @Test("beaver_status with a device")
    func statusConnected() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.info, "a", "", "x")])
        let ctx = makeContext(store, ui: HostSnapshot(serverState: "clientConnected", deviceConnected: true,
                                                      liveSessionId: s.id, viewingSessionId: s.id))
        let r = try await StatusTools.status.run(ToolArguments(), ctx)
        #expect(r.summary.hasPrefix("A device is connected"))
        #expect(r.structured["devices"]?.array?.count == 1)
        #expect(r.structured["devices"]?.array?.first?["latestEventId"]?.int64 != nil)
        #expect(r.next.first?.hasPrefix("logs_facets") == true)
    }

    @Test("Review focus: beaver_status on a fresh install")
    func statusEmpty() async throws {
        let store = try LogStore(source: .inMemory)
        let r = try await StatusTools.status.run(ToolArguments(), makeContext(store))
        #expect(r.summary.hasPrefix("No device is connected"))
        #expect(r.structured["devices"] == [])
        #expect(r.body.contains("ws://192.168.1.5:9080"))
    }

    @Test("sessions_list with counts, newest first")
    func sessions() async throws {
        let store = try LogStore(source: .inMemory)
        let old = try await store.createSession(source: .imported)
        let new = try await store.createSession(source: .live)
        try await seed(store, session: new.id, [(.info, "a", "", "x"), (.info, "a", "", "y")])
        let r = try await StatusTools.sessionsList.run(ToolArguments(), makeContext(store))
        let rows = try #require(r.structured["sessions"]?.array)
        #expect(rows.map { $0["id"]?.int64 } == [new.id, old.id])
        #expect(rows.first?["events"] == 2)
        #expect(r.body.split(separator: "\n").first?.hasPrefix("#\(new.id) live") == true)
    }

    @Test("Review focus: sessions_list on a fresh install")
    func freshInstall() async throws {
        let store = try LogStore(source: .inMemory)
        let r = try await StatusTools.sessionsList.run(ToolArguments(), makeContext(store))
        #expect(r.summary == "Beaver has no sessions yet.")
        #expect(!r.next.isEmpty)
    }
}
