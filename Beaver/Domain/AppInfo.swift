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
    /// "storage: session/applicaster.v2/deviceModel", "CMS", "user agent (best-effort)"…
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
    public static func leaves(session: String?, local: String?) -> [StorageLeaf] {
        var out: [StorageLeaf] = []
        for (layer, json) in [("session", session), ("local", local)] {
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

    public static func appIdentity(_ leaves: [StorageLeaf]) -> [InfoRow] {
        rows(leaves, [
            ("App name", ["app_name", "appName"], false),
            ("Bundle id", ["bundleIdentifier", "bundle_identifier"], false),
            ("App version", ["version_name", "versionName", "ver"], false),
            ("Build number", ["build_version", "buildVersion"], false),
            ("SDK version", ["sdk_version", "sdkVersion"], false),
            ("QuickBrick version", ["quickBrickVersion", "quickbrick_version"], false),
            ("Zapp version id", ["version_id"], false),
            ("Account id", ["accountsAccountId", "account_id", "accounts_account_id"], false),
            ("App family id", ["app_family_id"], false),
            ("Layout id", ["layoutId", "riversConfigurationId", "rivers_configuration_id"], false),
            ("URL scheme", ["urlSchemePrefix", "url_scheme_prefix"], false),
        ])
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

    public enum ConfigKind: String, Sendable, CaseIterable {
        case layout, rivers, pluginConfigurations
    }

    public struct ConfigFile: Sendable, Equatable {
        public let url: String
        /// A captured response body, when the app's request was recorded.
        public let body: String?
        /// "CMS", "captured request", "storage", "derived from storage".
        public let found: String
    }

    public static let configHost = "assets-secure.applicaster.com"

    /// Only Zapp's public config bucket is ever fetched.
    public static func isAllowedConfigURL(_ raw: String) -> Bool {
        guard let u = URLComponents(string: raw), u.scheme == "https", u.host == configHost,
              u.port == nil, u.user == nil, u.password == nil else { return false }
        return u.path.range(of: #"^/zapp/accounts/[^/]+/apps/[^/]+/[^/]+/[^/]+/.+\.json$"#,
                            options: .regularExpression) != nil
    }

    static func kind(of url: String) -> ConfigKind? {
        let path = url.components(separatedBy: "?")[0]
        let patterns: [(ConfigKind, String)] = [
            (.pluginConfigurations, #"plugin_?configurations?[\w-]*\.json"#),
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
    /// it. CMS URLs win, then captured requests, then URLs in storage, then
    /// the path Zapp builds from account, bundle, store and version.
    public static func configFiles(
        leaves: [StorageLeaf],
        network: [(url: String, body: String?)],
        cms: [ConfigKind: String] = [:]
    ) -> [ConfigKind: ConfigFile] {
        var out: [ConfigKind: ConfigFile] = [:]
        for (kind, url) in cms where isAllowedConfigURL(url) {
            out[kind] = ConfigFile(url: url, body: network.first { $0.url == url }?.body, found: "CMS")
        }
        var candidates = network.map { ConfigFile(url: $0.url, body: $0.body, found: "captured request") }
        for leaf in leaves {
            for url in allGroups(#"(https?://[^\s"'\\]+\.json[^\s"'\\]*)"#, in: leaf.text ?? "").map({ $0[0] }) {
                candidates.append(ConfigFile(url: url, body: nil, found: "storage"))
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
            candidates.append(ConfigFile(url: base + "/rivers/rivers.json", body: nil, found: "derived from storage"))
            candidates.append(ConfigFile(url: base + "/layouts/layout.json", body: nil, found: "derived from storage"))
        }
        for c in candidates where isAllowedConfigURL(c.url) {
            guard let kind = kind(of: c.url), out[kind]?.found != "CMS" else { continue }
            if out[kind] == nil || (out[kind]!.body == nil && c.body != nil) { out[kind] = c }
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
        for screen in list((json as? [String: Any])?["screens"]) {
            for component in list(screen["ui_components"]) {
                guard let id = (component["styles"] as? [String: Any])?["cell_plugin_configuration_id"] as? String,
                      !id.isEmpty else { continue }
                if usedIn[id] == nil { order.append(id); usedIn[id] = [] }
                let name = "\(screen["name"] ?? "")"
                if !usedIn[id]!.contains(name) { usedIn[id]!.append(name) }
            }
        }
        return order.map { id in
            CellStyle(id: id, plugin: known.first { $0.id == id }?.plugin
                      ?? "used in: " + usedIn[id]!.joined(separator: ", "))
        }
    }

    public static func layoutName(_ json: Any) -> String? {
        (json as? [String: Any])?["name"] as? String
    }

    public static func plugins(fromConfigurations json: Any) -> [Plugin] {
        list(json).compactMap { p in
            guard let id = [p["identifier"], p["plugin_identifier"], p["id"]].lazy.compactMap({ $0 as? String }).first
            else { return nil }
            return Plugin(id: id, version: [p["version"], p["plugin_version"]].lazy.compactMap { $0 as? String }.first)
        }
    }

    // MARK: - CMS build_params

    /// build_params field → App Info label; the CMS wins over storage.
    static let cmsLabels: [(String, String)] = [
        ("app_name", "App name"), ("bundle_identifier", "Bundle id"), ("version_name", "App version"),
        ("build_version", "Build number"), ("sdk_version", "SDK version"),
        ("quick_brick_version", "QuickBrick version"), ("version_id", "Zapp version id"),
        ("accounts_account_id", "Account id"), ("app_family_id", "App family id"),
        ("rivers_configuration_id", "Layout id"), ("device_target", "Device target"), ("store", "Store"),
    ]

    public static func mergeBuildParams(_ identity: [InfoRow], _ params: [String: Any]?) -> [InfoRow] {
        guard let params else { return identity }
        let cms = cmsLabels.compactMap { key, label -> InfoRow? in
            guard let value = params[key], let t = text(value), !t.isEmpty else { return nil }
            return InfoRow(label: label, value: t, source: "CMS")
        }
        let labels = Set(cms.map(\.label))
        return cms + identity.filter { !labels.contains($0.label) }
    }

    /// The config URLs build_params names, by kind.
    public static func cmsConfigURLs(_ params: [String: Any]?) -> [ConfigKind: String] {
        var out: [ConfigKind: String] = [:]
        for (kind, key) in [(ConfigKind.layout, "layout_url"), (.rivers, "rivers_url"),
                            (.pluginConfigurations, "plugin_configurations_url")] {
            if let url = params?[key] as? String, !url.isEmpty { out[kind] = url }
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
