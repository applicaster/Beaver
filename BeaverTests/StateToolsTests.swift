import Testing
import Foundation
@testable import BeaverCore

@Suite("Storage, commands, bookmarks, filters tools")
struct StateToolsTests {

    @Test("Storage snapshot per layer, secure = keychain")
    func storage() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .local,
                                              dataJSON: #"{"applicaster.v2":{"onboardingDone":"true"}}"#)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let local = try await StateTools.storageSnapshot.run(ToolArguments(["layer": "local"]), ctx)
        #expect(local.structured["layers"]?["local"]?["data"]?["applicaster.v2"]?["onboardingDone"] == "true")
        let all = try await StateTools.storageSnapshot.run(ToolArguments(), ctx)
        #expect(all.body.contains("Keychain: no snapshot"))
        await #expect(throws: ToolError.self) {
            try await StateTools.storageSnapshot.run(ToolArguments(["layer": "cookies"]), ctx)
        }
        let secure = try await StateTools.storageSnapshot.run(ToolArguments(["layer": "secure"]), ctx)
        #expect(secure.body == "Keychain: no snapshot")
    }

    @Test("Commands from the device's cmdlist")
    func commands() async throws {
        let store = try LogStore(source: .inMemory)
        let hints = [CommandHint(name: "storage.local.set", syntax: "storage.local.set <key> <value> [namespace]", description: "Write"),
                     CommandHint(name: "custom.thing", syntax: nil, description: nil)]
        let r = try await StateTools.commandsList.run(ToolArguments(), makeContext(store, ui: HostSnapshot(commands: hints)))
        #expect(r.body.contains("storage.local.set <key> <value> [namespace] — Write"))
        #expect(r.body.contains("custom.thing"))
        let none = try await StateTools.commandsList.run(ToolArguments(), makeContext(store))
        #expect(none.summary.hasPrefix("No command list yet"))
    }

    @Test("Bookmarked events")
    func bookmarks() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.error, "a", "", "keep me")])
        let id = try #require(try await store.latestEventId(sessionId: s.id))
        try await store.addBookmark(eventId: id, sessionId: s.id)
        let r = try await StateTools.bookmarksList.run(ToolArguments(), makeContext(store, ui: HostSnapshot(liveSessionId: s.id)))
        #expect(r.body.contains("keep me"))
        #expect(r.structured["events"]?.array?.count == 1)
    }

    @Test("Saved filters described")
    func filters() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.upsertSavedFilter(name: "Auth", filter: Filter(minLevel: .warning, subsystems: ["com.app.auth"]))
        let r = try await StateTools.filtersList.run(ToolArguments(), makeContext(store))
        #expect(r.body.contains("Auth — level ≥ warning; subsystems com.app.auth"))
    }
}
