import Testing
import Foundation
@testable import BeaverCore

@Suite("Session files and deletion")
struct SessionToolsTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beaver-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Beaver export: two events, local storage, one request.
    private func exportedFile(in dir: URL) async throws -> URL {
        let source = try LogStore(source: .inMemory)
        let s = try await source.createSession(source: .live)
        try await seed(source, session: s.id, [(.error, "com.app.auth", "token", "refresh failed 401"),
                                               (.info, "com.app.feed", "", "feed loaded")])
        try await source.recordStorageSnapshot(sessionId: s.id, namespace: .local, dataJSON: #"{"applicaster.v2":{"k":"v"}}"#)
        try await source.recordNetworkEntry(try #require(NetworkCapture(#"{"url":"https://a.example","status":500}"#, fallbackMillis: 0)),
                                            sessionId: s.id)
        let data = try #require(await SessionExport.make(store: source, sessionId: s.id, scope: .everything))
        let file = dir.appendingPathComponent("customer.json")
        try data.write(to: file)
        return file
    }

    @Test("Import opens a Beaver export as a new session, without switching the window")
    func importJSON() async throws {
        let store = try LogStore(source: .inMemory)
        let file = try await exportedFile(in: try tempDir())
        let ui = FakeUI()
        let r = try await SessionTools.importFile.run(ToolArguments(["path": .string(file.path)]),
                                                      makeContext(store, fakeUI: ui))
        let session = try #require(try await store.sessions().first)
        #expect(session.source == .imported)
        #expect(session.clientLabel == "customer")
        #expect(r.summary.contains("session #\(session.id)"))
        #expect(r.structured["events"] == 2)
        #expect(r.structured["requests"] == 1)
        #expect(r.structured["storageLayers"] == 1)
        #expect(ui.value.viewingSessionId == nil)
    }

    @Test("Import opens a Chrome HAR as a network-only session (§8: every file that opens keeps opening)")
    func importHAR() async throws {
        let store = try LogStore(source: .inMemory)
        let file = try tempDir().appendingPathComponent("chrome.har")
        try Data(#"""
        {"log":{"version":"1.2","creator":{"name":"WebInspector","version":"537.36"},"pages":[],
         "entries":[{"startedDateTime":"2024-03-01T10:20:30.5Z","time":123.456,
          "request":{"method":"GET","url":"https://cdn.io/a.js","httpVersion":"http/2.0","headers":[],
                     "queryString":[],"cookies":[],"headersSize":-1,"bodySize":0},
          "response":{"status":304,"statusText":"","httpVersion":"http/2.0","headers":[],"cookies":[],
                      "content":{"size":0,"mimeType":"x-unknown"},"redirectURL":"","headersSize":-1,"bodySize":0},
          "cache":{},"timings":{"send":0.1,"wait":120,"receive":3.3}}]}}
        """#.utf8).write(to: file)
        let r = try await SessionTools.importFile.run(ToolArguments(["path": .string(file.path)]), makeContext(store))
        #expect(r.structured["requests"] == 1)
        #expect(r.structured["events"] == 0)
    }

    @Test("Import refuses what isn't a session file, a missing file, and a relative path")
    func importErrors() async throws {
        let store = try LogStore(source: .inMemory)
        let junk = try tempDir().appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: junk)
        for path in [junk.path, "/no/such/file.json", "logs/today.json"] {
            await #expect(throws: ToolError.self) {
                try await SessionTools.importFile.run(ToolArguments(["path": .string(path)]), makeContext(store))
            }
        }
        #expect(try await store.sessions().isEmpty)
    }

    @Test("Export writes the filtered JSON, and a HAR of the requests")
    func export() async throws {
        let store = try LogStore(source: .inMemory)
        let dir = try tempDir()
        let imported = try await SessionTools.importFile.run(
            ToolArguments(["path": .string(try await exportedFile(in: dir).path)]), makeContext(store))
        let sid = try #require(imported.sessionId)
        let out = dir.appendingPathComponent("errors.json")
        let r = try await SessionTools.exportFile.run(
            ToolArguments(["sessionId": JSON(sid), "path": .string(out.path), "filter": ["minLevel": "error"]]),
            makeContext(store))
        #expect(r.structured["events"] == 1)
        let back = try EventJSON.decodeExport(Data(contentsOf: out))
        #expect(back.events.map(\.message) == ["refresh failed 401"])
        #expect(back.storage.count == 1)

        let har = dir.appendingPathComponent("requests.har")
        let h = try await SessionTools.exportFile.run(
            ToolArguments(["sessionId": JSON(sid), "path": .string(har.path), "format": "har"]), makeContext(store))
        #expect(h.structured["requests"] == 1)
        #expect(HARExport.decode(try Data(contentsOf: har)).count == 1)
        await #expect(throws: ToolError.self) {
            try await SessionTools.exportFile.run(
                ToolArguments(["sessionId": JSON(sid), "path": .string(dir.appendingPathComponent("x.har").path),
                               "format": "har", "filter": ["minLevel": "error"]]), makeContext(store))
        }
    }

    @Test("Review focus: export never replaces a file without overwrite: true")
    func exportNeverOverwrites() async throws {
        let store = try LogStore(source: .inMemory)
        let dir = try tempDir()
        let r = try await SessionTools.importFile.run(
            ToolArguments(["path": .string(try await exportedFile(in: dir).path)]), makeContext(store))
        let sid = try #require(r.sessionId)
        let existing = dir.appendingPathComponent("keep.json")
        try Data("precious".utf8).write(to: existing)
        do {
            _ = try await SessionTools.exportFile.run(
                ToolArguments(["sessionId": JSON(sid), "path": .string(existing.path)]), makeContext(store))
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("overwrite: true"))
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "precious")
        _ = try await SessionTools.exportFile.run(
            ToolArguments(["sessionId": JSON(sid), "path": .string(existing.path), "overwrite": true]), makeContext(store))
        #expect(try String(contentsOf: existing, encoding: .utf8) != "precious")
    }

    @Test("Review focus: a relative export path is refused with an example")
    func relativePathRejected() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        do {
            _ = try await SessionTools.exportFile.run(
                ToolArguments(["sessionId": JSON(s.id), "path": "out.json"]), makeContext(store))
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("absolute"))
            #expect(error.message.contains("~/"))
        }
    }

    @Test("Review focus: delete one session, or all; journal rows survive with the link gone")
    func deleteKeepsJournal() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .imported)
        await AgentJournal(store: store).post(.system, "about a", sessionId: a.id)
        await #expect(throws: ToolError.self) {
            try await SessionTools.delete.run(ToolArguments(), makeContext(store))   // must say which
        }
        let r = try await SessionTools.delete.run(ToolArguments(["sessionId": JSON(a.id)]), makeContext(store))
        #expect(r.summary.hasPrefix("Deleted session #\(a.id)"))
        #expect(try await store.sessions().map(\.id) == [b.id])
        let row = try #require(try await store.agentActivity().first { $0.summary == "about a" })
        #expect(row.sessionId == nil)
        _ = try await SessionTools.delete.run(ToolArguments(["all": true]), makeContext(store))
        #expect(try await store.sessions().isEmpty)
        #expect(SessionTools.delete.kind == .destructive)
    }

    @Test("Like the Sessions list, delete refuses the live session while the device is connected")
    func deleteRefusesLive() async throws {
        let store = try LogStore(source: .inMemory)
        let live = try await store.createSession(source: .live)
        let ctx = makeContext(store, fakeUI: FakeUI(value: HostSnapshot(deviceConnected: true, liveSessionId: live.id)))
        do {
            _ = try await SessionTools.delete.run(ToolArguments(["sessionId": JSON(live.id)]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("is the live one"))
            #expect(error.message.contains("sessions_list()"))
        }
        #expect(try await store.sessions().map(\.id) == [live.id])
    }
}
