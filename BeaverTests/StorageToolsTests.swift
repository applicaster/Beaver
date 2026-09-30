import Testing
import Foundation
@testable import BeaverCore

/// Plays the SDK's storage handler (PROTOCOL.md §3.2): applies set / delete
/// to its local layer and answers storage.list with a snapshot.
actor FakeStorageApp {
    private var local: [String: String] = ["onboardingDone": "true"]
    private let store: LogStore
    private let sessionId: Int64
    private let applies: Bool
    private let answers: Bool

    init(store: LogStore, sessionId: Int64, applies: Bool = true, answers: Bool = true) {
        self.store = store; self.sessionId = sessionId; self.applies = applies; self.answers = answers
    }

    func handle(_ command: String) async {
        let words = command.split(separator: " ").map(String.init)
        switch words.first ?? "" {
        case "storage.local.set" where applies && words.count >= 3:
            local[words[1]] = words[2]
        case "storage.local.delete" where applies && words.count >= 2:
            local[words[1]] = nil
        case "storage.list" where answers:
            let json = JSON.object(["applicaster.v2": .object(local.mapValues(JSON.string))]).text
            try? await store.recordStorageSnapshot(sessionId: sessionId, namespace: .local, dataJSON: json)
        default:
            break
        }
    }
}

@Suite("Storage tools")
struct StorageToolsTests {

    private func fixture(applies: Bool = true, answers: Bool = true, commands: [CommandHint] = [])
        async throws -> (LogStore, ToolContext, FakeDevice) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: s.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil)
        let app = FakeStorageApp(store: store, sessionId: s.id, applies: applies, answers: answers)
        let device = FakeDevice { await app.handle($0) }
        let ui = HostSnapshot(liveSessionIds: [s.id], commandsBySession: [s.id: commands])
        return (store, makeContext(store, ui: ui, device: device), device)
    }

    @Test("storage_set sends the command, re-reads storage and reports applied")
    func setApplied() async throws {
        let (_, ctx, device) = try await fixture()
        let r = try await StorageTools.set.run(
            ToolArguments(["layer": "local", "key": "onboardingDone", "value": "false"]), ctx)
        #expect(device.sent == ["storage.local.set onboardingDone false", "storage.list"])
        #expect(r.structured["outcome"] == "applied")
        #expect(r.summary.hasPrefix("Set local/applicaster.v2/onboardingDone = false on Alpha: applied"))
        let live = try #require(r.structured["sessionId"]?.int64)
        #expect(r.next.contains { $0.hasPrefix("logs_wait(sessionId: \(live), afterId: ") })
        #expect(r.next.contains { $0.hasPrefix("storage_snapshot(sessionId: \(live), ") })
    }

    @Test("A JSON value is sent compact and matched by content")
    func jsonValue() async throws {
        let (_, ctx, device) = try await fixture()
        let r = try await StorageTools.set.run(
            ToolArguments(["layer": "local", "key": "flags", "value": ["premium": true]]), ctx)
        #expect(device.sent.first == #"storage.local.set flags {"premium":true}"#)
        #expect(r.structured["outcome"] == "applied")
    }

    @Test("Review focus: a value with a space, a tab or nothing is refused before anything is sent")
    func spacesRefused() async throws {
        let (_, ctx, device) = try await fixture()
        for value in ["hello world", "a\tb", "  "] {
            do {
                _ = try await StorageTools.set.run(ToolArguments(["layer": "local", "key": "k", "value": .string(value)]), ctx)
                Issue.record("expected \(value) to be refused")
            } catch let error as ToolError {
                #expect(error.message.hasPrefix("Not sent."))
                #expect(error.message.contains("storage_set(layer:"))
                // D97: the app's storage toolbox sends it as is.
                #expect(error.message.contains(#"tools_call(name: "storage.set", arguments: {storageType: "local", key: "k""#))
            }
        }
        await #expect(throws: ToolError.self) {
            try await StorageTools.set.run(ToolArguments(["layer": "local", "key": "my key", "value": "v"]), ctx)
        }
        await #expect(throws: ToolError.self) {
            try await StorageTools.set.run(ToolArguments(["layer": "all", "key": "k", "value": "v"]), ctx)
        }
        #expect(device.sent.isEmpty)
    }

    @Test("An unknown layer is refused with the calling tool's own example")
    func unknownLayer() async throws {
        let (_, ctx, device) = try await fixture()
        do {
            _ = try await StorageTools.set.run(ToolArguments(["layer": "cookies", "key": "k", "value": "v"]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("storage_set(layer:"))
        }
        #expect(device.sent.isEmpty)
    }

    @Test("The app answered without the change: not applied")
    func notApplied() async throws {
        let (_, ctx, _) = try await fixture(applies: false)
        let r = try await StorageTools.set.run(ToolArguments(["layer": "local", "key": "k", "value": "v"]), ctx)
        #expect(r.structured["outcome"] == "notApplied")
        #expect(r.next.first?.hasPrefix("logs_query(sessionId: ") == true)
    }

    @Test("The app never answered: noAnswer")
    func noAnswer() async throws {
        let (_, ctx, _) = try await fixture(answers: false)
        let r = try await StorageTools.set.run(ToolArguments(["layer": "local", "key": "k", "value": "v"]), ctx)
        #expect(r.structured["outcome"] == "noAnswer")
        #expect(r.summary.contains("can't tell"))
    }

    @Test("storage_delete removes the key and is destructive")
    func delete() async throws {
        let (_, ctx, device) = try await fixture()
        let r = try await StorageTools.delete.run(ToolArguments(["layer": "local", "key": "onboardingDone"]), ctx)
        #expect(device.sent.first == "storage.local.delete onboardingDone")
        #expect(r.structured["outcome"] == "applied")
        #expect(StorageTools.delete.kind == .destructive)
    }

    @Test("A layer the app's cmdlist doesn't offer is refused")
    func unsupported() async throws {
        let (_, ctx, device) = try await fixture(commands: [CommandHint(name: "storage.local.set", syntax: nil, description: nil)])
        do {
            _ = try await StorageTools.delete.run(ToolArguments(["layer": "local", "key": "k"]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("storage.local.delete"))
        }
        #expect(device.sent.isEmpty)
    }

    @Test("storage_snapshot asks the connected app for fresh storage")
    func refresh() async throws {
        let (_, ctx, device) = try await fixture()
        let r = try await StorageTools.snapshot.run(ToolArguments(["layer": "local"]), ctx)
        #expect(device.sent == ["storage.list"])
        #expect(r.summary.contains("Fresh from Alpha."))
        #expect(r.next.contains { $0.contains("logs_query(sessionId: ") })
        #expect(r.structured["layers"]?["local"]?["data"]?["applicaster.v2"]?["onboardingDone"] == "true")
        let stored = try await StorageTools.snapshot.run(ToolArguments(["layer": "local", "refresh": false]), ctx)
        #expect(stored.summary.contains("refresh: false"))
        #expect(device.sent.count == 1)
    }

    @Test("Without a device the stored snapshot is read, and says so")
    func offline() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .local, dataJSON: #"{"applicaster.v2":{"k":"v"}}"#)
        let r = try await StorageTools.snapshot.run(ToolArguments(), makeContext(store, ui: HostSnapshot(viewingSessionId: s.id)))
        #expect(r.summary.contains("Not refreshed: no device is connected"))
    }

    @Test("storage_diff: earliest against latest, fresh from the connected app")
    func diffLive() async throws {
        let (_, ctx, device) = try await fixture()
        _ = try await StorageTools.snapshot.run(ToolArguments(["layer": "local"]), ctx)
        let first = try await StorageTools.diff.run(ToolArguments(["layer": "local"]), ctx)
        #expect(first.summary.contains("nothing to compare"))
        _ = try await StorageTools.set.run(
            ToolArguments(["layer": "local", "key": "onboardingDone", "value": "false"]), ctx)
        let sentBefore = device.sent.count

        let r = try await StorageTools.diff.run(ToolArguments(["layer": "local"]), ctx)
        #expect(Array(device.sent.dropFirst(sentBefore)) == ["storage.list"])
        #expect(r.summary.contains("earliest snapshot → latest: 1 change(s) (local 1). Fresh from Alpha."))
        #expect(r.body.contains("~ applicaster.v2/onboardingDone: true → false"))
        let change = r.structured["layers"]?["local"]?["changes"]?.array?.first
        #expect(change?["change"] == "changed" && change?["old"] == "true" && change?["new"] == "false")
        #expect(r.structured["layers"]?["local"]?["snapshots"]?.array?.count == 2)
        #expect(r.next.contains { $0.contains("filter: {search: \"onboardingDone\"}") })
    }

    @Test("storage_diff: beforeEventId starts from the last snapshot before the event")
    func diffBeforeEvent() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .imported)
        func record(_ json: String) async throws {
            try await store.recordStorageSnapshot(sessionId: s.id, namespace: .local, dataJSON: json)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await record(#"{"ns":{"k":"0"}}"#)
        try await record(#"{"ns":{"k":"1"}}"#)
        try await seed(store, session: s.id, [(.info, "auth", "", "login")],
                       startMillis: UInt64(Date().timeIntervalSince1970 * 1000))
        try await Task.sleep(for: .milliseconds(5))
        try await record(#"{"ns":{"k":"1","user":"{\"id\":7}"}}"#)
        let ctx = makeContext(store)
        let eventId = try #require(try await store.latestEventId(sessionId: s.id))

        let all = try await StorageTools.diff.run(ToolArguments(["sessionId": JSON(s.id), "layer": "local"]), ctx)
        #expect(all.summary.contains("2 change(s)"))
        let after = try await StorageTools.diff.run(
            ToolArguments(["sessionId": JSON(s.id), "layer": "local", "beforeEventId": JSON(eventId)]), ctx)
        #expect(after.summary.contains("before event #\(eventId) → latest: 1 change(s)"))
        #expect(after.body.contains(#"+ ns/user = {"id":7}"#))
    }

    @Test("storage_diff: one snapshot per layer says so; a wrong id says what to call")
    func diffNothingToCompare() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .imported)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .local, dataJSON: #"{"ns":{"k":"v"}}"#)
        let ctx = makeContext(store)
        let r = try await StorageTools.diff.run(ToolArguments(["sessionId": JSON(s.id)]), ctx)
        #expect(r.summary.contains("nothing to compare — one snapshot per layer"))
        #expect(r.next == ["storage_snapshot(sessionId: \(s.id), refresh: false) for what is stored"])
        do {
            _ = try await StorageTools.diff.run(ToolArguments(["sessionId": JSON(s.id), "fromId": 999]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("storage_diff(sessionId: \(s.id))"))
        }
    }
}
