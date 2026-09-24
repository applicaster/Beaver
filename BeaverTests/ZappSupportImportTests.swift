import Testing
import Foundation
@testable import BeaverCore

/// zapp-support (the web logger) exports its own files; people attach
/// those to tickets too. Beaver has to open them without dropping lines,
/// and without changing how any Beaver file opens.
///
/// Fixtures are shaped exactly like zapp-support's writers:
/// logs — `JSON.stringify(RawLogEntry[])` (xrayLogTable `exportLogs`);
/// storage — `storageStore.toExportObject()`; HAR — `utils/har.ts buildHar`.
@Suite("zapp-support import")
struct ZappSupportImportTests {

    /// One `RawLogEntry` as zapp-support writes it: `id` and `emitterId`
    /// are extra, `level` is whatever the emitter sent.
    private func zappLine(level: String) -> String {
        #"{"id":"log-1","category":"net","subsystem":"player","level":\#(level),"timestamp":1700000000000,"message":"hi","emitterId":"emitter-1","context":{"build":"1.0"}}"#
    }

    private func decodeOne(level: String) throws -> DecodedEvent {
        let file = Data("[\(zappLine(level: level))]".utf8)
        let events = try EventJSON.decodeExport(file).events
        return try #require(events.first, "a line must never be dropped over its level")
    }

    private func context(_ event: DecodedEvent) throws -> [String: Any] {
        let json = try #require(event.contextJSON)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Levels

    @Test("Known level spellings map onto Beaver's five", arguments: [
        (#""verbose""#, LogLevel.verbose), (#""VERBOSE""#, .verbose),
        (#""trace""#, .verbose), (#""Trace""#, .verbose), (#""""#, .verbose),
        (#""debug""#, .debug), (#""DEBUG""#, .debug),
        (#""info""#, .info), (#""Info""#, .info),
        (#""warning""#, .warning), (#""WARNING""#, .warning),
        (#""warn""#, .warning), (#""WARN""#, .warning),
        (#""error""#, .error), (#""ERROR""#, .error),
        (#""err""#, .error), (#""fatal""#, .error), (#""FATAL""#, .error),
        (#""0""#, .verbose), (#""1""#, .debug), (#""2""#, .info),
        (#""3""#, .warning), (#""4""#, .error),
        ("0", .verbose), ("1", .debug), ("2", .info), ("3", .warning), ("4", .error),
    ])
    func knownLevels(raw: String, expected: LogLevel) throws {
        let event = try decodeOne(level: raw)
        #expect(event.level == expected)
        #expect(try context(event)["originalLevel"] == nil, "a recognised level is not an oddity")
    }

    @Test("An unknown level becomes info and keeps the raw value", arguments: [
        (#""off""#, "off"), (#""unknown""#, "unknown"), (#""critical""#, "critical"),
    ])
    func unknownStringLevel(raw: String, original: String) throws {
        let event = try decodeOne(level: raw)
        #expect(event.level == .info)
        let ctx = try context(event)
        #expect(ctx["originalLevel"] as? String == original)
        #expect(ctx["build"] as? String == "1.0", "existing context is kept")
    }

    @Test("An out-of-range numeric level becomes info and keeps the raw value")
    func unknownNumericLevel() throws {
        let event = try decodeOne(level: "100")
        #expect(event.level == .info)
        #expect(try context(event)["originalLevel"] as? Int == 100)
    }

    @Test("A boolean level is not read as 0 / 1")
    func booleanLevelIsUnknown() throws {
        let event = try decodeOne(level: "true")
        #expect(event.level == .info)
        #expect(try context(event)["originalLevel"] as? Bool == true)
    }

    @Test("A line with no level still opens, as info")
    func missingLevel() throws {
        let file = Data(#"[{"subsystem":"a","timestamp":1,"message":"m"}]"#.utf8)
        let event = try #require(try EventJSON.decodeExport(file).events.first)
        #expect(event.level == .info)
        #expect(event.contextJSON == nil, "nothing to record when there was no level")
    }

    @Test("An unknown level with no context creates one")
    func unknownLevelWithoutContext() throws {
        let file = Data(#"[{"subsystem":"a","timestamp":1,"level":"off","message":"m"}]"#.utf8)
        let event = try #require(try EventJSON.decodeExport(file).events.first)
        #expect(try context(event)["originalLevel"] as? String == "off")
    }

    @Test("A whole zapp-support log export opens with its fields intact")
    func zappLogExport() throws {
        let file = Data(#"""
        [
          {"id":"log-1","category":"net","subsystem":"player","level":"warn",
           "timestamp":1700000000000,"message":"slow","data":{"ms":900},
           "emitterId":"e1","context":{"build":"1.0"}},
          {"id":"log-2","category":"Unknown","subsystem":"auth","level":"error",
           "timestamp":1700000000001,"message":"boom"}
        ]
        """#.utf8)

        let events = try EventJSON.decodeExport(file).events

        #expect(events.map(\.message) == ["slow", "boom"])
        #expect(events.map(\.level) == [.warning, .error])
        #expect(events[0].category == "net")
        #expect(events[0].dataJSON == #"{"ms":900}"#)
        #expect(events[0].contextJSON == #"{"build":"1.0"}"#)
    }

    // MARK: Storage

    /// `storageStore.toExportObject()`: storage type → namespace → key.
    /// Keys with no namespace are grouped under `"root"`; stringified
    /// objects are written unwrapped.
    private let zappStorage = Data(#"""
    {
      "local":   { "applicaster.v2": { "uuid": "u-1", "flags": {"premium": true} },
                   "root": { "lastLoginAt": "1700000000" } },
      "session": { "applicaster.v2": { "app_name": "Demo" } },
      "secure":  { "root": { "authToken": "synthetic-token" } }
    }
    """#.utf8)

    private func layer(_ json: String?) throws -> [String: Any] {
        let json = try #require(json)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("A zapp-support storage export opens as storage snapshots")
    func zappStorageExport() throws {
        let back = try EventJSON.decodeExport(zappStorage)

        #expect(back.events.isEmpty)
        #expect(back.network.isEmpty)
        #expect(Set(back.storage.keys) == [.local, .session, .keychain])

        let session = try layer(back.storage[.session])
        #expect((session["applicaster.v2"] as? [String: Any])?["app_name"] as? String == "Demo")

        let local = try layer(back.storage[.local])
        #expect((local["applicaster.v2"] as? [String: Any])?["uuid"] as? String == "u-1")
    }

    @Test("zapp-support's 'root' group becomes plain top-level keys again")
    func zappRootNamespaceUnwraps() throws {
        let back = try EventJSON.decodeExport(zappStorage)

        // The SDK's own wire shape for an ungrouped key, which the
        // Storages screen already shows as a plain key.
        let local = try layer(back.storage[.local])
        #expect(local["root"] == nil)
        #expect((local["lastLoginAt"] as? [String: Any])?["undefined"] as? String == "1700000000")

        let records = StorageRecord.parseTopLevel(try #require(back.storage[.keychain]))
        #expect(records.map(\.key) == ["authToken"])
        #expect(records.first?.valueText == "synthetic-token")
    }

    @Test("An object that is not storage is not mistaken for it", arguments: [
        #"{}"#,
        #"{"local":"not an object"}"#,
        #"{"local":{},"somethingElse":{}}"#,
        #"{"log":{"entries":[]}}"#,
    ])
    func notStorage(json: String) throws {
        let back = try EventJSON.decodeExport(Data(json.utf8))
        #expect(back.storage.isEmpty)
        #expect(back.events.isEmpty)
    }

    // MARK: HAR

    @Test("A zapp-support HAR opens into the Network tab")
    func zappHAR() throws {
        // `buildHar` output, one success and one transport failure.
        let har = Data(#"""
        {"log":{"version":"1.2","creator":{"name":"Zapp Support","version":"1.0"},"entries":[
          {"startedDateTime":"2023-11-14T22:13:20.000Z","time":250,
           "request":{"method":"POST","url":"https://api.example.com/v1/feed?page=2","httpVersion":"HTTP/1.1",
             "cookies":[],"headers":[{"name":"Content-Type","value":"application/json"}],
             "queryString":[{"name":"page","value":"2"}],
             "postData":{"mimeType":"application/json","text":"{\"q\":1}"},"headersSize":-1,"bodySize":7},
           "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","cookies":[],
             "headers":[{"name":"Content-Type","value":"application/json"}],
             "content":{"size":13,"mimeType":"application/json","text":"{\"items\":[]}"},
             "redirectURL":"","headersSize":-1,"bodySize":13},
           "cache":{},"timings":{"send":0,"wait":250,"receive":0}},
          {"startedDateTime":"2023-11-14T22:13:21.000Z","time":0,
           "request":{"method":"GET","url":"https://api.example.com/down","httpVersion":"HTTP/1.1",
             "cookies":[],"headers":[],"queryString":[],"headersSize":-1,"bodySize":0},
           "response":{"status":0,"statusText":"","httpVersion":"HTTP/1.1","cookies":[],"headers":[],
             "content":{"size":0,"mimeType":"application/octet-stream"},
             "redirectURL":"","headersSize":-1,"bodySize":0},
           "cache":{},"timings":{"send":0,"wait":0,"receive":0},"_error":"The Internet connection appears to be offline."}
        ]}}
        """#.utf8)

        // Same order MainWindow.handleImport uses: Beaver first, then HAR.
        let asExport = try EventJSON.decodeExport(har)
        #expect(asExport.events.isEmpty && asExport.storage.isEmpty && asExport.network.isEmpty)

        let entries = HARExport.decode(har)
        #expect(entries.count == 2)
        #expect(entries[0].url == "https://api.example.com/v1/feed?page=2")
        #expect(entries[0].method == "POST")
        #expect(entries[0].status == 200)
        #expect(entries[0].requestBody == #"{"q":1}"#)
        #expect(entries[0].responseBody == #"{"items":[]}"#)
        #expect(entries[0].startMillis == 1_700_000_000_000)
        #expect(entries[0].durationMillis == 250)
        #expect(entries[1].status == nil)
        #expect(entries[1].error == "The Internet connection appears to be offline.")
    }

    // MARK: Legacy Beaver shapes, unchanged

    @Test("Beaver's own storage key is not rewritten")
    func beaverStorageKeepsRootNamespace() throws {
        // A real SDK namespace called "root" must survive: the
        // zapp-support unwrapping applies to zapp-support files only.
        let file = Data(#"{"events":[],"storage":{"local":{"root":{"k":"v"}}}}"#.utf8)
        let local = try layer(try EventJSON.decodeExport(file).storage[.local])
        #expect((local["root"] as? [String: Any])?["k"] as? String == "v")
    }

    @Test("Events given as JSON strings still open")
    func stringEncodedEvents() throws {
        let file = Data(#"{"events":["{\"subsystem\":\"a\",\"timestamp\":1,\"level\":\"info\",\"message\":\"m\"}"]}"#.utf8)
        let back = try EventJSON.decodeExport(file)
        #expect(back.events.map(\.message) == ["m"])
        #expect(back.events.first?.contextJSON == nil)
    }

    @Test("A Beaver file with every section decodes exactly as before")
    func fullBeaverFile() throws {
        let file = Data(#"""
        {"events":[
           {"subsystem":"player","timestamp":1700000000000,"level":"warning","message":"w",
            "category":"net","data":{"a":1},"context":{"b":2}},
           {"subsystem":"auth","timestamp":1700000000001,"level":3,"message":"n"}],
         "storage":{"session":{"applicaster.v2":{"app_name":"Demo"}},"secure":{"authToken":"synthetic"}},
         "network":[{"url":"https://a.example/one","method":"GET","status":200,"timestamp":1700000000000}]}
        """#.utf8)

        let back = try EventJSON.decodeExport(file)

        #expect(back.events.map(\.level) == [.warning, .warning])
        #expect(back.events[0].dataJSON == #"{"a":1}"#)
        #expect(back.events[0].contextJSON == #"{"b":2}"#)
        #expect(back.events[1].contextJSON == nil)
        #expect(try layer(back.storage[.keychain])["authToken"] as? String == "synthetic")
        #expect(back.storage[.local] == nil)
        #expect(back.network.map(\.url) == ["https://a.example/one"])
    }
}
