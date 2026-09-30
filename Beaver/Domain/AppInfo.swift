//
//  AppInfo.swift
//  Beaver
//
//  D79: what device and app a session is, read from its storage, captured
//  requests and logs, each value with where it came from. The selectors are
//  zapp-support's (src/utils/deviceAppInfo.ts): keep the alias lists in step
//  so both tools show the same rows.

import Foundation

public struct InfoRow: Sendable, Equatable {
    public let label: String
    public let value: String
    /// "storage: session/applicaster.v2/deviceModel", "config file URL", "user agent (best-effort)"…
    public let source: String

    public init(label: String, value: String, source: String) {
        self.label = label; self.value = value; self.source = source
    }
}

/// One namespaced key of the session or local layer.
public struct StorageLeaf: Sendable, Equatable {
    public let layer: String
    public let ns: String
    public let key: String
    /// The value as text: strings as they are, anything else as JSON.
    /// Nil for null.
    public let text: String?

    var source: String { "storage: \(layer)/\(ns)/\(key)" }
}

public enum AppInfo {

    // MARK: - Storage

    /// One leaf per namespaced key, session layer first (it wins on lookup).
    /// A namespace may arrive as an object or as a JSON string; the flat
    /// `ns_::_key` shape of web SDKs is split too.
    public static func leaves(session: String?, local: String?, keychain: String? = nil) -> [StorageLeaf] {
        var out: [StorageLeaf] = []
        for (layer, json) in [("session", session), ("local", local), ("keychain", keychain)] {
            guard let json, let root = object(json) else { continue }
            for key in root.keys.sorted() {
                let value = root[key]!
                if let inner = object(value) {
                    for innerKey in inner.keys.sorted() {
                        out.append(StorageLeaf(layer: layer, ns: key, key: innerKey, text: text(inner[innerKey]!)))
                    }
                } else if key.contains("_::_") {
                    let parts = key.components(separatedBy: "_::_")
                    out.append(StorageLeaf(layer: layer, ns: parts[0],
                                           key: parts.dropFirst().joined(separator: "_::_"), text: text(value)))
                }
            }
        }
        return out
    }

    /// First leaf whose key matches one of `keys` (in alias order),
    /// applicaster.v2 preferred over other namespaces, session over local.
    static func find(_ leaves: [StorageLeaf], _ keys: [String], anyNamespace: Bool = false) -> StorageLeaf? {
        for key in keys {
            let pool = leaves.filter { $0.key == key && !($0.text ?? "").isEmpty }
            if let leaf = pool.first(where: { $0.ns == "applicaster.v2" }) ?? (anyNamespace ? pool.first : nil) {
                return leaf
            }
        }
        return nil
    }

    static func rows(_ leaves: [StorageLeaf], _ spec: [(String, [String], Bool)]) -> [InfoRow] {
        spec.compactMap { label, keys, anyNamespace in
            find(leaves, keys, anyNamespace: anyNamespace).map { InfoRow(label: label, value: $0.text!, source: $0.source) }
        }
    }

    // MARK: - Device

    public struct Device: Sendable, Equatable {
        public var identity: [InfoRow]
        public var hardware: [InfoRow]
        public var advertising: [InfoRow]
        public var userAgent: [InfoRow]
        /// Why there is no advertising id, when there isn't.
        public var advertisingNote: String?
    }

    public static func device(_ leaves: [StorageLeaf]) -> Device {
        let identity = rows(leaves, [
            ("UUID", ["uuid", "UUID"], false),
            ("Session id (session_id)", ["session_id"], false),
            ("Session id (sessionId)", ["sessionId"], false),
            ("Session start", ["session_time"], false),
        ])
        let hardware = rows(leaves, [
            ("Manufacturer", ["deviceMake", "device_make"], false),
            ("Model", ["deviceModel", "device_model"], false),
            ("Device name", ["deviceName", "device_name"], false),
            ("Device type", ["deviceType", "device_type"], false),
            ("Platform", ["platform"], false),
            ("OS version", ["osVersion", "os_version"], false),
            ("Store", ["store"], false),
            ("Screen width", ["deviceWidth", "device_width"], false),
            ("Screen height", ["deviceHeight", "device_height"], false),
            ("Network type", ["network_type", "networkType"], false),
            ("Language", ["languageCode", "language_code"], false),
            ("Country", ["countryLocale", "country_locale"], false),
            ("UI language", ["uiLanguage", "ui_language"], false),
            ("Country code", ["countryCode", "country_code"], false),
            ("Region", ["regionCode", "region_code"], false),
            ("Currency", ["currencySymbol", "currency_symbol"], false),
            ("Right-to-left", ["is_rtl", "isRTL"], false),
        ])
        // Written by the session-storage-idfa plugin (idfa_storing); any namespace.
        let advertising = rows(leaves, [
            ("Advertising ID", ["advertisingIdentifier", "advertising_id", "advertisingId"], true),
            ("Advertising ID type", ["advertisingIdentifierType"], true),
            ("Limit ad tracking (LMT)", ["advertisingIdentifierLMT"], true),
        ])
        var userAgent: [InfoRow] = []
        if let ua = find(leaves, ["userAgent", "user_agent"]), let text = ua.text {
            userAgent = [InfoRow(label: "User agent", value: text, source: ua.source)] + userAgentDerived(text)
        }
        return Device(
            identity: identity, hardware: hardware, advertising: advertising, userAgent: userAgent,
            advertisingNote: advertising.isEmpty
                ? "Not exposed by this app: the advertising-ID plugin (idfa_storing) is not installed or has not stored a value."
                : nil)
    }

    static func userAgentDerived(_ ua: String) -> [InfoRow] {
        var out: [InfoRow] = []
        func add(_ label: String, _ pattern: String) {
            if let value = firstGroup(pattern, in: ua) {
                out.append(InfoRow(label: label, value: value, source: "user agent (best-effort)"))
            }
        }
        add("Tizen version", #"Tizen (\d+(?:\.\d+)*)"#)
        add("webOS", #"webOS\.TV-(\d+)"#)
        add("Chromium", #"(?:Chrome/|\s)(\d+\.\d+\.\d+\.\d+)"#)
        if ua.range(of: "SMART-TV|Web0S|TV Safari", options: [.regularExpression, .caseInsensitive]) != nil {
            out.append(InfoRow(label: "Form factor", value: "TV", source: "user agent (best-effort)"))
        }
        return out
    }

    // MARK: - App

    public struct Plugin: Sendable, Equatable {
        public let id: String
        public let version: String?
        /// Only the build's list (`build.plugins`, D85) names them.
        public var name: String? = nil
    }

    public struct CellStyle: Sendable, Equatable {
        public let id: String
        public let plugin: String
    }

    public struct Screen: Sendable, Equatable {
        public let id: String
        public let name: String
        public let type: String?
    }

    /// Type mapping: an entry's type → the screen that opens it.
    public struct TypeMapping: Sendable, Equatable {
        public let type: String
        public let screenId: String
        /// Nil when the layout has no screen with that id.
        public let screenName: String?
    }

    public static func appIdentity(_ leaves: [StorageLeaf]) -> [InfoRow] {
        rows(leaves, [
            ("App name", ["app_name", "appName"], false),
            ("Bundle id", ["bundleIdentifier", "bundle_identifier"], false),
            ("App version", ["version_name", "versionName", "ver"], false),
            ("Build number", ["build_version", "buildVersion"], false),
            ("SDK version", ["sdk_version", "sdkVersion"], false),
            ("QuickBrick version", ["quickBrickVersion", "quickbrick_version"], false),
            ("Zapp version id", ["version_id"], false),
            ("Account id", ["accountsAccountId", "account_id", "accounts_account_id", "zapp_account_id"], false),
            ("App family id", ["app_family_id"], false),
            ("Layout id", ["layoutId", "riversConfigurationId", "rivers_configuration_id"], false),
            ("URL scheme", ["urlSchemePrefix", "url_scheme_prefix", "urlScheme"], false),
            ("Sessions of this version", ["total_sessions_for_current_version"], false),
            ("Sessions in total", ["total_session_number"], false),
        ]).map { row in
            // urlScheme is a JSON array: ["aio"].
            guard row.label == "URL scheme", let list = (try? JSONSerialization.jsonObject(with: Data(row.value.utf8))) as? [String]
            else { return row }
            return InfoRow(label: row.label, value: list.joined(separator: ", "), source: row.source)
        }
    }

    /// Session-layer namespaces other than applicaster.v2 are plugin configs.
    public static func pluginsFromStorage(_ leaves: [StorageLeaf]) -> [Plugin] {
        Set(leaves.filter { $0.layer == "session" && $0.ns != "applicaster.v2" }.map(\.ns))
            .sorted().map { Plugin(id: $0, version: nil) }
    }

    /// Local `loader_cache.cellStyles` is a JSON string, possibly cut short
    /// on the device, so the pairs are salvaged by regex rather than parsed.
    public static func cellStylesFromStorage(_ leaves: [StorageLeaf]) -> [CellStyle] {
        guard let text = leaves.first(where: { $0.key == "loader_cache" || $0.key == "cellStyles" })?.text else { return [] }
        let tail = text.range(of: "cellStyles").map { String(text[$0.lowerBound...]) } ?? text
        let pattern = #"([0-9a-f]{8}-[0-9a-f-]{27})\\*"\s*:\s*\{\\*"plugin_identifier\\*"\s*:\s*\\*"([^"\\]+)"#
        var seen: [String] = []
        var plugin: [String: String] = [:]
        for groups in allGroups(pattern, in: tail) where groups.count == 2 {
            if plugin[groups[0]] == nil { seen.append(groups[0]) }
            plugin[groups[0]] = groups[1]
        }
        return seen.map { CellStyle(id: $0, plugin: plugin[$0]!) }
    }

    // MARK: - Launch-time config files (S3)

    /// The files QuickBrick loads at launch (`runtime_configuration_urls.json`,
    /// written by zapplicaster-cli), plus the older
    /// rivers.json and styles.json.
    public enum ConfigKind: String, Sendable, CaseIterable {
        case layout, tabletLayout, rivers, pluginConfigurations, remoteConfigurations,
             cellStyles, tabletCellStyles, presetsMapping, tabletPresetsMapping, pipesEndpoints, styles,
             /// The strings file of the device's language (remote_configurations' `localizations`).
             localization

        /// Read by App Info, so always downloaded; the rest are only listed.
        var isParsed: Bool { [.layout, .rivers, .pluginConfigurations, .remoteConfigurations, .pipesEndpoints].contains(self) }
    }

    public struct ConfigFile: Sendable, Equatable {
        public let url: String
        /// A captured response body, when the app's request was recorded.
        public let body: String?
        /// "captured request", "storage: local/applicaster.v2/layout_url", "derived from storage".
        public let found: String
    }

    public static let configHost = "assets-secure.applicaster.com"

    /// Only Zapp's public config bucket is ever fetched: an app version's
    /// files, or its app family's (cell styles, presets, pipes endpoints).
    public static func isAllowedConfigURL(_ raw: String) -> Bool {
        guard let u = URLComponents(string: raw), u.scheme == "https", u.host == configHost,
              u.port == nil, u.user == nil, u.password == nil else { return false }
        return u.path.range(of: #"^/zapp/accounts/[^/]+/(apps/[^/]+/[^/]+/[^/]+|app_families/[^/]+)/.+\.json$"#,
                            options: .regularExpression) != nil
    }

    /// The app's own record of the URLs it loaded: applicaster.v2 keys, in
    /// the session and local layers. The key names the kind, tablet ones too.
    static let storageKeys: [String: ConfigKind] = [
        "layout_url": .layout, "tablet_layout_url": .tabletLayout, "rivers_url": .rivers,
        "plugin_configuration_url": .pluginConfigurations, "plugin_configurations_url": .pluginConfigurations,
        "remote_configuration_url": .remoteConfigurations, "remote_configurations_url": .remoteConfigurations,
        "cell_styles_url": .cellStyles, "tablet_cell_styles_url": .tabletCellStyles,
        "presets_mapping_url": .presetsMapping, "tablet_presets_mapping_url": .tabletPresetsMapping,
        "endpoints_url": .pipesEndpoints, "pipes_endpoints_url": .pipesEndpoints, "styles_url": .styles,
    ]

    /// Tablet variants can't be told from the URL: they come only from
    /// storage keys and remote_configurations.
    static func kind(of url: String) -> ConfigKind? {
        let path = url.components(separatedBy: "?")[0]
        let patterns: [(ConfigKind, String)] = [
            (.pluginConfigurations, #"plugin_?configurations?[\w-]*\.json"#),
            (.remoteConfigurations, #"remote_?configurations?[\w-]*\.json"#),
            (.cellStyles, #"cell_?styles[\w-]*\.json"#),
            (.presetsMapping, #"presets_?mapping[\w-]*\.json"#),
            (.pipesEndpoints, #"/data_source_providers/endpoints\.json|pipes_?endpoints[\w-]*\.json"#),
            (.styles, #"/styles/styles\.json"#),
            (.localization, #"/localizations/[\w-]+\.json"#),
            (.rivers, #"rivers[\w-]*\.json"#),
            (.layout, #"layout[\w-]*\.json"#),
        ]
        return patterns.first { path.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }?.0
    }

    /// Storage `store` → the S3 path segment. Unknown values aren't guessed.
    static let storeSegment = [
        "samsung": "samsung_app_store", "samsung_app_store": "samsung_app_store",
        "lg": "lg_content_store", "lg_content_store": "lg_content_store",
        "apple_store": "apple_store",
    ]

    /// Where each config file is, with its body when a captured request has
    /// it. What the app itself used wins: captured requests, then the URLs
    /// it keeps in storage; then the path Zapp builds from account, bundle,
    /// store and version.
    public static func configFiles(
        leaves: [StorageLeaf],
        network: [(url: String, body: String?)]
    ) -> [ConfigKind: ConfigFile] {
        var candidates: [(kind: ConfigKind?, file: ConfigFile)] =
            network.map { (nil, ConfigFile(url: $0.url, body: $0.body, found: "captured request")) }
        for leaf in leaves {
            for url in allGroups(#"(https?://[^\s"'\\]+\.json[^\s"'\\]*)"#, in: leaf.text ?? "").map({ $0[0] }) {
                candidates.append((storageKeys[leaf.key], ConfigFile(url: url, body: nil, found: leaf.source)))
            }
        }
        let part = { (keys: [String]) in find(leaves, keys)?.text }
        if let account = part(["accountsAccountId", "account_id", "accounts_account_id"]),
           let bundle = part(["bundleIdentifier", "bundle_identifier"]),
           let store = part(["store"]).flatMap({ storeSegment[$0] }),
           let version = part(["version_name", "versionName"]) {
            let seg = [account, bundle, store, version]
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            let base = "https://\(configHost)/zapp/accounts/\(seg[0])/apps/\(seg[1])/\(seg[2])/\(seg[3])"
            for file in ["rivers/rivers.json", "layouts/layout.json", "remote_configurations/remote_configurations.json",
                         "plugin_configurations/plugin_configurations.json"] {
                candidates.append((nil, ConfigFile(url: base + "/" + file, body: nil, found: "derived from storage")))
            }
        }
        if let account = part(["accountsAccountId", "account_id", "accounts_account_id"]),
           let family = part(["app_family_id"]) {
            let seg = [account, family].map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            candidates.append((nil, ConfigFile(
                url: "https://\(configHost)/zapp/accounts/\(seg[0])/app_families/\(seg[1])/data_source_providers/endpoints.json",
                body: nil, found: "derived from storage")))
        }
        var out: [ConfigKind: ConfigFile] = [:]
        for (known, c) in candidates where isAllowedConfigURL(c.url) {
            guard let kind = known ?? kind(of: c.url) else { continue }
            if out[kind] == nil { out[kind] = c }
        }
        return out
    }

    // Tolerant readers: exact S3 shapes vary, so take the common
    // `id`/`name`/`type` and `identifier`/`plugin_identifier`/`version` fields.

    static func list(_ json: Any?) -> [[String: Any]] {
        if let array = json as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        if let dict = json as? [String: Any] { return dict.keys.sorted().compactMap { dict[$0] as? [String: Any] } }
        return []
    }

    public static func screens(fromRiversOrLayout json: Any) -> [Screen] {
        list((json as? [String: Any])?["screens"] ?? json).compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            return Screen(id: id, name: name, type: r["type"] as? String)
        }
    }

    /// Cell styles a layout uses; the plugin name comes from the storage
    /// cache when it knows the id, else the screens that use it.
    public static func cellStyles(fromLayout json: Any, known: [CellStyle]) -> [CellStyle] {
        var order: [String] = []
        var usedIn: [String: [String]] = [:]
        // Groups hold their own ui_components, so walk them all.
        func walk(_ components: [[String: Any]], screen: String) {
            for component in components {
                if let id = (component["styles"] as? [String: Any])?["cell_plugin_configuration_id"] as? String, !id.isEmpty {
                    if usedIn[id] == nil { order.append(id); usedIn[id] = [] }
                    if !usedIn[id]!.contains(screen) { usedIn[id]!.append(screen) }
                }
                walk(list(component["ui_components"]), screen: screen)
            }
        }
        for screen in list((json as? [String: Any])?["screens"]) {
            walk(list(screen["ui_components"]), screen: "\(screen["name"] ?? "")")
        }
        return order.map { id in
            CellStyle(id: id, plugin: known.first { $0.id == id }?.plugin
                      ?? "used in: " + usedIn[id]!.joined(separator: ", "))
        }
    }

    /// layout.json's `content_types` (Zapp's type mapping), by type.
    public static func typeMapping(fromLayout json: Any) -> [TypeMapping] {
        guard let layout = json as? [String: Any], let types = layout["content_types"] as? [String: Any] else { return [] }
        let names = screenNames(layout)
        return types.keys.sorted().compactMap { type in
            guard let id = (types[type] as? [String: Any])?["screen_id"] as? String else { return nil }
            return TypeMapping(type: type, screenId: id, screenName: names[id])
        }
    }

    /// A menu or nav bar entry of layout.json's `navigations`, and the screen it opens.
    public struct NavItem: Sendable, Equatable {
        public let menu: String
        public let title: String
        public let screenId: String
        public let screenName: String?
    }

    public static func navigation(fromLayout json: Any) -> [NavItem] {
        guard let layout = json as? [String: Any] else { return [] }
        let names = screenNames(layout)
        return list(layout["navigations"]).flatMap { nav -> [NavItem] in
            let menu = "\(nav["name"] as? String ?? "")" + ((nav["category"] as? String).map { " (\($0))" } ?? "")
            return list(nav["nav_items"])
                .sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                .map { item in
                    let target = (item["data"] as? [String: Any])?["target"] as? String ?? ""
                    return NavItem(menu: menu, title: item["title"] as? String ?? "", screenId: target, screenName: names[target])
                }
        }
    }

    /// A data source (pipes endpoint): what the app requests, and which
    /// storage keys it sends with it (`namespace.key`, as header, query…).
    public struct DataSource: Sendable, Equatable {
        public let url: String
        public let method: String
        public let sends: [(key: String, as: String)]

        public static func == (a: Self, b: Self) -> Bool {
            a.url == b.url && a.method == b.method && a.sends.map { "\($0.key) \($0.as)" } == b.sends.map { "\($0.key) \($0.as)" }
        }
    }

    public static func dataSources(fromEndpoints json: Any) -> [DataSource] {
        guard let endpoints = (json as? [String: Any])?["endpoints"] as? [String: Any] else { return [] }
        return endpoints.keys.sorted().map { url in
            let e = endpoints[url] as? [String: Any] ?? [:]
            let sends = list(e["context_obj"]).compactMap { c -> (key: String, as: String)? in
                (c["key"] as? String).map { ($0, c["type"] as? String ?? "") }
            }
            return DataSource(url: url, method: (e["method"] as? String ?? "get").uppercased(), sends: sends)
        }
    }

    /// Whether the storage keys the data sources send (`namespace.key`) are
    /// stored — the login state, as the app's own requests see it. Never the
    /// value. Other context keys (`timeZoneOffset`, `screen/…`) are filled
    /// at request time, not from storage: left out.
    public static func sentKeys(_ sources: [DataSource], leaves: [StorageLeaf]) -> [InfoRow] {
        var seen: [String] = []
        for s in sources {
            for k in s.sends where !seen.contains(k.key)
                && k.key.range(of: #"^[\w-]+\.[\w.-]+$"#, options: .regularExpression) != nil {
                seen.append(k.key)
            }
        }
        return seen.map { key in
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            let leaf = leaves.first { $0.ns == parts[0] && $0.key == parts[1] && !($0.text ?? "").isEmpty }
            return InfoRow(label: key, value: leaf == nil ? "not in storage" : "stored",
                           source: leaf?.source ?? "sent by data sources")
        }
    }

    /// remote_configurations' languages, and the strings file of the
    /// device's language (else the first).
    public static func languages(fromRemote json: Any?) -> [String] {
        ((json as? [String: Any])?["languages"] as? [String]) ?? []
    }

    public static func localizationURL(fromRemote json: Any?, leaves: [StorageLeaf]) -> String? {
        guard let files = (json as? [String: Any])?["localizations"] as? [String: String], !files.isEmpty else { return nil }
        let device = find(leaves, ["uiLanguage", "ui_language", "languageCode", "language_code"])?.text
        let lang = [device, device.map { String($0.prefix(2)) }].compactMap { $0 }.first { files[$0] != nil }
            ?? languages(fromRemote: json).first { files[$0] != nil } ?? files.keys.sorted()[0]
        return files[lang]
    }

    /// The app's icon from remote_configurations' assets (Icon-1024 when there).
    public static func iconURL(fromRemote json: Any?) -> String? {
        guard let assets = (json as? [String: Any])?["assets"] as? [String: Any] else { return nil }
        let all = assets.values.compactMap { $0 as? [String: Any] }.flatMap { $0 }
            .filter { $0.key.hasPrefix("Icon") }.compactMap { kv in (kv.value as? String).map { (kv.key, $0) } }
        return (all.first { $0.0 == "Icon-1024" } ?? all.sorted { $0.0 < $1.0 }.last)?.1
    }

    static func screenNames(_ layout: [String: Any]) -> [String: String] {
        Dictionary(list(layout["screens"]).compactMap { s in
            (s["id"] as? String).map { ($0, s["name"] as? String ?? "") }
        }, uniquingKeysWith: { a, _ in a })
    }

    public static func layoutName(_ json: Any) -> String? {
        (json as? [String: Any])?["name"] as? String
    }

    /// Zapp's file is `[{plugin: {identifier, manifest_version, …}, configuration_json}]`;
    /// flat entries are read too.
    public static func plugins(fromConfigurations json: Any) -> [Plugin] {
        list(json).compactMap { entry in
            let p = entry["plugin"] as? [String: Any] ?? entry
            guard let id = [p["identifier"], p["plugin_identifier"], p["id"]].lazy.compactMap({ $0 as? String }).first
            else { return nil }
            return Plugin(id: id, version: [p["manifest_version"], p["dependency_version"], p["version"], p["plugin_version"]]
                .lazy.compactMap { $0 as? String }.first)
        }
    }

    /// The account id from a config URL (`/zapp/accounts/<id>/…`), for apps
    /// whose storage doesn't name it.
    public static func accountId(fromConfigURLs urls: [String]) -> String? {
        urls.lazy.compactMap { firstGroup(#"/zapp/accounts/([^/]+)/"#, in: $0) }.first
    }

    // MARK: - Config URLs named inside config files

    /// The URLs remote_configurations.json's general_settings names — how
    /// cell styles and presets are found when storage doesn't keep them.
    public static func remoteConfigURLs(_ json: Any?) -> [ConfigKind: String] {
        urls((json as? [String: Any])?["general_settings"] as? [String: Any], [
            (.cellStyles, "cell_styles_json_url"), (.tabletCellStyles, "tablet_cell_styles_json_url"),
            (.presetsMapping, "presets_mapping_json_url"), (.tabletPresetsMapping, "tablet_presets_mapping_json_url"),
        ])
    }

    static func urls(_ dict: [String: Any]?, _ keys: [(ConfigKind, String)]) -> [ConfigKind: String] {
        var out: [ConfigKind: String] = [:]
        for (kind, key) in keys {
            if let url = dict?[key] as? String, !url.isEmpty { out[kind] = url }
        }
        return out
    }

    // MARK: - Screens visited (GA screen_view and Navigator logs)

    public static func screens(fromLogs logs: [(subsystem: String, dataJSON: String)]) -> [Screen] {
        var order: [String] = []
        var seen: [String: Screen] = [:]
        for log in logs {
            guard let d = object(log.dataJSON) else { continue }
            let params = ((d["mappedEvent"] as? [String: Any])?["params"] as? [String: Any])
            var screen: Screen?
            if log.subsystem.contains("google-analytics"), let name = params?["screen_name"] as? String {
                screen = Screen(id: params?["screen_entry_id"] as? String ?? "", name: name,
                                type: params?["screen_type"] as? String)
            } else if log.subsystem.hasSuffix("/Navigator"), let name = d["screenName"] as? String {
                screen = Screen(id: d["screenId"] as? String ?? "", name: name, type: d["entryType"] as? String)
            }
            guard let screen else { continue }
            let key = screen.name + "|" + screen.id
            if seen[key] == nil { order.append(key) }
            seen[key] = screen
        }
        return order.map { seen[$0]! }
    }

    // MARK: - Helpers

    /// A JSON object, or a string holding one.
    static func object(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let s = value as? String, s.hasPrefix("{"),
              let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return nil }
        return parsed as? [String: Any]
    }

    static func text(_ value: Any) -> String? {
        switch value {
        case is NSNull: return nil
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func allGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        allGroups(pattern, in: text).first?.first
    }
}
