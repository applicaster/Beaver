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
        /// Nil when the JSON loaded.
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
    public var cms: CMS
    /// When the newest storage snapshot was taken; nil without storage.
    public var storageAsOf: Date?

    public static func build(store: LogStore, sessionId: Int64, http: ZappHTTP) async throws -> AppInfoReport {
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

        let network = try await store.networkEntries(sessionId: sessionId)
            .filter { AppInfo.isAllowedConfigURL($0.url) }
            .map { (url: $0.url, body: $0.responseBody) }
        let files = AppInfo.configFiles(leaves: leaves, network: network, cms: AppInfo.cmsConfigURLs(params))
        var json: [AppInfo.ConfigKind: Any] = [:]
        var configs: [AppInfo.ConfigKind: Config] = [:]
        for (kind, file) in files {
            do {
                // A captured body may be cut at the SDK's 100 KB; fetch then.
                if let body = file.body, let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)) {
                    json[kind] = parsed
                } else {
                    guard let url = URL(string: file.url) else { throw URLError(.badURL) }
                    json[kind] = try JSONSerialization.jsonObject(with: try await http.get(url))
                }
                configs[kind] = Config(url: file.url, found: file.found, error: nil)
            } catch {
                configs[kind] = Config(url: file.url, found: file.found, error: error.localizedDescription)
            }
        }

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
            // The app's own list is the build's; Zapp's file is today's and
            // may have moved on (a plugin bumped without a rebuild).
            pluginsSource: pluginList != nil ? "in Zapp now, may differ from the build" : "session storage namespaces",
            configs: configs,
            cms: cms,
            storageAsOf: [session?.takenAt, local?.takenAt].compactMap { $0 }.max()
        )
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

    public static let live = ZappHTTP(
        token: { ZappToken.read() },
        buildParams: { versionId, token in
            guard versionId.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil else {
                throw ZappError("\"\(versionId)\" isn't a Zapp version id")
            }
            var url = URLComponents(string: "https://zapp.applicaster.com/api/v1/admin/build_params")!
            url.queryItems = [URLQueryItem(name: "app_version_id", value: versionId),
                              URLQueryItem(name: "access_token", value: token)]
            var request = URLRequest(url: url.url!, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 401, 403: throw ZappError("Zapp rejected the token — set a new one in the app menu")
            case 404: throw ZappError("Zapp doesn't know app version \(versionId)")
            case let code: throw ZappError("Zapp answered \(code)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = json["build_params"] as? [String: Any] else { throw ZappError("Zapp's answer has no build_params") }
            return params
        },
        get: { url in
            if let cached = await ConfigCache.shared.data(for: url) { return cached }
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw ZappError("\(url.lastPathComponent): HTTP \(code)") }
            await ConfigCache.shared.store(data, for: url)
            return data
        }
    )
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

    /// Nil or empty removes it.
    @discardableResult
    public static func write(_ token: String?) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
