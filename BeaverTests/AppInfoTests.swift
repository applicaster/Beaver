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

    @Test("Config files: CMS, then captured, then derived; only Zapp's bucket")
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

        files = AppInfo.configFiles(leaves: leaves, network: [],
                                    cms: [.pluginConfigurations: base + "/plugin_configurations/plugin_configurations.json"])
        #expect(files[.pluginConfigurations]?.found == "CMS")
        #expect(!AppInfo.isAllowedConfigURL("http://assets-secure.applicaster.com/zapp/accounts/a/apps/b/c/d/x.json"))
        #expect(!AppInfo.isAllowedConfigURL("https://assets-secure.applicaster.com:444/zapp/accounts/a/apps/b/c/d/x.json"))
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

    @Test("The report: CMS wins, a cut captured body is fetched, plugins come from the file")
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
            token: { "t" },
            buildParams: { id, _ in
                ["app_name": "River CMS", "plugin_configurations_url": base + "/plugins/plugin_configurations.json",
                 "version_id": id]
            },
            get: { url in
                fetched.mutate { $0.append(url.lastPathComponent) }
                switch url.lastPathComponent {
                case "rivers.json": return Data(#"[{"id":"s1","name":"Home"}]"#.utf8)
                case "plugin_configurations.json": return Data(#"[{"identifier":"hero","version":"2.1"}]"#.utf8)
                default: throw URLError(.fileDoesNotExist)
                }
            })
        let r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.cms == .loaded)
        #expect(r.identity.first == InfoRow(label: "App name", value: "River CMS", source: "CMS"))
        #expect(r.screens.map(\.name) == ["Home"])
        #expect(r.screensSource == "rivers.json")
        #expect(r.plugins == [AppInfo.Plugin(id: "hero", version: "2.1")])
        #expect(r.configs[.layout]?.error != nil)
        #expect(fetched.value.sorted() == ["layout.json", "plugin_configurations.json", "rivers.json"])
    }

    @Test("Without a token the CMS isn't asked")
    func noToken() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let http = ZappHTTP(token: { nil }, buildParams: { _, _ in Issue.record("asked"); return [:] },
                            get: { _ in throw URLError(.notConnectedToInternet) })
        let r = try await AppInfoReport.build(store: store, sessionId: s.id, http: http)
        #expect(r.cms == .noToken)
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
