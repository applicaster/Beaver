//
//  AppInfoReport.swift
//  Beaver
//
//  D79: the Info tab and `app_info` read the same report — storage, captured
//  requests and logs, and the app's launch-time JSON from Zapp's public
//  bucket. No Zapp token: the app's storage names everything (D96).

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

    public var device: AppInfo.Device
    public var identity: [InfoRow]
    public var screens: [AppInfo.Screen]
    public var screensSource: String
    public var cellStyles: [AppInfo.CellStyle]
    public var cellStylesSource: String
    /// From layout.json; empty without it.
    public var typeMapping: [AppInfo.TypeMapping]
    public var navigation: [AppInfo.NavItem]
    /// From the pipes endpoints file.
    public var dataSources: [AppInfo.DataSource]
    /// The storage keys data sources send (login tokens…): stored or not.
    public var sentKeys: [InfoRow]
    /// From remote_configurations.
    public var iconURL: String?
    public var plugins: [AppInfo.Plugin]
    public var pluginsSource: String
    public var configs: [AppInfo.ConfigKind: Config]
    /// When the config files were saved with the session; nil: read from Zapp now.
    public var configsSavedAt: Date?
    /// When the newest storage snapshot was taken; nil without storage.
    public var storageAsOf: Date?
    /// What the app said it was built with (D85); nil when it wasn't asked or couldn't be.
    public var build: AppBuild?
    /// The build's plugins beside Zapp's (D85). Without the build's list:
    /// Zapp's, each "build not confirmed".
    public var pluginRows: [AppBuild.PluginRow]
    /// Why the build's plugin list isn't known; nil when it is.
    public var pluginsNotConfirmed: String?

    /// The session's latest storage, both layers.
    struct Inputs {
        var session: StorageSnapshot?
        var local: StorageSnapshot?
        var leaves: [StorageLeaf]
        /// Session, local and keychain: only to tell whether a key is stored.
        var allLeaves: [StorageLeaf]
    }

    static func inputs(store: LogStore, sessionId: Int64) async throws -> Inputs {
        let session = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: .session)
        let local = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: .local)
        let keychain = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: .keychain)
        return Inputs(session: session, local: local, leaves: AppInfo.leaves(session: session?.dataJSON, local: local?.dataJSON),
                      allLeaves: AppInfo.leaves(session: session?.dataJSON, local: local?.dataJSON, keychain: keychain?.dataJSON))
    }

    /// Every config file the session points to, with the bodies of the
    /// kinds `download` asks for (remote_configurations always: it names
    /// cell styles and presets).
    static func locate(_ inputs: Inputs, store: LogStore, sessionId: Int64, http: ZappHTTP,
                       download: (AppInfo.ConfigKind) -> Bool) async throws -> [Fetched] {
        let network = try await store.networkEntries(sessionId: sessionId)
            .filter { AppInfo.isAllowedConfigURL($0.url) }
            .map { (url: $0.url, body: $0.responseBody) }
        var files = AppInfo.configFiles(leaves: inputs.leaves, network: network)

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
            var named = AppInfo.remoteConfigURLs(json)
            named[.localization] = AppInfo.localizationURL(fromRemote: json, leaves: inputs.leaves)
            for (kind, url) in named where files[kind] == nil && AppInfo.isAllowedConfigURL(url) {
                files[kind] = AppInfo.ConfigFile(url: url, body: nil, found: "remote_configurations.json")
            }
        }
        for (kind, file) in files { out.append(await fetch(kind, file)) }
        return out
    }

    public static func build(store: LogStore, sessionId: Int64, http: ZappHTTP) async throws -> AppInfoReport {
        let inputs = try await inputs(store: store, sessionId: sessionId)
        let (session, local, leaves) = (inputs.session, inputs.local, inputs.leaves)

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
        let languages = AppInfo.languages(fromRemote: json[.remoteConfigurations])
        if !languages.isEmpty {
            identity.append(InfoRow(label: "Languages", value: languages.joined(separator: ", "), source: "remote_configurations.json"))
        }
        let build = try await store.appBuild(sessionId: sessionId).flatMap { AppBuild(json: $0.json, fetchedAt: $0.fetchedAt) }
        if let build { identity = AppBuild.merge(identity, build) }
        if !identity.contains(where: { $0.label == "Account id" }),
           let account = AppInfo.accountId(fromConfigURLs: configs.values.map(\.url)) {
            identity.append(InfoRow(label: "Account id", value: account, source: "config file URL"))
        }

        let listed = json[.rivers].map(AppInfo.screens(fromRiversOrLayout:))
            ?? json[.layout].map(AppInfo.screens(fromRiversOrLayout:)) ?? []
        let visited = listed.isEmpty
            ? AppInfo.screens(fromLogs: try await store.screenLogPayloads(sessionId: sessionId)) : []
        let storageCells = AppInfo.cellStylesFromStorage(leaves)
        let pluginList = json[.pluginConfigurations].map(AppInfo.plugins(fromConfigurations:))
        let dataSources = json[.pipesEndpoints].map(AppInfo.dataSources(fromEndpoints:)) ?? []

        return AppInfoReport(
            device: AppInfo.device(leaves),
            identity: identity,
            screens: listed.isEmpty ? visited : listed,
            screensSource: listed.isEmpty ? "visited this session, from logs"
                : json[.rivers] != nil ? "rivers.json" : "layout.json",
            cellStyles: json[.layout].map { AppInfo.cellStyles(fromLayout: $0, known: storageCells) } ?? storageCells,
            cellStylesSource: json[.layout] != nil ? "layout.json" : "local storage cache",
            typeMapping: json[.layout].map(AppInfo.typeMapping(fromLayout:)) ?? [],
            navigation: json[.layout].map(AppInfo.navigation(fromLayout:)) ?? [],
            dataSources: dataSources,
            sentKeys: AppInfo.sentKeys(dataSources, leaves: inputs.allLeaves),
            iconURL: AppInfo.iconURL(fromRemote: json[.remoteConfigurations]),
            plugins: pluginList ?? AppInfo.pluginsFromStorage(leaves),
            // The app's own list is the build's; Zapp's file is today's (or
            // the connect time's, when saved) and may have moved on.
            pluginsSource: pluginList == nil ? "session storage namespaces"
                : savedAt.map { "in Zapp at \($0.formatted(date: .abbreviated, time: .shortened)), may differ from the build" }
                    ?? "in Zapp now, may differ from the build",
            configs: configs,
            configsSavedAt: savedAt,
            storageAsOf: [session?.takenAt, local?.takenAt].compactMap { $0 }.max(),
            build: build,
            pluginRows: AppBuild.pluginRows(build: build?.plugins, zapp: pluginList),
            pluginsNotConfirmed: build?.plugins != nil ? nil
                : build?.pluginsNote ?? "the app wasn't asked: it wasn't connected with X-Ray's native sink (or the session is older than Beaver 4.20)"
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
        let inputs = try await AppInfoReport.inputs(store: store, sessionId: sessionId)
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

/// Beaver's only calls to Zapp: GETs of the allow-listed config bucket.
/// Injected so tests stay offline.
public struct ZappHTTP: Sendable {
    public var get: @Sendable (URL) async throws -> Data

    public init(get: @escaping @Sendable (URL) async throws -> Data) {
        self.get = get
    }

    /// No network: storage, captured requests and logs only.
    public static let offline = ZappHTTP(get: { _ in throw ZappError("offline") })

    public static let live = ZappHTTP(get: { url in
        if let cached = await ConfigCache.shared.data(for: url) { return cached }
        let data = try await download(url)
        await ConfigCache.shared.store(data, for: url)
        return data
    })

    /// `live` without the run's cache: what Zapp has this minute, for saving.
    public static let liveUncached = ZappHTTP(get: download)

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ZappError("\(url.lastPathComponent): HTTP \(code)") }
        return data
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

/// D96: Beaver no longer uses a Zapp token (D92's Settings → Zapp). One
/// saved by an older build is removed at launch: an unused secret
/// shouldn't stay in the keychain.
public enum LegacyZappToken {
    public static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.applicaster.beaver.zapp-token",
            kSecAttrAccount as String: "zapp",
        ] as CFDictionary)
    }
}
