import Testing
import Foundation
@testable import BeaverCore

@Suite("App build from app.info and build.plugins (D85)")
struct AppBuildTests {

    static let info: JSON = [
        "bundleId": "com.a.river", "packageName": "com.a.river", "version": "2.8", "buildNumber": "812",
        "layoutId": "lay-1", "uuid": "u-1", "sdkVersion": "15.0.1", "quickbrickVersion": "7.4.0",
        "platform": "iOS 18.6", "debugEnvironment": false, "flavor": "store",
    ]
    static let plugins: JSON = [
        ["id": "hero", "name": "Hero cell", "version": "2.1"], ["id": "player", "version": "5.0"],
        ["id": "nover"], ["name": "no id"],
    ]

    /// A tools/call result as the native MCP server sends it.
    static func result(_ value: JSON) -> JSON { ["content": [["type": "text", "text": .string(value.text)]]] }

    @Test("Store: one answer per session, the latest wins, gone with its session")
    func storeRoundTrip() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        #expect(try await store.appBuild(sessionId: s.id) == nil)
        try await store.recordAppBuild(sessionId: s.id, json: "1", at: Date(timeIntervalSince1970: 10))
        try await store.recordAppBuild(sessionId: s.id, json: "2", at: Date(timeIntervalSince1970: 20))
        let row = try #require(try await store.appBuild(sessionId: s.id))
        #expect(row.json == "2")
        #expect(row.fetchedAt == Date(timeIntervalSince1970: 20))
        try await store.deleteSessions(ids: [s.id])
        #expect(try await store.appBuild(sessionId: s.id) == nil)
    }

    @Test("Parse: app.info rows (iOS's duplicate packageName dropped, new fields kept), build.plugins, the note")
    func parse() throws {
        let b = try #require(AppBuild(json: AppBuild.stored(appInfo: Self.info, buildPlugins: Self.plugins, note: nil),
                                      fetchedAt: Date()))
        #expect(b.rows.map(\.label) == ["Bundle id", "App version", "Build number", "SDK version", "QuickBrick version",
                                        "Layout id", "UUID", "Platform", "Debug environment", "flavor"])
        #expect(b.rows.allSatisfy { $0.source == "app.info" })
        #expect(b.plugins?.map(\.id) == ["hero", "player", "nover"])
        #expect(b.plugins?.first == AppInfo.Plugin(id: "hero", version: "2.1", name: "Hero cell"))
        #expect(b.pluginsNote == nil)

        let old = try #require(AppBuild(json: AppBuild.stored(appInfo: nil, buildPlugins: nil, note: "older X-Ray"),
                                        fetchedAt: Date()))
        #expect(old.rows.isEmpty)
        #expect(old.plugins == nil)
        #expect(old.pluginsNote == "older X-Ray")
        #expect(AppBuild(json: "[]", fetchedAt: Date()) == nil)
    }

    @Test("A tools/call result: text or structuredContent, a wrapped array, null, an unknown tool, an error")
    func answers() {
        #expect(AppBuild.answer(fromCallResult: Self.result(Self.plugins)) == .value(Self.plugins))
        #expect(AppBuild.answer(fromCallResult: ["structuredContent": ["result": Self.plugins]]) == .value(Self.plugins))
        #expect(AppBuild.answer(fromCallResult: ["structuredContent": Self.info]) == .value(Self.info))
        #expect(AppBuild.answer(fromCallResult: Self.result(.null)) == .value(.null))
        #expect(AppBuild.answer(fromCallResult: ["isError": true, "content": [["type": "text", "text": "Unknown tool 'build.plugins'"]]]) == .noTool)
        #expect(AppBuild.answer(fromCallResult: ["isError": true, "content": [["type": "text", "text": "boom"]]]) == .failed("boom"))
        #expect(AppBuild.answer(fromCallResult: ["content": [["type": "text", "text": "not json"]]]) == .failed("not JSON"))
    }

    /// Runs `fetch` against a fake app answering `tools/call` by tool name.
    private func fetch(_ answers: @escaping @Sendable (String) throws -> JSON) async throws -> AppBuild? {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let device = FakeDevice(onMCP: { _, params in try answers(params["name"]?.string ?? "") })
        await AppBuild.fetch(from: device, store: store, sessionId: s.id, retryAfter: .milliseconds(1))
        return try await store.appBuild(sessionId: s.id).flatMap { AppBuild(json: $0.json, fetchedAt: $0.fetchedAt) }
    }

    @Test("Fetch: both tools; an older CLI (null); an older X-Ray (unknown tool); no MCP stores nothing")
    func fetching() async throws {
        let both = try #require(try await fetch { $0 == "app.info" ? Self.result(Self.info) : Self.result(Self.plugins) })
        #expect(both.plugins?.count == 3)
        #expect(both.rows.first?.value == "com.a.river")

        let oldCLI = try #require(try await fetch { $0 == "app.info" ? Self.result(Self.info) : Self.result(.null) })
        #expect(oldCLI.plugins == nil)
        #expect(oldCLI.pluginsNote?.contains("QuickBrick CLI") == true)

        let unknown: JSON = ["isError": true, "content": [["type": "text", "text": "Unknown tool"]]]
        let oldXRay = try #require(try await fetch { _ in unknown })
        #expect(oldXRay.rows.isEmpty)
        #expect(oldXRay.pluginsNote?.contains("older X-Ray") == true)

        #expect(try await fetch { _ in throw DeviceMCPError.unsupported } == nil)
    }

    @Test("Identity: the app's value wins; a different storage value stays, labelled")
    func merge() throws {
        let b = try #require(AppBuild(json: AppBuild.stored(appInfo: Self.info, buildPlugins: nil, note: nil), fetchedAt: Date()))
        let identity = [
            InfoRow(label: "App name", value: "River", source: "storage: session/applicaster.v2/app_name"),
            InfoRow(label: "Build number", value: "800", source: "storage: session/applicaster.v2/build_version"),
            InfoRow(label: "SDK version", value: "15.0.1", source: "storage: session/applicaster.v2/sdk_version"),
        ]
        #expect(AppBuild.merge(identity, b).map { "\($0.label)=\($0.value)" } == [
            "App name=River", "Build number=812", "Build number (storage)=800", "SDK version=15.0.1",
            "Bundle id=com.a.river", "App version=2.8", "QuickBrick version=7.4.0", "Layout id=lay-1",
        ])
    }

    @Test("Plugin rows: same, rebuild needed, only in one; unknown versions aren't a difference; no build list → not confirmed")
    func rows() {
        let build = [AppInfo.Plugin(id: "hero", version: "2.1"), AppInfo.Plugin(id: "player", version: "5.0"),
                     AppInfo.Plugin(id: "rater", version: "1.0"), AppInfo.Plugin(id: "nover", version: nil)]
        let zapp = [AppInfo.Plugin(id: "hero", version: "2.1"), AppInfo.Plugin(id: "player", version: "5.1"),
                    AppInfo.Plugin(id: "nover", version: "3.0"), AppInfo.Plugin(id: "analytics", version: "9")]
        #expect(AppBuild.pluginRows(build: build, zapp: zapp).map { "\($0.id) \($0.status)" } == [
            "hero same", "player rebuildNeeded", "rater onlyInBuild", "nover same", "analytics onlyInZapp",
        ])
        #expect(AppBuild.pluginRows(build: nil, zapp: zapp).allSatisfy { $0.status == .notConfirmed && $0.build == nil })
        #expect(AppBuild.pluginRows(build: build, zapp: nil).allSatisfy { $0.status == .zappUnknown })
    }

    @Test("Report and app_info: confirmed with a rebuild hint; else Zapp's list, not confirmed, with why")
    func report() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let pc = "https://assets-secure.applicaster.com/zapp/accounts/a/apps/b/apple_store/2.9/plugin_configurations/plugin_configurations.json"
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .session, dataJSON: #"""
            {"applicaster.v2":{"version_name":"2.9","build_version":"800","plugin_configuration_url":"\#(pc)"}}
            """#)
        let http = ZappHTTP(get: { url in
            guard url.lastPathComponent == "plugin_configurations.json" else { throw URLError(.fileDoesNotExist) }
            return Data(#"[{"plugin":{"identifier":"hero","manifest_version":"2.2"}},{"plugin":{"identifier":"player","manifest_version":"5.0"}}]"#.utf8)
        })

        var r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.build == nil)
        #expect(r.pluginsNotConfirmed?.contains("wasn't asked") == true)
        #expect(r.pluginRows.map(\.status) == [.notConfirmed, .notConfirmed])

        try await store.recordAppBuild(sessionId: s.id, json: AppBuild.stored(
            appInfo: ["version": "2.8", "buildNumber": "812"],
            buildPlugins: [["id": "hero", "version": "2.1"], ["id": "player", "version": "5.0"]], note: nil))
        r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.pluginsNotConfirmed == nil)
        #expect(r.pluginRows.map(\.status) == [.rebuildNeeded, .same])
        #expect(r.identity.first { $0.label == "Build number" } == InfoRow(label: "Build number", value: "812", source: "app.info"))
        #expect(r.identity.contains { $0.label == "Build number (storage)" && $0.value == "800" })

        let ctx = ToolContext(store: store, ui: FakeUI(), device: FakeDevice(), zapp: http)
        let tool = try await InfoTools.appInfo.run(ToolArguments(["sessionId": JSON(s.id)]), ctx)
        #expect(tool.summary.contains("2 plugins built into the app, 1 need a rebuild to match Zapp"))
        #expect(tool.body.contains("hero: build 2.1, Zapp 2.2  [Zapp has another version: rebuild to pick it up]"))
        #expect(tool.structured["app"]?["pluginsConfirmed"] == true)
        #expect(tool.structured["app"]?["buildPlugins"]?.array?.first?["zapp"] == "2.2")

        try await store.recordAppBuild(sessionId: s.id, json: AppBuild.stored(appInfo: nil, buildPlugins: nil,
                                                                              note: "this app's X-Ray has no build.plugins (older X-Ray)"))
        let old = try await InfoTools.appInfo.run(ToolArguments(["sessionId": JSON(s.id)]), ctx)
        #expect(old.summary.contains("build not confirmed"))
        #expect(old.body.contains("build not confirmed: this app's X-Ray has no build.plugins"))
    }
}
