//
//  AppBuild.swift
//  Beaver
//
//  D85: what the running app says it was built with — X-Ray's `app.info`
//  (identity) and `build.plugins` (the plugins bundled at build time),
//  asked once per live session through the device MCP gateway (D75) and
//  kept with the session. Plugin *versions* change only with a rebuild;
//  their configuration comes from Zapp at launch (D79 saves that).

import Foundation
import os

public struct AppBuild: Sendable, Equatable {
    public let fetchedAt: Date
    /// `app.info`'s fields as rows, source "app.info"; empty without it.
    public let rows: [InfoRow]
    /// `build.plugins`: the build's bundled plugins; nil when unknown.
    public let plugins: [AppInfo.Plugin]?
    /// Why `plugins` is nil, in a few words, for "build not confirmed".
    public let pluginsNote: String?

    public static let source = "app.info"

    /// app.info key → App Info label; identity labels match `AppInfo.appIdentity`.
    static let labels: [(String, String)] = [
        ("bundleId", "Bundle id"), ("packageName", "Package name"), ("version", "App version"),
        ("buildNumber", "Build number"), ("sdkVersion", "SDK version"),
        ("quickbrickVersion", "QuickBrick version"), ("layoutId", "Layout id"), ("uuid", "UUID"),
        ("platform", "Platform"), ("debugEnvironment", "Debug environment"),
    ]

    /// The rows that mean the same as an identity row from storage.
    static let identityLabels: Set<String> = [
        "Bundle id", "App version", "Build number", "SDK version", "QuickBrick version", "Layout id",
    ]

    /// What the store keeps: `{"appInfo": {…}|null, "buildPlugins": […]|null, "buildPluginsNote": "…"|null}`.
    public static func stored(appInfo: JSON?, buildPlugins: JSON?, note: String?) -> String {
        JSON.object(["appInfo": appInfo ?? .null, "buildPlugins": buildPlugins ?? .null, "buildPluginsNote": JSON(note)]).text
    }

    public init?(json: String, fetchedAt: Date) {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let object = root["appInfo"] as? [String: Any] ?? [:]
        func value(_ key: String) -> String? { object[key].flatMap(AppInfo.text).flatMap { $0.isEmpty ? nil : $0 } }
        var rows: [InfoRow] = []
        for (key, label) in Self.labels {
            guard let v = value(key) else { continue }
            // iOS sends its bundle id as packageName too.
            if key == "packageName", v == value("bundleId") { continue }
            rows.append(InfoRow(label: label, value: v, source: Self.source))
        }
        // Fields a newer SDK adds show under their own name.
        let known = Set(Self.labels.map(\.0))
        for key in object.keys.sorted() where !known.contains(key) {
            if let v = value(key) { rows.append(InfoRow(label: key, value: v, source: Self.source)) }
        }
        self.rows = rows
        self.plugins = (root["buildPlugins"] as? [Any]).map { list in
            list.compactMap { entry -> AppInfo.Plugin? in
                guard let p = entry as? [String: Any], let id = p["id"] as? String, !id.isEmpty else { return nil }
                return AppInfo.Plugin(id: id, version: p["version"].flatMap(AppInfo.text), name: p["name"] as? String)
            }
        }
        self.pluginsNote = plugins == nil ? (root["buildPluginsNote"] as? String) : nil
        self.fetchedAt = fetchedAt
    }

    // MARK: - Asking the app

    private static let log = Logger(subsystem: "com.applicaster.LoggerNext", category: "AppBuild")

    /// What one tool call gave.
    enum Answer: Equatable {
        /// The tool's value; `.null` is an answer too (build.plugins on an older CLI).
        case value(JSON)
        /// "Unknown tool": the app's X-Ray predates it.
        case noTool
        /// It answered with an error, or nothing usable.
        case failed(String)
    }

    /// Asks the app for `app.info` and `build.plugins` and stores what it
    /// says. Nothing is stored when the app has no MCP server at all. A busy
    /// line or a slow app gets two more tries, `retryAfter` apart. Never
    /// activates anything.
    public static func fetch(from device: any DeviceLink, store: LogStore, sessionId: Int64,
                             retryAfter: Duration = .seconds(5)) async {
        guard let info = await call("app.info", device: device, sessionId: sessionId, retryAfter: retryAfter) else { return }
        let plugins = await call("build.plugins", device: device, sessionId: sessionId, retryAfter: retryAfter)
            ?? .failed("the app didn't answer")
        var appInfo: JSON?
        if case .value(let v) = info, v.object != nil { appInfo = v }
        var list: JSON?
        var note: String?
        switch plugins {
        case .value(let v) where v.array != nil: list = v
        case .value: note = "built with a QuickBrick CLI that doesn't record its plugins"
        case .noTool: note = "this app's X-Ray has no build.plugins (older X-Ray)"
        case .failed(let why): note = "build.plugins failed: \(why)"
        }
        do {
            try await store.recordAppBuild(sessionId: sessionId,
                                           json: stored(appInfo: appInfo, buildPlugins: list, note: note))
        } catch {
            log.debug("Session \(sessionId): couldn't store the build (\(error.localizedDescription))")
        }
    }

    /// One tools/call; nil when the app couldn't be asked at all (no MCP,
    /// gone, still busy after three tries).
    static func call(_ name: String, device: any DeviceLink, sessionId: Int64, retryAfter: Duration) async -> Answer? {
        for attempt in 1...3 {
            do {
                let reply = try await device.mcp("tools/call", params: ["name": .string(name), "arguments": [:]],
                                                 to: sessionId, timeout: DeviceMCPClient.listTimeout)
                return answer(fromCallResult: reply)
            } catch DeviceMCPError.timeout where attempt < 3 {
            } catch DeviceMCPError.notSent where attempt < 3 {
            } catch {
                log.debug("Session \(sessionId): no \(name) (\(String(describing: error)))")
                return nil
            }
            try? await Task.sleep(for: retryAfter)
        }
        return nil
    }

    /// A tools/call result → its value: `structuredContent` (an array may
    /// come wrapped as `{result: […]}`), else the text parsed as JSON.
    static func answer(fromCallResult reply: JSON) -> Answer {
        let text = reply["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
        if reply["isError"]?.bool == true {
            return text.localizedCaseInsensitiveContains("unknown tool") ? .noTool : .failed(String(text.prefix(200)))
        }
        if let structured = reply["structuredContent"] {
            if let wrapped = structured["result"], structured.object?.count == 1 { return .value(wrapped) }
            return .value(structured)
        }
        guard let parsed = try? JSON.parse(Data(text.utf8)) else {
            return .failed(text.isEmpty ? "empty answer" : "not JSON")
        }
        return .value(parsed)
    }

    // MARK: - Against storage and Zapp

    /// The app's value wins for what it reports. A storage value that
    /// differs stays below it, labelled "(storage)".
    public static func merge(_ identity: [InfoRow], _ build: AppBuild) -> [InfoRow] {
        let own = build.rows.filter { identityLabels.contains($0.label) }
        var out: [InfoRow] = []
        for row in identity {
            guard let mine = own.first(where: { $0.label == row.label }) else { out.append(row); continue }
            out.append(mine)
            if row.value != mine.value {
                out.append(InfoRow(label: "\(row.label) (storage)", value: row.value, source: row.source))
            }
        }
        return out + own.filter { mine in !identity.contains { $0.label == mine.label } }
    }

    /// One plugin as the build has it and as Zapp has it now.
    public struct PluginRow: Sendable, Equatable {
        public enum Status: String, Sendable {
            case same = "same"
            case rebuildNeeded = "Zapp has another version: rebuild to pick it up"
            case onlyInBuild = "not in Zapp now"
            case onlyInZapp = "not in this build: rebuild to add it"
            /// The build's list isn't known: Zapp's version, not confirmed.
            case notConfirmed = "build not confirmed"
            /// Zapp's list isn't loaded: nothing to compare with.
            case zappUnknown = "not compared: Zapp's list isn't loaded"
        }
        public let id: String
        public let name: String?
        public let build: String?
        public let zapp: String?
        public let status: Status
    }

    /// Build and Zapp side by side, by plugin id: the build's order, then
    /// what only Zapp has. An unknown version isn't a difference. Without
    /// the build's list, Zapp's, each `notConfirmed`.
    public static func pluginRows(build: [AppInfo.Plugin]?, zapp: [AppInfo.Plugin]?) -> [PluginRow] {
        guard let build else {
            return (zapp ?? []).map { PluginRow(id: $0.id, name: $0.name, build: nil, zapp: $0.version, status: .notConfirmed) }
        }
        guard let zapp else {
            return build.map { PluginRow(id: $0.id, name: $0.name, build: $0.version, zapp: nil, status: .zappUnknown) }
        }
        let inZapp = Dictionary(zapp.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inBuild = Set(build.map(\.id))
        var out = build.map { b -> PluginRow in
            guard let z = inZapp[b.id] else {
                return PluginRow(id: b.id, name: b.name, build: b.version, zapp: nil, status: .onlyInBuild)
            }
            let differs = b.version != nil && z.version != nil && b.version != z.version
            return PluginRow(id: b.id, name: b.name, build: b.version, zapp: z.version, status: differs ? .rebuildNeeded : .same)
        }
        out += zapp.filter { !inBuild.contains($0.id) }
            .map { PluginRow(id: $0.id, name: $0.name, build: nil, zapp: $0.version, status: .onlyInZapp) }
        return out
    }
}
