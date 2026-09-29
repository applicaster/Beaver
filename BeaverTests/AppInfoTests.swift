import Testing
import Foundation
@testable import BeaverCore

@Suite("App Info (D79)")
struct AppInfoTests {

    private let session = #"""
    {"applicaster.v2":{"deviceModel":"iPhone15,2","platform":"ios","osVersion":"18.6","app_name":"River",
      "version_name":"2.7","bundleIdentifier":"com.applicaster.river","accountsAccountId":"acct1","store":"apple_store",
      "version_id":"558736c1-fab8-4f78","userAgent":"Mozilla/5.0 (SMART-TV; Tizen 6.5) Chrome/85.0.4183.93"},
     "idfa":"{\"advertisingIdentifier\":\"AAAA-1111\",\"advertisingIdentifierLMT\":false}",
     "player_::_volume":"7"}
    """#
    private let local = #"""
    {"applicaster.v2":{"deviceModel":"ignored-local"},
     "loader":{"loader_cache":"{\"cellStyles\":{\"0a1b2c3d-1111-2222-3333-444455556666\":{\"plugin_identifier\":\"hero\"}}"}}
    """#

    @Test("Namespaces as objects, as JSON strings and flat ns_::_key; session wins")
    func leaves() {
        let leaves = AppInfo.leaves(session: session, local: local)
        #expect(leaves.contains(StorageLeaf(layer: "session", ns: "idfa", key: "advertisingIdentifierLMT", text: "false")))
        #expect(leaves.contains(StorageLeaf(layer: "session", ns: "player", key: "volume", text: "7")))
        #expect(AppInfo.find(leaves, ["deviceModel"])?.text == "iPhone15,2")
        // Only applicaster.v2 unless the row allows any namespace.
        #expect(AppInfo.find(leaves, ["advertisingIdentifier"]) == nil)
    }

    @Test("Device rows carry their source; the ad id comes from any namespace")
    func device() {
        let d = AppInfo.device(AppInfo.leaves(session: session, local: local))
        #expect(d.hardware.first == InfoRow(label: "Model", value: "iPhone15,2",
                                             source: "storage: session/applicaster.v2/deviceModel"))
        #expect(d.advertising.map(\.value) == ["AAAA-1111", "false"])
        #expect(d.advertisingNote == nil)
        #expect(d.userAgent.map(\.label) == ["User agent", "Tizen version", "Chromium", "Form factor"])
        #expect(AppInfo.device([]).advertisingNote != nil)
    }

    @Test("Cell styles are salvaged from the escaped loader cache")
    func cellStyles() {
        let cells = AppInfo.cellStylesFromStorage(AppInfo.leaves(session: session, local: local))
        #expect(cells == [AppInfo.CellStyle(id: "0a1b2c3d-1111-2222-3333-444455556666", plugin: "hero")])
    }

    @Test("Config files: captured, then derived; only Zapp's bucket")
    func configFiles() {
        let leaves = AppInfo.leaves(session: session, local: local)
        let base = "https://assets-secure.applicaster.com/zapp/accounts/acct1/apps/com.applicaster.river/apple_store/2.7"
        var files = AppInfo.configFiles(leaves: leaves, network: [])
        #expect(files[.rivers] == AppInfo.ConfigFile(url: base + "/rivers/rivers.json", body: nil, found: "derived from storage"))

        files = AppInfo.configFiles(leaves: leaves, network: [
            (url: base + "/rivers/rivers.json", body: "[]"),
            (url: "https://evil.example/zapp/accounts/a/apps/b/c/d/layout.json", body: "{}"),
        ])
        #expect(files[.rivers]?.body == "[]")
        #expect(files[.layout]?.found == "derived from storage")

        #expect(!AppInfo.isAllowedConfigURL("http://assets-secure.applicaster.com/zapp/accounts/a/apps/b/c/d/x.json"))
        #expect(!AppInfo.isAllowedConfigURL("https://assets-secure.applicaster.com:444/zapp/accounts/a/apps/b/c/d/x.json"))
    }

    @Test("The app's own URLs in applicaster.v2 win over the derived path; the key names the kind")
    func storageURLs() {
        let host = "https://assets-secure.applicaster.com/zapp/accounts/acct1"
        let app = host + "/apps/com.app/apple_store/0.0.7-dev"
        // As a real iOS app keeps them (loggernext_2026-09-23): cell styles only in local.
        let leaves = AppInfo.leaves(session: #"""
            {"applicaster.v2":{"accountsAccountId":"acct1","bundleIdentifier":"com.app","store":"apple_store","version_name":"0.0.7-dev",
              "layout_url":"\#(app)/layouts/layout.json","styles_url":"\#(app)/styles/styles.json",
              "endpoints_url":"\#(host)/app_families/7/data_source_providers/endpoints.json",
              "remote_configuration_url":"\#(app)/remote_configurations/remote_configurations.json"}}
            """#, local: #"""
            {"applicaster.v2":{"cell_styles_url":"\#(host)/app_families/7/layouts/L1/cell_styles.json",
              "tablet_layout_url":"\#(app)/layouts/tablet_layout.json"}}
            """#)
        let files = AppInfo.configFiles(leaves: leaves, network: [])
        #expect(files[.cellStyles] == AppInfo.ConfigFile(url: host + "/app_families/7/layouts/L1/cell_styles.json", body: nil,
                                                         found: "storage: local/applicaster.v2/cell_styles_url"))
        #expect(files[.tabletLayout]?.url == app + "/layouts/tablet_layout.json")
        #expect(files[.layout]?.found == "storage: session/applicaster.v2/layout_url")
        #expect(files[.styles]?.url == app + "/styles/styles.json")
        #expect(files[.pipesEndpoints]?.found == "storage: session/applicaster.v2/endpoints_url")
        #expect(files[.presetsMapping] == nil)
        #expect(files[.rivers]?.found == "derived from storage")
        #expect(AppInfo.accountId(fromConfigURLs: [app + "/layouts/layout.json"]) == "acct1")
    }

    @Test("Screens and cell styles from layout.json, plugins from configurations")
    func parsers() throws {
        let layout = try JSONSerialization.jsonObject(with: Data(#"""
        {"name":"Main","screens":[{"id":"s1","name":"Home","type":"general",
          "ui_components":[{"styles":{"cell_plugin_configuration_id":"c1"}}]}]}
        """#.utf8))
        #expect(AppInfo.layoutName(layout) == "Main")
        #expect(AppInfo.screens(fromRiversOrLayout: layout) == [AppInfo.Screen(id: "s1", name: "Home", type: "general")])
        #expect(AppInfo.cellStyles(fromLayout: layout, known: []) == [AppInfo.CellStyle(id: "c1", plugin: "used in: Home")])
        let pc = try JSONSerialization.jsonObject(with: Data(#"[{"plugin_identifier":"hero","version":"2.1"},{"x":1}]"#.utf8))
        #expect(AppInfo.plugins(fromConfigurations: pc) == [AppInfo.Plugin(id: "hero", version: "2.1")])
    }

    @Test("Zapp's real shapes: plugins nested under plugin, cell styles inside groups")
    func realShapes() throws {
        let pc = try JSONSerialization.jsonObject(with: Data(#"""
        [{"plugin":{"identifier":"quick-brick-app-rater","manifest_version":"9.1.2","dependency_version":"9.1.2"},"configuration_json":{}},
         {"plugin":{"identifier":"di_manager_call","manifest_version":"0.16.0"},"configuration_json":{}}]
        """#.utf8))
        #expect(AppInfo.plugins(fromConfigurations: pc) == [AppInfo.Plugin(id: "quick-brick-app-rater", version: "9.1.2"),
                                                            AppInfo.Plugin(id: "di_manager_call", version: "0.16.0")])
        let layout = try JSONSerialization.jsonObject(with: Data(#"""
        {"id":"l1","api_version":"2","screens":[{"id":"s1","name":"Home","type":"general","ui_components":[
          {"component_type":"group","styles":{},"ui_components":[{"styles":{"cell_plugin_configuration_id":"c9"}}]}]}]}
        """#.utf8))
        #expect(AppInfo.cellStyles(fromLayout: layout, known: []) == [AppInfo.CellStyle(id: "c9", plugin: "used in: Home")])
        #expect(AppInfo.layoutName(layout) == nil)
    }

    @Test("Visited screens from GA and Navigator logs, once each")
    func screensFromLogs() {
        let screens = AppInfo.screens(fromLogs: [
            (subsystem: "plugins/google-analytics", dataJSON: #"{"mappedEvent":{"params":{"screen_name":"Home","screen_entry_id":"e1"}}}"#),
            (subsystem: "app/Navigator", dataJSON: #"{"screenName":"Player","screenId":"p1"}"#),
            (subsystem: "plugins/google-analytics", dataJSON: #"{"mappedEvent":{"params":{"screen_name":"Home","screen_entry_id":"e1"}}}"#),
        ])
        #expect(screens.map(\.name) == ["Home", "Player"])
    }

    @Test("The report: storage identity, a cut captured body is fetched, plugins come from the file")
    func report() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .session, dataJSON: session)
        let base = "https://assets-secure.applicaster.com/zapp/accounts/acct1/apps/com.applicaster.river/apple_store/2.7"
        try await store.recordNetworkEntry(try #require(NetworkCapture(
            #"{"url":"\#(base)/rivers/rivers.json","status":200,"responseBody":"[{\"id\":\"s1\",\"name\":\"Ho"}"#,
            fallbackMillis: 0)), sessionId: s.id)
        let fetched = LockedBox<[String]>([])
        let http = ZappHTTP(
            get: { url in
                fetched.mutate { $0.append(url.lastPathComponent) }
                switch url.lastPathComponent {
                case "rivers.json": return Data(#"[{"id":"s1","name":"Home"}]"#.utf8)
                case "plugin_configurations.json": return Data(#"[{"identifier":"hero","version":"2.1"}]"#.utf8)
                default: throw URLError(.fileDoesNotExist)
                }
            })
        let r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.identity.first == InfoRow(label: "App name", value: "River", source: "storage: session/applicaster.v2/app_name"))
        #expect(r.identity.first { $0.label == "Account id" }?.source == "storage: session/applicaster.v2/accountsAccountId")
        #expect(r.screens.map(\.name) == ["Home"])
        #expect(r.screensSource == "rivers.json")
        #expect(r.plugins == [AppInfo.Plugin(id: "hero", version: "2.1")])
        #expect(r.configs[.layout]?.error != nil)
        #expect(fetched.value.sorted() == ["layout.json", "plugin_configurations.json", "remote_configurations.json", "rivers.json"])
    }

    @Test("Every launch-time file is listed; only the parsed ones are downloaded")
    func allConfigFiles() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .session, dataJSON: #"""
            {"applicaster.v2":{"version_name":"0.0.8-dev","bundleIdentifier":"com.app","accountsAccountId":"acct1",
              "store":"apple_store","app_family_id":"6420"}}
            """#)
        let host = "https://assets-secure.applicaster.com/zapp/accounts/acct1"
        let layouts = host + "/app_families/6420/layouts/L1"
        let fetched = LockedBox<[String]>([])
        let http = ZappHTTP(get: { url in
            fetched.mutate { $0.append(url.lastPathComponent) }
            guard url.lastPathComponent == "remote_configurations.json" else { return Data("{}".utf8) }
            return Data(#"""
                {"general_settings":{"cell_styles_json_url":"\#(layouts)/cell_styles.json",
                  "presets_mapping_json_url":"\#(layouts)/presets_mapping.json",
                  "tablet_cell_styles_json_url":"https://evil.example/cell_styles.json"}}
                """#.utf8)
        })
        let r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        let app = host + "/apps/com.app/apple_store/0.0.8-dev"
        #expect(r.configs[.remoteConfigurations]?.url == app + "/remote_configurations/remote_configurations.json")
        #expect(r.configs[.pluginConfigurations]?.url == app + "/plugin_configurations/plugin_configurations.json")
        #expect(r.configs[.pipesEndpoints]?.url == host + "/app_families/6420/data_source_providers/endpoints.json")
        #expect(r.configs[.cellStyles] == .init(url: layouts + "/cell_styles.json", found: "remote_configurations.json", error: nil))
        #expect(r.configs[.presetsMapping]?.url == layouts + "/presets_mapping.json")
        #expect(r.configs[.tabletCellStyles] == nil)
        #expect(!fetched.value.contains { ["cell_styles.json", "presets_mapping.json", "endpoints.json"].contains($0) })
        #expect(AppInfo.kind(of: layouts + "/cell_styles.json") == .cellStyles)
        #expect(!AppInfo.isAllowedConfigURL(host + "/app_families/6420"))
    }

    @Test("No storage: nothing to look up, nothing fetched")
    func noStorage() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let http = ZappHTTP(get: { _ in Issue.record("fetched"); throw URLError(.notConnectedToInternet) })
        let r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.configs.isEmpty)
        #expect(r.storageAsOf == nil)
    }
}

/// A tiny thread-safe box for recording calls from @Sendable closures.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}


@Suite("Device fingerprint (D79)")
struct FingerprintTests {
    @Test("Context line, ids, session and time, one per line")
    func fingerprint() {
        let s = Session(id: 7, startedAt: Date(timeIntervalSince1970: 0), source: .live, appName: "River",
                        appVersion: "2.7", deviceModel: "iPhone15,2", platform: "iOS", osVersion: "18.6",
                        deviceUID: "uid-1", appPackage: "com.a.river")
        #expect(s.fingerprint(capturedAt: Date(timeIntervalSince1970: 0)) == """
            River 2.7 · iPhone15,2 · iOS 18.6
            Device id: uid-1
            Bundle id: com.a.river
            Beaver session: #7
            Captured: 1970-01-01T00:00:00Z
            """)
        #expect(Session(id: 1, startedAt: Date(), source: .imported).fingerprint(capturedAt: Date()).hasPrefix("Unknown device\n"))
    }
}

@Suite("Config files saved with the session (D79)")
struct SavedConfigTests {
    private let storage = #"""
        {"applicaster.v2":{"version_name":"1.0","bundleIdentifier":"com.app","accountsAccountId":"acct1",
          "store":"apple_store","app_family_id":"7"}}
        """#
    private static let family = "https://assets-secure.applicaster.com/zapp/accounts/acct1/app_families/7"

    /// Serves every file; counts what was fetched.
    private func zapp(_ fetched: LockedBox<[String]>, layoutName: String = "Main") -> ZappHTTP {
        ZappHTTP(get: { url in
            fetched.mutate { $0.append(url.lastPathComponent) }
            switch url.lastPathComponent {
            case "remote_configurations.json":
                return Data(#"{"general_settings":{"cell_styles_json_url":"\#(Self.family)/layouts/L/cell_styles.json"}}"#.utf8)
            case "layout.json": return Data(#"{"name":"\#(layoutName)","screens":[{"id":"s1","name":"Home"}]}"#.utf8)
            case "cell_styles.json": return Data(#"{"c1":{"plugin_identifier":"hero"}}"#.utf8)
            default: throw URLError(.fileDoesNotExist)
            }
        })
    }

    private func session(_ store: LogStore) async throws -> Int64 {
        let s = try await store.createSession(source: .live)
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .session, dataJSON: storage)
        return s.id
    }

    @Test("Capture downloads every file once, a second capture fetches nothing, and App Info reads the saved copy")
    func capture() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        let fetched = LockedBox<[String]>([])
        let n = try await ConfigSnapshot.capture(store: store, sessionId: s, http: zapp(fetched))
        #expect(n == 6)  // layout, rivers, plugin + remote configurations, pipes endpoints, cell styles
        #expect(fetched.value.contains("cell_styles.json"))
        let saved = try await store.savedConfigs(sessionId: s)
        #expect(saved.first { $0.kind == .cellStyles }?.sha256 != nil)
        #expect(saved.first { $0.kind == .rivers }?.error != nil)

        let before = fetched.value.count
        #expect(try await ConfigSnapshot.capture(store: store, sessionId: s, http: zapp(fetched)) == 6)
        #expect(fetched.value.count == before)

        // Zapp published a new layout since: the session still shows its own.
        let r = try await AppInfoReport.build(store: store, sessionId: s, http: zapp(fetched, layoutName: "Republished"))
        #expect(r.identity.first?.value == "Main")
        #expect(r.configsSavedAt != nil)
        #expect(r.configs[.cellStyles]?.size == #"{"c1":{"plugin_identifier":"hero"}}"#.utf8.count)
        #expect(fetched.value.count == before)
    }

    @Test("A file shared by two sessions is stored once and goes with the last of them")
    func sharedBlob() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await session(store), b = try await session(store)
        let fetched = LockedBox<[String]>([])
        try await ConfigSnapshot.capture(store: store, sessionId: a, http: zapp(fetched))
        try await ConfigSnapshot.capture(store: store, sessionId: b, http: zapp(fetched))
        let sha = try #require(try await store.savedConfigs(sessionId: a).first { $0.kind == .layout }?.sha256)
        #expect(try await store.savedConfigs(sessionId: b).first { $0.kind == .layout }?.sha256 == sha)

        try await store.deleteSessions(ids: [a])
        #expect(try await store.configData(sha256: sha) != nil)
        try await store.deleteSessions(ids: [b])
        #expect(try await store.configData(sha256: sha) == nil)
    }

    @Test("app_config: the saved files, a path inside one, errors that say what exists, download for older sessions")
    func tool() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await session(store)
        let fetched = LockedBox<[String]>([])
        let ctx = ToolContext(store: store, ui: FakeUI(value: HostSnapshot()), device: FakeDevice(), zapp: zapp(fetched))
        await #expect(throws: ToolError.self) {
            _ = try await InfoTools.appConfig.run(ToolArguments(["sessionId": JSON(s)]), ctx)
        }
        let list = try await InfoTools.appConfig.run(ToolArguments(["sessionId": JSON(s), "download": true]), ctx)
        #expect(list.summary.contains("config files saved"))

        let name = try await InfoTools.appConfig.run(
            ToolArguments(["sessionId": JSON(s), "kind": "layout", "path": "screens.0.name"]), ctx)
        #expect(name.body == "\"Home\"")
        let layout = try await InfoTools.appConfig.run(ToolArguments(["sessionId": JSON(s), "kind": "layout"]), ctx)
        #expect(layout.structured["keys"] == ["name", "screens"])

        do {
            _ = try await InfoTools.appConfig.run(ToolArguments(["sessionId": JSON(s), "kind": "layout", "path": "screenz"]), ctx)
            Issue.record("no error")
        } catch let e as ToolError {
            #expect(e.message.contains("keys: name, screens"))
        }
    }
}
