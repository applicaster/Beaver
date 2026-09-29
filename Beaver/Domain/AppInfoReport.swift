//
//  AppInfoReport.swift
//  Beaver
//
//  D79: the Info tab and `app_info` read the same report — storage, captured
//  requests and logs, the Zapp CMS's build_params when a Zapp token is set,
//  and the app's launch-time JSON from Zapp's public bucket.

import Foundation
import Security

public struct AppInfoReport: Sendable {
    public struct Config: Sendable, Equatable {
        public let url: String
        public let found: String
        /// Nil when the JSON loaded, or wasn't needed (only listed).
        public let error: String?
        /// Set when the file is saved with the session: open it by its hash.
        public var savedAt: Date? = nil
        public var sha256: String? = nil
        public var size: Int? = nil
    }

    /// A config file found for a session, with its body when it was downloaded.
    public struct Fetched: Sendable {
        public let kind: AppInfo.ConfigKind
        public let url: String
        public let found: String
        public let data: Data?
        public let error: String?
    }

    public enum CMS: Sendable, Equatable {
        case noToken
        /// The app's storage has no Zapp version id to ask about.
        case noVersionId
        case loaded
        case failed(String)
    }

    public var device: AppInfo.Device
    public var identity: [InfoRow]
    public var screens: [AppInfo.Screen]
    public var screensSource: String
    public var cellStyles: [AppInfo.CellStyle]
    public var cellStylesSource: String
    public var plugins: [AppInfo.Plugin]
    public var pluginsSource: String
    public var configs: [AppInfo.ConfigKind: Config]
    /// When the config files were saved with the session; nil: read from Zapp now.
    public var configsSavedAt: Date?
    public var cms: CMS
    /// When the newest storage snapshot was taken; nil without storage.
    public var storageAsOf: Date?

    /// The session's Zapp version id from its storage, for Settings → Zapp → Test.
    public static func versionId(store: LogStore, sessionId: Int64) async -> String? {
        let session = try? await store.latestStorageSnapshot(sessionId: sessionId, namespace: .session)
        let local = try? await store.latestStorageSnapshot(sessionId: sessionId, namespace: .local)
        return AppInfo.find(AppInfo.leaves(session: session?.dataJSON, local: local?.dataJSON), ["version_id"])?.text
    }

    /// The session's storage and, with a token, the CMS's build_params.
    struct Inputs {
        var session: StorageSnapshot?
        var local: StorageSnapshot?
        var leaves: [StorageLeaf]
        var params: [String: Any]?
        var cms: CMS
    }

    static func inputs(store: LogStore, sessionId: Int64, http: ZappHTTP) async throws -> Inputs {
        let session = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: .session)
        let local = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: .local)
        let leaves = AppInfo.leaves(session: session?.dataJSON, local: local?.dataJSON)
        var cms = CMS.noToken
        var params: [String: Any]?
        if let token = http.token() {
            if let versionId = AppInfo.find(leaves, ["version_id"])?.text {
                do {
                    params = try await http.buildParams(versionId, token)
                    cms = .loaded
                } catch {
                    cms = .failed(error.localizedDescription)
                }
            } else {
                cms = .noVersionId
            }
        }
        return Inputs(session: session, local: local, leaves: leaves, params: params, cms: cms)
    }

    /// Every config file the session points to, with the bodies of the
    /// kinds `download` asks for (remote_configurations always: it names
    /// cell styles and presets).
    static func locate(_ inputs: Inputs, store: LogStore, sessionId: Int64, http: ZappHTTP,
                       download: (AppInfo.ConfigKind) -> Bool) async throws -> [Fetched] {
        let network = try await store.networkEntries(sessionId: sessionId)
            .filter { AppInfo.isAllowedConfigURL($0.url) }
            .map { (url: $0.url, body: $0.responseBody) }
        var files = AppInfo.configFiles(leaves: inputs.leaves, network: network, cms: AppInfo.cmsConfigURLs(inputs.params))

        func fetch(_ kind: AppInfo.ConfigKind, _ file: AppInfo.ConfigFile) async -> Fetched {
            guard download(kind) || kind == .remoteConfigurations else {
                return Fetched(kind: kind, url: file.url, found: file.found, data: nil, error: nil)
            }
            do {
                // A captured body may be cut at the SDK's 100 KB; fetch then.
                var data = file.body.map { Data($0.utf8) }
                if data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
                    guard let url = URL(string: file.url) else { throw URLError(.badURL) }
                    data = try await http.get(url)
                    _ = try JSONSerialization.jsonObject(with: data!)
                }
                return Fetched(kind: kind, url: file.url, found: file.found, data: data, error: nil)
            } catch {
                return Fetched(kind: kind, url: file.url, found: file.found, data: nil, error: error.localizedDescription)
            }
        }

        var out: [Fetched] = []
        if let remote = files.removeValue(forKey: .remoteConfigurations) {
            let fetched = await fetch(.remoteConfigurations, remote)
            out.append(fetched)
            let json = fetched.data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            for (kind, url) in AppInfo.remoteConfigURLs(json) where files[kind] == nil && AppInfo.isAllowedConfigURL(url) {
                files[kind] = AppInfo.ConfigFile(url: url, body: nil, found: "remote_configurations.json")
            }
        }
        for (kind, file) in files { out.append(await fetch(kind, file)) }
        return out
    }

    public static func build(store: LogStore, sessionId: Int64, http: ZappHTTP) async throws -> AppInfoReport {
        let inputs = try await inputs(store: store, sessionId: sessionId, http: http)
        let (session, local, leaves, params, cms) = (inputs.session, inputs.local, inputs.leaves, inputs.params, inputs.cms)

        var json: [AppInfo.ConfigKind: Any] = [:]
        var configs: [AppInfo.ConfigKind: Config] = [:]
        let saved = try await store.savedConfigs(sessionId: sessionId)
        if !saved.isEmpty {
            // Saved when the device connected: Zapp as the session saw it.
            for s in saved {
                configs[s.kind] = Config(url: s.url, found: s.found, error: s.error,
                                         savedAt: s.savedAt, sha256: s.sha256, size: s.size)
                if s.kind.isParsed, let sha = s.sha256, let data = try await store.configData(sha256: sha) {
                    json[s.kind] = try? JSONSerialization.jsonObject(with: data)
                }
            }
        } else {
            // Cell styles are 1–2 MB and nothing reads them: listed, not downloaded.
            for f in try await locate(inputs, store: store, sessionId: sessionId, http: http, download: \.isParsed) {
                configs[f.kind] = Config(url: f.url, found: f.found, error: f.error)
                json[f.kind] = f.data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
        }
        let savedAt = saved.first?.savedAt

        var identity = AppInfo.appIdentity(leaves)
        if let name = json[.layout].flatMap(AppInfo.layoutName) {
            identity.insert(InfoRow(label: "Layout name", value: name, source: "layout.json"), at: 0)
        }
        identity = AppInfo.mergeBuildParams(identity, params)

        let listed = json[.rivers].map(AppInfo.screens(fromRiversOrLayout:))
            ?? json[.layout].map(AppInfo.screens(fromRiversOrLayout:)) ?? []
        let visited = listed.isEmpty
            ? AppInfo.screens(fromLogs: try await store.screenLogPayloads(sessionId: sessionId)) : []
        let storageCells = AppInfo.cellStylesFromStorage(leaves)
        let pluginList = json[.pluginConfigurations].map(AppInfo.plugins(fromConfigurations:))

        return AppInfoReport(
            device: AppInfo.device(leaves),
            identity: identity,
            screens: listed.isEmpty ? visited : listed,
            screensSource: listed.isEmpty ? "visited this session, from logs"
                : json[.rivers] != nil ? "rivers.json" : "layout.json",
            cellStyles: json[.layout].map { AppInfo.cellStyles(fromLayout: $0, known: storageCells) } ?? storageCells,
            cellStylesSource: json[.layout] != nil ? "layout.json" : "local storage cache",
            plugins: pluginList ?? AppInfo.pluginsFromStorage(leaves),
            // The app's own list is the build's; Zapp's file is today's (or
            // the connect time's, when saved) and may have moved on.
            pluginsSource: pluginList == nil ? "session storage namespaces"
                : savedAt.map { "in Zapp at \($0.formatted(date: .abbreviated, time: .shortened)), may differ from the build" }
                    ?? "in Zapp now, may differ from the build",
            configs: configs,
            configsSavedAt: savedAt,
            cms: cms,
            storageAsOf: [session?.takenAt, local?.takenAt].compactMap { $0 }.max()
        )
    }
}

/// D79: a live session's config files, downloaded when its storage first
/// names the app and kept with it — so the session later shows Zapp as it
/// was then, not after the next publish.
public enum ConfigSnapshot {
    /// Downloads every file the session points to and saves it; returns how
    /// many were found (0: storage doesn't name the app yet — try again on
    /// the next snapshot). Already saved: saves nothing, returns their count.
    @discardableResult
    public static func capture(store: LogStore, sessionId: Int64, http: ZappHTTP) async throws -> Int {
        let saved = try await store.savedConfigs(sessionId: sessionId)
        guard saved.isEmpty else { return saved.count }
        let inputs = try await AppInfoReport.inputs(store: store, sessionId: sessionId, http: http)
        let files = try await AppInfoReport.locate(inputs, store: store, sessionId: sessionId, http: http) { _ in true }
        if !files.isEmpty { try await store.saveConfigs(sessionId: sessionId, files) }
        return files.count
    }

    /// Storage arrives every few seconds: one capture per session at a time,
    /// and none after one found the files.
    public actor Gate {
        public static let shared = Gate()
        private var busyOrDone: Set<Int64> = []
        public func run(_ sessionId: Int64, _ capture: @Sendable () async -> Int) async {
            guard busyOrDone.insert(sessionId).inserted else { return }
            if await capture() == 0 { busyOrDone.remove(sessionId) }
        }
    }
}

/// Beaver's only calls to Zapp: build_params with the person's own token,
/// and GETs of the allow-listed config bucket. Injected so tests stay offline.
public struct ZappHTTP: Sendable {
    public var token: @Sendable () -> String?
    public var buildParams: @Sendable (_ versionId: String, _ token: String) async throws -> [String: Any]
    public var get: @Sendable (URL) async throws -> Data

    public init(token: @escaping @Sendable () -> String?,
                buildParams: @escaping @Sendable (String, String) async throws -> [String: Any],
                get: @escaping @Sendable (URL) async throws -> Data) {
        self.token = token; self.buildParams = buildParams; self.get = get
    }

    /// No token and no network: storage, captured requests and logs only.
    public static let offline = ZappHTTP(
        token: { nil },
        buildParams: { _, _ in throw ZappError("offline") },
        get: { _ in throw ZappError("offline") }
    )

    public static let live = ZappHTTP(
        token: { ZappToken.read() },
        buildParams: { versionId, token in
            guard let request = buildParamsRequest(versionId: versionId, token: token) else {
                throw ZappError("\"\(versionId)\" isn't a Zapp version id")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 401, 403: throw ZappError("Zapp rejected the token — set a new one in Settings → Zapp")
            case 404: throw ZappError("Zapp doesn't know app version \(versionId)")
            case let code: throw ZappError("Zapp answered \(code)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = json["build_params"] as? [String: Any] else { throw ZappError("Zapp's answer has no build_params") }
            return params
        },
        get: { url in
            if let cached = await ConfigCache.shared.data(for: url) { return cached }
            let data = try await download(url)
            await ConfigCache.shared.store(data, for: url)
            return data
        }
    )

    /// `live` without the run's cache: what Zapp has this minute, for saving.
    public static let liveUncached = ZappHTTP(token: live.token, buildParams: live.buildParams, get: download)

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ZappError("\(url.lastPathComponent): HTTP \(code)") }
        return data
    }
}

extension ZappHTTP {
    /// Nil when `versionId` isn't shaped like a Zapp version id.
    static func buildParamsRequest(versionId: String, token: String) -> URLRequest? {
        guard versionId.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil else { return nil }
        var url = URLComponents(string: "https://zapp.applicaster.com/api/v1/admin/build_params")!
        url.queryItems = [URLQueryItem(name: "app_version_id", value: versionId),
                          URLQueryItem(name: "access_token", value: token)]
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Settings → Zapp → Test (D92): one build_params call with the token.
public enum ZappTokenCheck: Sendable, Equatable {
    case accepted
    case rejected
    /// Zapp couldn't be asked, or answered something else.
    case unknown(String)

    /// A version id Zapp doesn't have: past the token check it answers 404.
    public static let probeVersionId = "00000000-0000-0000-0000-000000000000"

    /// 200 or 404 got past the token check; 401 and 403 didn't.
    public init(status: Int) {
        switch status {
        case 200, 404: self = .accepted
        case 401, 403: self = .rejected
        default: self = .unknown("Zapp answered \(status)")
        }
    }

    /// Asks about `versionId` (the viewed session's) or, without a usable
    /// one, the probe id.
    public static func run(token: String, versionId: String?) async -> ZappTokenCheck {
        let request = versionId.flatMap { ZappHTTP.buildParamsRequest(versionId: $0, token: token) }
            ?? ZappHTTP.buildParamsRequest(versionId: probeVersionId, token: token)!
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ZappTokenCheck(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }
}

public struct ZappError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Config files are per app version, so one download serves the whole run;
/// the Info tab's Reload empties it.
public actor ConfigCache {
    public static let shared = ConfigCache()
    private var files: [URL: Data] = [:]
    func data(for url: URL) -> Data? { files[url] }
    func store(_ data: Data, for url: URL) { files[url] = data }
    public func clear() { files = [:] }
}

/// The person's Zapp access token (the one zapptool uses), in the login keychain.
public enum ZappToken {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.applicaster.beaver.zapp-token",
        kSecAttrAccount as String: "zapp",
    ] }

    public static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Posted by `write`, so the Info tab asks the CMS again.
    public static let didChange = Notification.Name("BeaverZappTokenDidChange")

    /// Nil or empty removes it.
    @discardableResult
    public static func write(_ token: String?) -> Bool {
        defer { NotificationCenter.default.post(name: didChange, object: nil) }
        SecItemDelete(query as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
