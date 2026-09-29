import Testing
import Foundation
@testable import BeaverCore

@Suite("Session compare (D81)")
struct SessionCompareTests {

    @Test("Patterns hide what varies between runs", arguments: [
        ("Loaded 42 items in 118ms", "Loaded <n> items in <n>ms"),
        ("Loaded 7 items in 95ms", "Loaded <n> items in <n>ms"),
        ("SDK 4.6.0 ready, ratio 1.5", "SDK <n> ready, ratio <n>"),
        ("user 3F2504E0-4F89-11D3-9A0C-0305E82C3301 signed in", "user <uuid> signed in"),
        ("at 2026-09-28T12:34:56.789Z and 09:15:02", "at <time> and <time>"),
        ("object 0x7fa3b2 hash 5f3a9c2e1b", "object <hex> hash <hex>"),
        ("GET https://api.x.io/feed?page=2&token=abc#top done", "GET https://api.x.io/feed?page=<*>&token=<*>#top done"),
        ("no numbers here", "no numbers here"),
        ("api/v2 deadbeef", "api/v<n> deadbeef"),
        ("on 2026-09-28 12:00:01+02:00 ok", "on <time> ok"),
        ("short 5f3a, 1,000 rows, 0xZZ", "short <n>f<n>a, <n> rows, <n>xZZ"),
        ("naïve 42 ✓", "naïve <n> ✓"),
    ])
    func pattern(input: String, expected: String) {
        #expect(SessionCompare.pattern(input) == expected)
    }

    @Test("Request keys drop the query and ids in the path")
    func requestKey() throws {
        func key(_ url: String) throws -> String {
            SessionCompare.requestKey(try #require(NetworkEntry.parse(#"{"url":"\#(url)","method":"get"}"#, fallbackMillis: 0)))
        }
        #expect(try key("https://api.x.io/v2/users/42/posts?page=3") == "GET api.x.io/v2/users/:id/posts")
        #expect(try key("https://api.x.io/items/3f2504e0-4f89-11d3-9a0c-0305e82c3301") == "GET api.x.io/items/:id")
        #expect(try key("https://api.x.io/media/5f3a9c2e1b/play") == "GET api.x.io/media/:id/play")
        #expect(try key("https://api.x.io/t/AbCdEf123456GhIjKl") == "GET api.x.io/t/:id")
        #expect(try key("https://api.x.io/feed") == "GET api.x.io/feed")
    }

    private func sessions() async throws -> (LogStore, Int64, Int64) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live).id
        let b = try await store.createSession(source: .live).id
        // Two versions of one app: only such sessions compare.
        try await store.applyHandshake(ClientHandshake(appPackage: "com.x.app", version: "4.5"), to: a)
        try await store.applyHandshake(ClientHandshake(appPackage: "com.x.app", version: "4.6"), to: b)
        return (store, a, b)
    }

    @Test("Only sessions of one app compare: bundle id, else app name")
    func sameApp() async throws {
        func s(_ package: String?, _ name: String?) -> Session {
            Session(id: 1, startedAt: Date(), source: .live, appName: name, appPackage: package)
        }
        #expect(SessionCompare.sameApp(s("com.a", "Anton"), s("com.a", "Other name")))
        #expect(!SessionCompare.sameApp(s("com.a", "App"), s("com.b", "App")))
        #expect(SessionCompare.sameApp(s(nil, "River"), s("com.r", "River")))
        #expect(!SessionCompare.sameApp(s(nil, "Anton"), s(nil, "Ruslan")))
        #expect(!SessionCompare.sameApp(s(nil, nil), s(nil, nil)))

        let store = try LogStore(source: .inMemory)
        let anton = try await store.createSession(source: .live).id
        let ruslan = try await store.createSession(source: .live).id
        try await store.applyHandshake(ClientHandshake(appPackage: "com.anton"), to: anton)
        try await store.applyHandshake(ClientHandshake(appPackage: "com.ruslan"), to: ruslan)
        await #expect(throws: SessionCompare.DifferentApps.self) {
            try await SessionCompare.run(store: store, a: anton, b: ruslan)
        }
    }

    @Test("Logs: patterns only in one session, warnings and errors per subsystem")
    func logs() async throws {
        let (store, a, b) = try await sessions()
        try await seed(store, session: a, [
            (.info, "feed", "", "Loaded 42 items in 118ms"),
            (.info, "player", "", "Playback started"),
            (.warning, "player", "", "Buffer low 12%"),
        ])
        try await seed(store, session: b, [
            (.info, "feed", "", "Loaded 7 items in 95ms"),
            (.error, "auth", "", "Token refresh failed: 401"),
            (.error, "auth", "", "Token refresh failed: 403"),
            (.warning, "player", "", "Buffer low 3%"),
            (.warning, "player", "", "Buffer low 1%"),
        ])
        let logs = try #require(try await SessionCompare.run(store: store, a: a, b: b).logs)
        #expect(logs.onlyInA.map(\.pattern) == ["Playback started"])
        let only = try #require(logs.onlyInB.first)
        #expect(logs.onlyInB.count == 1)
        #expect((only.subsystem, only.pattern, only.level, only.count) == ("auth", "Token refresh failed: <n>", .error, 2))
        #expect(logs.levels.map { "\($0.subsystem) \($0.level.rawValue) \($0.a)→\($0.b)" }
                == ["auth error 0→2", "player warning 1→2"])
        #expect(logs.levels.allSatisfy { $0.increased })
        #expect(!logs.capped)
    }

    @Test("Network: only in one, status class changed, median duration changed")
    func network() async throws {
        let (store, a, b) = try await sessions()
        func record(_ session: Int64, _ path: String, status: Int?, ms: Int, method: String = "GET") async throws {
            let status = status.map { #","status":\#($0)"# } ?? #","error":"offline""#
            let p = #"{"url":"https://api.x.io\#(path)","method":"\#(method)"\#(status),"timing":{"startTime":1,"duration":\#(ms)}}"#
            try await store.recordNetworkEntry(try #require(NetworkCapture(p, fallbackMillis: 0)), sessionId: session)
        }
        try await record(a, "/feed/1", status: 200, ms: 100)
        try await record(a, "/feed/2", status: 200, ms: 120)
        try await record(a, "/token", status: 200, ms: 80, method: "POST")
        try await record(a, "/legacy", status: 200, ms: 50)
        try await record(b, "/feed/9", status: 200, ms: 900)
        try await record(b, "/token", status: 401, ms: 90, method: "POST")
        try await record(b, "/token", status: nil, ms: 90, method: "POST")
        try await record(b, "/new?x=1", status: 200, ms: 10)

        let net = try #require(try await SessionCompare.run(store: store, a: a, b: b, sections: [.network]).network)
        #expect(net.onlyInA.map(\.key) == ["GET api.x.io/legacy"])
        #expect(net.onlyInB.map(\.key) == ["GET api.x.io/new"])
        #expect(net.statusChanged.map(\.key) == ["POST api.x.io/token"])
        #expect(net.statusChanged.first?.b.statusText == "4xx×1, Failed×1")
        #expect(net.durationChanged.map { "\($0.key) \($0.a.medianMs!)→\($0.b.medianMs!)" } == ["GET api.x.io/feed/:id 110→900"])
    }

    @Test("sessions_compare: summary, lists, Next, sections, errors")
    func tool() async throws {
        let (store, a, b) = try await sessions()
        try await seed(store, session: a, [(.info, "app", "", "Started in 120ms")])
        try await seed(store, session: b, [(.info, "app", "", "Started in 95ms"), (.error, "app", "", "Crash 0x1f")])
        let ctx = makeContext(store)
        let r = try await SessionTools.compare.run(ToolArguments(["a": JSON(a), "b": JSON(b),
                                                                  "sections": ["logs", "storage"]]), ctx)
        #expect(r.summary.hasPrefix("Session #\(a) vs #\(b): logs: 0 pattern(s) only in #\(a), 1 only in #\(b)"))
        #expect(r.summary.contains("storage: 0 key(s) differ (no storage on either side)"))
        #expect(r.body.contains("error app: Crash <hex> ×1"))
        #expect(r.next.contains { $0.hasPrefix("logs_get(ids: [") })
        #expect(r.structured["network"] == nil)

        let bad: [([String: JSON], String)] = [
            (["a": JSON(a)], "a and b are required"),
            (["a": JSON(a), "b": JSON(a)], "pick two"),
            (["a": JSON(a), "b": 999], "No session #999"),
            (["a": JSON(a), "b": JSON(b), "sections": ["nope"]], "Unknown section"),
        ]
        for (args, needle) in bad {
            do {
                _ = try await SessionTools.compare.run(ToolArguments(args), ctx)
                #expect(Bool(false), "Expected ToolError for \(args)")
            } catch let error as ToolError {
                #expect(error.message.contains(needle), "\(error.message)")
            }
        }
    }

    @Test("Storage: each layer's latest snapshot, A → B; a layer on one side only says so")
    func storage() async throws {
        let (store, a, b) = try await sessions()
        try await store.recordStorageSnapshot(sessionId: a, namespace: .local, dataJSON:
            #"{"applicaster.v2":{"token":"t1","plan":"free"},"player":"{\"quality\":\"auto\"}"}"#)
        try await store.recordStorageSnapshot(sessionId: b, namespace: .local, dataJSON:
            #"{"applicaster.v2":{"plan":"premium","userId":"u1"},"player":"{\"quality\":\"1080p\"}"}"#)
        try await store.recordStorageSnapshot(sessionId: b, namespace: .keychain, dataJSON: #"{"applicaster.v2":{"authToken":"x"}}"#)
        let r = try await SessionCompare.run(store: store, a: a, b: b, sections: [.storage])
        let local = try #require(r.storage?.layers.first { $0.layer == .local })
        #expect(Set(local.changes.map { "\($0.kind.rawValue) \($0.path)" })
                == ["removed applicaster.v2/token", "changed applicaster.v2/plan", "added applicaster.v2/userId", "changed player"])
        #expect(local.changes.first { $0.path == "player" }?.fields.map(\.path) == ["quality"])
        let keychain = try #require(r.storage?.layers.first { $0.layer == .keychain })
        #expect(keychain.missing == "only #\(b) has a Keychain snapshot")
        #expect(r.storage?.layers.contains { $0.layer == .session } == false)
    }

    @Test("App Info: versions and plugins that differ; session ids aren't a finding")
    func appInfo() async throws {
        let (store, a, b) = try await sessions()
        func storage(_ version: String, _ session: String) -> String {
            #"{"applicaster.v2":{"app_name":"River","version_name":"\#(version)","sdk_version":"14.1","session_id":"\#(session)"},"login-plugin":{"k":"v"}}"#
        }
        try await store.recordStorageSnapshot(sessionId: a, namespace: .session, dataJSON: storage("4.5", "s1"))
        try await store.recordStorageSnapshot(sessionId: b, namespace: .session, dataJSON:
            storage("4.6", "s2").replacingOccurrences(of: #""login-plugin""#, with: #""iap-plugin""#))
        let r = try await SessionCompare.run(store: store, a: a, b: b, sections: [.appInfo])
        let info = try #require(r.appInfo)
        #expect(info.values == [SessionCompare.ValueChange(label: "App version", a: "4.5", b: "4.6")])
        #expect(info.plugins == [SessionCompare.PluginChange(id: "iap-plugin", a: nil, b: ""),
                                 SessionCompare.PluginChange(id: "login-plugin", a: "", b: nil)])
    }

    /// Opt-in, like FeedBenchmark: BEAVER_BENCH=1 swift test --filter SessionCompareTests
    @Test("100k events per session compare quickly", .enabled(if: ProcessInfo.processInfo.environment["BEAVER_BENCH"] != nil))
    func benchmark() async throws {
        let (store, a, b) = try await sessions()
        for (sid, offset) in [(a, 0), (b, 7)] {
            for chunk in 0..<10 {
                try await store.appendBulk((0..<10_000).map { i in
                    let n = chunk * 10_000 + i + offset
                    return DecodedEvent(timestampMillis: UInt64(n), level: n % 50 == 0 ? .error : .info,
                                        subsystem: "sub\(n % 12)", category: "",
                                        message: "request \(n) finished in \(n % 300)ms id \(UUID().uuidString) kind\(n % 400 == 0 ? "X" : "")",
                                        dataJSON: nil, contextJSON: nil)
                }, to: sid)
            }
        }
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await SessionCompare.run(store: store, a: a, b: b, sections: [.logs])
        }
        print("SessionCompare logs, 2 × 100k events: \(elapsed)")
        #expect(elapsed < .seconds(10))
    }
}
