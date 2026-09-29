import Testing
import Foundation
@testable import BeaverCore

@Suite("Issues (D95)")
struct IssuesTests {

    private func session(_ store: LogStore, package: String? = "com.x.app", name: String? = nil) async throws -> Int64 {
        let id = try await store.createSession(source: .live).id
        if package != nil || name != nil {
            try await store.applyHandshake(ClientHandshake(appPackage: package, appName: name), to: id)
        }
        return id
    }

    private let rows: [(LogLevel, String, String, String)] = [
        (.info, "feed", "", "Loaded 42 items"),
        (.warning, "player", "", "Buffer low 12%"),
        (.error, "auth", "", "Token refresh failed: 401"),
        (.warning, "player", "", "Buffer low 7%"),
        (.error, "auth", "", "Token refresh failed: 403"),
        (.warning, "auth", "", "Token refresh failed: 500"),
        (.error, "net", "", "Request 3F2504E0-4F89-11D3-9A0C-0305E82C3301 timed out"),
    ]

    @Test("Groups warnings and errors by subsystem and Compare's pattern")
    func grouping() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        try await seed(store, session: s, rows)
        let report = try await store.issues(sessionId: s)
        let byKey = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.signature, $0) })
        #expect(report.groups.count == 3)
        #expect(!report.capped)
        let auth = try #require(byKey[Issues.signature(subsystem: "auth", pattern: "Token refresh failed: <n>")])
        #expect(auth.level == .error)
        #expect(auth.count == 3)
        #expect(auth.example == "Token refresh failed: 401")
        #expect(auth.firstId < auth.lastId)
        #expect(byKey[Issues.signature(subsystem: "player", pattern: "Buffer low <n>%")]?.level == .warning)
        #expect(byKey[Issues.signature(subsystem: "net", pattern: "Request <uuid> timed out")]?.count == 1)

        // A signature means the same in Compare (D81): same subsystem, pattern, count.
        let compare = try await store.messagePatterns(sessionId: s, limit: 100)
            .filter { $0.level >= .warning }
        #expect(Set(compare.map { Issues.signature(subsystem: $0.subsystem, pattern: $0.pattern) + "×\($0.count)" })
                == Set(report.groups.map { $0.signature + "×\($0.count)" }))

        let errors = try await store.issues(sessionId: s, minLevel: .error)
        #expect(errors.groups.map(\.count).sorted() == [1, 2])
        #expect(errors.errors == 2 && errors.warnings == 0)

        let capped = try await store.issues(sessionId: s, limit: 2)
        #expect(capped.groups.count == 2 && capped.capped)
        #expect(capped.groups.first?.level == .error)
    }

    @Test("Histogram: counts in 30 buckets over the session's span")
    func histogram() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        try await seed(store, session: s, [(.info, "app", "", "start")], startMillis: 0)
        try await seed(store, session: s, [(.error, "app", "", "boom 1"), (.error, "app", "", "boom 2")], startMillis: 10)
        try await seed(store, session: s, [(.error, "app", "", "boom 3")], startMillis: 1_500)
        try await seed(store, session: s, [(.info, "app", "", "end")], startMillis: 2_999)
        let g = try #require(try await store.issues(sessionId: s).groups.first)
        #expect(g.histogram.count == Issues.buckets)
        #expect(g.histogram[0] == 2)
        #expect(g.histogram[15] == 1)
        #expect(g.histogram.reduce(0, +) == 3)
        #expect(Issues.histogram("0:1,29:2,40:9") == [1] + Array(repeating: 0, count: 28) + [2])
    }

    @Test("The group's filter shows exactly its events, first one first")
    func filterReproducesGroup() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        try await seed(store, session: s, rows + [(.info, "auth", "", "Token refresh failed: 200"),
                                                  (.error, "other", "", "Token refresh failed: 1")])
        for minLevel in [LogLevel.warning, .error] {
            for g in try await store.issues(sessionId: s, minLevel: minLevel).groups {
                let f = g.filter(minLevel: minLevel)
                let page = try await store.eventPage(sessionId: s, filter: f, limit: 100, newestFirst: false)
                #expect(page.total == g.count, "\(g.signature) at \(minLevel)")
                #expect(page.events.first?.id == g.firstId)
                #expect(page.events.last?.id == g.lastId)
            }
        }
        // A stored filter from before `pattern` existed still restores.
        let old = #"{"minLevel":"error","searchIsRegex":false,"excludeIsRegex":false,"searchPayloads":false,"subsystems":[],"excludedSubsystems":[],"categories":[],"excludedCategories":[]}"#
        #expect(Filter.restore(from: Data(old.utf8))?.minLevel == .error)
    }

    @Test("Ignore is per app — bundle id, else name — and reaches its later sessions")
    func ignore() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await session(store, package: "com.x.app", name: "X")
        let b = try await session(store, package: "com.x.app", name: "X renamed")
        let other = try await session(store, package: "com.y.app", name: "X")
        let byName = try await session(store, package: nil, name: "X")
        let unknown = try await session(store, package: nil, name: nil)
        for s in [a, b, other, byName, unknown] { try await seed(store, session: s, rows) }

        try await store.setIssueIgnored(true, subsystem: "player", pattern: "Buffer low <n>%", sessionId: a)
        func ignored(_ s: Int64) async throws -> [String] {
            try await store.issues(sessionId: s).groups.filter(\.ignored).map(\.subsystem)
        }
        #expect(try await ignored(a) == ["player"])
        #expect(try await ignored(b) == ["player"])
        #expect(try await ignored(byName) == ["player"])
        #expect(try await ignored(other) == [])
        #expect(try await ignored(unknown) == [])
        #expect(try await store.issues(sessionId: a).shown.count == 2)

        await #expect(throws: Issues.UnknownApp.self) {
            try await store.setIssueIgnored(true, subsystem: "auth", pattern: "x", sessionId: unknown)
        }
        try await store.setIssueIgnored(false, subsystem: "player", pattern: "Buffer low <n>%", sessionId: b)
        #expect(try await ignored(a) == [])
    }

    @Test("Sorts: newest, most frequent, errors first")
    func sorting() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        try await seed(store, session: s, rows)
        let groups = try await store.issues(sessionId: s).groups
        #expect(Issues.Sort.newest.sorted(groups).map(\.subsystem) == ["net", "auth", "player"])
        #expect(Issues.Sort.frequent.sorted(groups).map(\.subsystem) == ["auth", "player", "net"])
        #expect(Issues.Sort.errorsFirst.sorted(groups).map(\.subsystem) == ["auth", "net", "player"])
        #expect(Issues.parse(signature: groups[0].signature)?.pattern == groups[0].pattern)
    }

    @Test("issues_list and issues_ignore")
    func tools() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        try await seed(store, session: s, rows)
        let ctx = makeContext(store)
        let list = try await IssueTools.list.run(ToolArguments(["sessionId": JSON(s)]), ctx)
        #expect(list.summary.contains("3 warning/error issue(s) — 2 error, 1 warning"))
        #expect(list.body.hasPrefix("ERROR ×3 auth: Token refresh failed: <n>"))
        let first = try #require(list.structured["issues"]?.array?.first)
        #expect(first["signature"] == .string("auth ␟ Token refresh failed: <n>"))
        #expect(first["filter"]?["pattern"] == "Token refresh failed: <n>")
        let firstId = try #require(first["firstId"]?.int64)
        #expect(list.next.first == "logs_get(ids: [\(firstId)])")
        #expect(list.next.contains { $0.hasPrefix("logs_query(sessionId: \(s), filter: {") && $0.contains(#""pattern":"Token refresh failed: <n>""#) })

        // The Next filter, as an agent would send it, finds the group's events.
        let query = try await LogTools.query.run(
            ToolArguments(["sessionId": JSON(s), "filter": try #require(first["filter"])]), ctx)
        #expect(query.structured["total"] == 3)

        let ignore = try await IssueTools.ignore.run(
            ToolArguments(["signature": "auth ␟ Token refresh failed: <n>", "sessionId": JSON(s)]), ctx)
        #expect(ignore.summary.hasPrefix("Ignored auth: Token refresh failed: <n> for com.x.app"))
        let after = try await IssueTools.list.run(ToolArguments(["sessionId": JSON(s)]), ctx)
        #expect(after.summary.contains("2 warning/error issue(s)"))
        #expect(after.summary.contains("1 ignored"))
        let all = try await IssueTools.list.run(ToolArguments(["sessionId": JSON(s), "includeIgnored": true]), ctx)
        #expect(all.body.contains("[ignored] ERROR ×3 auth"))

        do {
            _ = try await IssueTools.ignore.run(ToolArguments(["signature": "no separator"]), ctx)
            #expect(Bool(false), "Expected ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("Example: issues_ignore("))
        }
    }

    @Test("ui_show and ui_state know the Issues tab")
    func tab() throws {
        #expect(try UITools.tab("issues") == .issues)
        #expect(try UITools.tab("Problems") == .issues)
        #expect(UITab.issues.title == "Issues")
        var ui = UIState()
        ui.tab = .issues
        ui.sessionId = 3
        #expect(UITools.view(ui) == "Issues, session #3")
    }
}
