import Testing
import Foundation
@testable import BeaverCore

/// The Log feed query syntax (D88). The first test is zapp-support's
/// `src/utils/logQuery.test.mts`, case for case, run through the SQL the
/// feed uses.
@Suite("Log query syntax")
struct LogQueryTests {

    /// Does one event match `query`, filtered by `LogStore`'s SQL?
    private func hit(_ query: String, _ message: String, category: String = "App",
                     subsystem: String = "Core", level: LogLevel = .info,
                     data: String? = nil, payloads: Bool = false, regex: Bool = false) async throws -> Bool {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.appendBulk([DecodedEvent(timestampMillis: 1_000, level: level, subsystem: subsystem,
                                                 category: category, message: message,
                                                 dataJSON: data, contextJSON: nil)], to: session.id)
        let filter = Filter(search: query, searchIsRegex: regex, searchPayloads: payloads)
        return try await store.feedSnapshot(sessionId: session.id, filter: filter, limit: 10).events.count == 1
    }

    @Test("zapp-support's cases")
    func zappSupportCases() async throws {
        #expect(try await hit("", "x"))
        #expect(try await hit("foo bar", "bar and foo"))                     // AND
        #expect(try await !hit("foo bar", "foo only"))
        #expect(try await hit(#""foo bar""#, "a foo bar b"))                 // phrase
        #expect(try await !hit(#""foo bar""#, "bar foo"))
        #expect(try await !hit("-foo", "foo"))                               // exclude
        #expect(try await hit("-foo", "bar"))
        #expect(try await !hit("+foo", "bar"))                               // require
        #expect(try await hit("foo OR bar", "bar"))                          // OR
        #expect(try await !hit("foo OR bar baz", "bar"))                     // OR binds tighter
        #expect(try await hit("foo OR bar baz", "bar baz"))
        #expect(try await hit("level:error", "x", level: .error))
        #expect(try await hit("level:warn", "x", level: .warning))
        #expect(try await !hit("level:error", "x"))
        #expect(try await hit("cat:net", "x", category: "Network"))
        #expect(try await !hit("-cat:Network", "x", category: "Network"))
        #expect(try await hit("sub:core", "x"))
        #expect(try await !hit("msg:core", "x"))                             // msg: ignores subsystem
        #expect(try await hit("core", "x"))                                  // plain term searches all fields
        #expect(try await hit(#"/^err\d+/"#, "Err42 boom"))                  // regex
        #expect(try await !hit("-/^err/", "Err42"))
        #expect(try await hit("/[/", "x"))                                   // invalid regex ignored
        #expect(try await hit("foo:bar", "see foo:bar"))                     // unknown prefix = plain
        #expect(try await hit("/var/log", "/var/log/x"))                     // path, not regex
        #expect(try await hit("cat:", "has cat: here"))
    }

    @Test("Parsing: AND of OR-groups, lower-cased, prefixes any case")
    func parse() {
        let q = LogQuery.parse(#"LEVEL:Error foo OR -"Bar Baz" OR sub:/Au+th/ x"#)
        #expect(q.map(\.count) == [1, 3, 1])
        #expect(q[0][0] == .init(field: .level, negated: false, text: "error", regex: nil))
        #expect(q[1][1] == .init(field: .any, negated: true, text: "bar baz", regex: nil))
        #expect(q[1][2].regex == "Au+th")
        #expect(q[1][2].field == .sub)
        // OR is only the upper-case word, and a leading OR joins nothing.
        #expect(LogQuery.parse("or").first?.first?.text == "or")
        #expect(LogQuery.parse("OR a b").map(\.count) == [1, 1])
        // A dropped half-typed regex keeps a pending OR, as in zapp-support.
        #expect(LogQuery.parse("a OR /[/ b").map(\.count) == [2])
    }

    @Test("Problems mark the field: an unclosed quote, a bad regex")
    func problems() {
        #expect(LogQuery.problem(in: #"level:error "foo bar"#) != nil)
        #expect(LogQuery.problem(in: #"""#) != nil)
        #expect(LogQuery.problem(in: "/[/")?.contains("regular expression") == true)
        #expect(LogQuery.problem(in: #"level:error "foo bar" /a+/ /var/log -x"#) == nil)
    }

    @Test("Beaver's additions: payload toggle, * in sub: and cat:, the regex toggle")
    func beaverSpecifics() async throws {
        // Plain terms search data only with the {} toggle (D40); fields never do.
        let data = #"{"url":"player.m3u8"}"#
        #expect(try await !hit("m3u8", "x", data: data))
        #expect(try await hit("m3u8", "x", data: data, payloads: true))
        #expect(try await hit("-m3u8", "x", payloads: true))                 // NULL data survives an exclude
        #expect(try await !hit("msg:m3u8", "x", data: data, payloads: true))
        // `*` globs sub: and cat: (MCP's subsystem filters work that way).
        #expect(try await hit("sub:*auth*", "x", subsystem: "com.app.auth/token"))
        #expect(try await hit("sub:com*token", "x", subsystem: "com.app.auth/token"))
        #expect(try await !hit("msg:a*b", "axb"))
        // LIKE wildcards stay literal inside a query.
        #expect(try await !hit("100%", "1000 done"))
        #expect(try await hit("100% -a_b", "100% done"))
        // With the regex toggle the whole text is one pattern: no syntax.
        #expect(try await hit("level:error|boom", "boom", regex: true))
        #expect(try await !hit("-boom", "boom"))
        #expect(try await hit("-boom", "a -boom b", regex: true))
    }

    @Test("Chips and the level control still AND with the query")
    func combinesWithChips() async throws {
        let store = try LogStore(source: .inMemory)
        let sid = try await store.createSession(source: .live).id
        let events: [(LogLevel, String, String)] = [
            (.error, "auth", "refresh failed"), (.error, "auth", "heartbeat"),
            (.error, "player", "stall"), (.warning, "auth", "retry"),
        ]
        try await store.appendBulk(events.enumerated().map { i, e in
            DecodedEvent(timestampMillis: UInt64(1_000 + i), level: e.0, subsystem: e.1, category: "c",
                         message: e.2, dataJSON: nil, contextJSON: nil)
        }, to: sid)
        func messages(_ f: Filter) async throws -> [String] {
            try await store.feedSnapshot(sessionId: sid, filter: f, limit: 10).events.map(\.message)
        }
        #expect(try await messages(Filter(search: "level:error sub:auth -heartbeat")) == ["refresh failed"])
        #expect(try await messages(Filter(minLevel: .warning, search: "sub:auth -heartbeat")) == ["refresh failed", "retry"])
        #expect(try await messages(Filter(search: "level:error", subsystems: ["player"])) == ["stall"])
    }
}
