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

    @Test("sessions_list marks (live now) only on the host's live session, not any unended live one")
    func onlyHostLiveSessionMarkedLiveNow() async throws {
        // A crash can leave an old session with no endedAt even though it's
        // not the device's current session — Session.isActive alone can't
        // tell them apart, only the host's own liveSessionId can.
        let store = try LogStore(source: .inMemory)
        let orphaned = try await store.createSession(source: .live)
        let current = try await store.createSession(source: .live)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: current.id))
        let r = try await StatusTools.sessionsList.run(ToolArguments(), ctx)
        let rows = try #require(r.structured["sessions"]?.array)
        let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row["id"]?.int64.map { ($0, row) } })
        #expect(byId[current.id]?["liveNow"] == true)
        #expect(byId[orphaned.id]?["liveNow"] == false)
        let lines = r.body.split(separator: "\n")
        #expect(lines.first(where: { $0.hasPrefix("#\(current.id) ") })?.contains("(live now)") == true)
        #expect(lines.first(where: { $0.hasPrefix("#\(orphaned.id) ") })?.contains("(live now)") == false)
    }

    @Test("Review focus: sessions_list on a fresh install")
    func freshInstall() async throws {
        let store = try LogStore(source: .inMemory)
        let r = try await StatusTools.sessionsList.run(ToolArguments(), makeContext(store))
        #expect(r.summary == "Beaver has no sessions yet.")
        #expect(!r.next.isEmpty)
    }

    @Test("sessions_list filters by source: imported only")
    func sourceImportedOnly() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await store.createSession(source: .live)
        let imported = try await store.createSession(source: .imported)
        let args = ToolArguments(["source": .string("imported")])
        let r = try await StatusTools.sessionsList.run(args, makeContext(store))
        let rows = try #require(r.structured["sessions"]?.array)
        #expect(rows.count == 1)
        #expect(rows.first?["id"]?.int64 == imported.id)
    }

    @Test("sessions_list with limit: returns one row")
    func limitOne() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await store.createSession(source: .imported)
        _ = try await store.createSession(source: .live)
        let args = ToolArguments(["limit": JSON(1)])
        let r = try await StatusTools.sessionsList.run(args, makeContext(store))
        let rows = try #require(r.structured["sessions"]?.array)
        #expect(rows.count == 1)
        #expect(r.structured["total"]?.int64 == 2)
    }

    @Test("sessions_list rejects invalid source")
    func sourceBogusRejected() async throws {
        let store = try LogStore(source: .inMemory)
        let args = ToolArguments(["source": .string("bogus")])
        do {
            _ = try await StatusTools.sessionsList.run(args, makeContext(store))
            #expect(Bool(false), "Expected ToolError to be thrown")
        } catch let error as ToolError {
            #expect(error.message.contains("source must be live, imported or any"))
        }
    }

    @Test("beaver_status reports the notification state, and how to turn it on")
    func notifications() async throws {
        let store = try LogStore(source: .inMemory)
        let denied = try await StatusTools.status.run(ToolArguments(),
                                                       makeContext(store, ui: HostSnapshot(notifications: .denied)))
        #expect(denied.structured["notifications"] == "denied")
        #expect(denied.body.contains(AgentNotifications.howToEnable))

        // Beaver isn't listed in System Settings until it has asked once,
        // so notDetermined points at what triggers the ask instead of the
        // Settings path.
        let notDetermined = try await StatusTools.status.run(ToolArguments(),
                                                              makeContext(store, ui: HostSnapshot(notifications: .notDetermined)))
        #expect(notDetermined.structured["notifications"] == "notDetermined")
        #expect(notDetermined.body.contains("attention note"))
        #expect(!notDetermined.body.contains(AgentNotifications.howToEnable))
    }
}
