//
//  BeaverApp.swift
//  Beaver
//

import Sparkle
import SwiftUI
import os

@main
struct BeaverApp: App {

    @State private var env: AppEnvironment

    /// Window-level toast surface. Single instance shared across every
    /// view that wants to confirm an action ("Copied!", "Bookmark
    /// added", …). Lives at the App level so it survives every
    /// tab / window mutation.
    @State private var toasts: ToastCenter
    /// The Settings window's own toasts: they show where the person is,
    /// not in the main window too.
    @State private var settingsToasts = ToastCenter()

    /// Settings → General → Delete sessions older than (D83, D92), in days; 0 is Never.
    @AppStorage(SessionRetention.key) private var retentionDays = SessionRetention.default.rawValue

    /// Agent Access (design §3.2): on by default, a toggle in Settings → Agents (D92).
    @AppStorage(AgentAccess.enabledKey) private var agentAccessEnabled = true
    private let agentAccess: AgentAccess

    /// Serializes `applyAgentAccess()` calls so a quick off→on toggle
    /// doesn't race the previous stop against the next start.
    @State private var agentAccessApply: Task<Void, Never>?

    /// Sparkle's standard controller — owns the updater process,
    /// runs the periodic appcast check, and presents the system
    /// "Update Available" dialog. Lives for the entire app lifetime.
    ///
    /// Public key is set via `INFOPLIST_KEY_SUPublicEDKey` build
    /// setting. Feed URL is set programmatically via `updaterDelegate`
    /// — Xcode's GENERATE_INFOPLIST_FILE doesn't reliably propagate
    /// third-party `INFOPLIST_KEY_*` settings into the built plist,
    /// so we provide the URL via SPUUpdaterDelegate.feedURLString(for:)
    /// instead. See DECISIONS.md D22.
    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = BeaverUpdaterDelegate()

    init() {
        // Build the environment synchronously on the main actor.
        let store: LogStore
        let ranBefore: Bool
        do {
            let url = try LogStore.defaultStoreURL()
            ranBefore = FileManager.default.fileExists(atPath: url.path)
            store = try LogStore(source: .onDisk(url))
        } catch {
            fatalError("Failed to open log store: \(error)")
        }
        let server = WSServer(port: 9080)
        let environment = AppEnvironment(store: store, server: server)
        // D92: the first launch of a new version shows what changed since
        // the last one seen; a fresh install shows nothing.
        environment.whatsNew = WhatsNew.atLaunch(.bundled, current: Changelog.appVersion, ranBefore: ranBefore)
        // The Log feed's filter lives in env (D54); a launch starts with
        // the one last used, as LogFeedViewModel did on its own before,
        // or with the saved filter marked Default (D82).
        environment.activeFilter = LogFeedViewModel.rememberedFilter()
        environment.startFromDefaultFilter()
        _env = State(initialValue: environment)
        let toastCenter = ToastCenter()
        _toasts = State(initialValue: toastCenter)
        agentAccess = AgentAccess(store: store, ui: environment, device: environment)
        // design M28: permission read and click delegate ready at launch,
        // before the first attention note or an old notification's click.
        _ = AgentNotifier.shared

        // Sparkle: `startingUpdater: true` schedules checks on its
        // 24-hour interval; the background check below adds one on
        // every launch. Updates download on their own and the
        // delegate asks to restart. Users can also check via the
        // "Check for Updates…" menu item below.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        updaterController.updater.checkForUpdatesInBackground()

        // Start the server and wire up the inbound pipeline.
        Task { [env = _env.wrappedValue] in
            await Self.bootstrap(env: env)
        }

        // D83: delete old sessions a few seconds after launch, once the
        // window's first loads are done, then daily while Beaver runs.
        Task { [env = _env.wrappedValue] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await Self.deleteOldSessions(env: env, toasts: toastCenter)
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(env)
                .environment(toasts)
                .task { await scheduleAgentAccessApply() }
                // Hides the title but keeps a real title bar, so a double-click
                // on the toolbar's empty space zooms. `.hiddenTitleBar` left only
                // the sidebar's strip doing that.
                .toolbar(removing: .title)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { /* disable new window */ }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                Button("What's New…") {
                    NSApp.activate()
                    env.whatsNew = WhatsNew.history(.bundled, current: Changelog.appVersion)
                }
                Button("Copy WebSocket Address") {
                    // Full ws://<ip>:9080 URL — matches the toolbar
                    // "Copy IP" button. Both forms (with / without
                    // scheme) work in the SDK; the prefixed form is
                    // more directly pasteable.
                    let host = NetworkInterface.bestAddress() ?? "localhost"
                    let url = "ws://\(host):9080"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    toasts.success("Copied \(url)")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                // D94: a TV connects from Beaver, not from an SDK.
                Button("Connect a TV…") {
                    NSApp.activate()
                    env.showingConnectTV = true
                }
                // Settings live in Settings… (D92); the actions stay here.
                Button("Copy MCP Setup Command") {
                    let command = AgentAccess.setupCommand(port: env.agentAccessPort ?? AgentAccess.configuredPort())
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    toasts.success("Copied: \(command)")
                }
                .disabled(env.agentAccessPort == nil)
            }
        }

        // D92 (amends D62): Beaver → Settings… (⌘,) and the sidebar's gear.
        Settings {
            SettingsView(retentionDays: retentionBinding, agentAccessEnabled: agentAccessBinding,
                         applyAgentAccess: { await scheduleAgentAccessApply() },
                         updater: updaterController.updater)
                .environment(env)
                .environment(settingsToasts)
        }
    }

    /// Applies at once, not in an `.onChange` on the main window: Settings
    /// works with that window closed.
    private var agentAccessBinding: Binding<Bool> {
        Binding(get: { agentAccessEnabled }, set: { on in
            agentAccessEnabled = on
            Task { await scheduleAgentAccessApply() }
        })
    }

    private var retentionBinding: Binding<Int> {
        Binding(get: { retentionDays }, set: { days in
            retentionDays = days
            // A choice made in Settings is informed: no grace day (D83).
            UserDefaults.standard.set(Date(), forKey: SessionRetention.startsAtKey)
            Task { await Self.deleteOldSessions(env: env, toasts: toasts) }
        })
    }

    /// Wires the server's inbound stream into the store, and tracks
    /// connection state for the UI. Spawned once at app launch.
    private static func bootstrap(env: AppEnvironment) async {
        // Start listening.
        do {
            try await env.server.start()
        } catch {
            env.serverState = .failed(reason: error.localizedDescription)
            return
        }

        // Track server state on the main actor.
        Task { @MainActor in
            for await state in env.server.state {
                env.serverState = state
            }
        }

        // Open and end live sessions in the same loop that stores frames,
        // so the session exists before the first frame and outlives the
        // last one. Driven from `server.state` instead, frames sent right
        // after the handshake were dropped.
        Task { @MainActor in
            for await item in env.server.inbound {
                switch item {
                case .connected(let connection):
                    env.mcpClients[connection] = DeviceMCPClient { [server = env.server] data in
                        await server.send(data: data, to: connection)
                    }
                    guard let session = try? await env.store.createSession(source: .live) else { continue }
                    env.didConnect(connection, session: session.id)
                    // Ask the SDK for its command list so the command-bar
                    // help popover has something to show, and for its
                    // storage, whose applicaster.v2 names the device in the
                    // device menu and beaver_status even while another one
                    // is viewed (D73). Brief delay so the SDK has finished
                    // registering its handlers. A `register` client (the TV
                    // bridge, D89) sent its frame by then; `send` drops both.
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await env.sendQuietCmdlist(to: session.id)
                        await env.send(command: "storage.list", to: session.id)
                    }
                case .frame(let connection, let frame):
                    guard let sessionId = env.live.session(for: connection) else {
                        // D75: while a deleted live session is being replaced,
                        // an MCP reply still reaches its request, and a
                        // handshake is kept: the replacement reads it from
                        // `live` (replaceDeletedLiveSessions).
                        switch ProtocolDecoder.decode(frame) {
                        case .success(.mcp(let message)):
                            await env.mcpClients[connection]?.receive(message)
                        case .success(.clientHandshake(let handshake)):
                            env.live.setHandshake(handshake, for: connection)
                            await Self.markMCP(env.mcpClients[connection], for: handshake)
                        default:
                            break
                        }
                        continue
                    }
                    await Self.handleInbound(frame: frame, connection: connection, sessionId: sessionId, env: env)
                case .disconnected(let connection):
                    await env.mcpClients.removeValue(forKey: connection)?.close()
                    if let sessionId = env.didDisconnect(connection) {
                        try? await env.store.endSession(sessionId)
                    }
                }
            }
        }

        // Keep the toolbar's "are there events to act on?" count fresh,
        // and react to session deletions so the viewing and live pointers
        // don't dangle on rows that no longer exist.
        Task { @MainActor in
            for await change in await env.store.changes() {
                switch change {
                case .appended(let sid, _) where sid == env.viewingSessionId:
                    await env.refreshViewingEventCount()
                case .cleared(let sid) where sid == env.viewingSessionId:
                    await env.refreshViewingEventCount()
                // Only the first request changes what the toolbar enables.
                case .networkAppended(let sid) where sid == env.viewingSessionId && env.viewingNetworkCount == 0:
                    await env.refreshViewingEventCount()
                case .sessionStarted, .sessionEnded:
                    await env.refreshViewingEventCount()
                case .sessionsDeleted(let ids):
                    let viewed = env.viewingSessionId
                    if let viewed, ids.contains(viewed) { env.viewingSessionId = nil }
                    await replaceDeletedLiveSessions(env: env, viewed: viewed) { ids.contains($0) }
                    await env.refreshViewingEventCount()
                case .sessionsCleared:
                    let viewed = env.viewingSessionId
                    env.viewingSessionId = nil
                    await replaceDeletedLiveSessions(env: env, viewed: viewed) { _ in true }
                    await env.refreshViewingEventCount()
                default:
                    break
                }
            }
        }
    }

    /// Chains onto the previous `applyAgentAccess()` call so a quick
    /// off→on toggle doesn't bind the port while the old listener is
    /// still closing — which would otherwise show a false "port in use".
    @MainActor
    private func scheduleAgentAccessApply() async {
        let previous = agentAccessApply
        let task = Task {
            await previous?.value
            await applyAgentAccess()
        }
        agentAccessApply = task
        await task.value
    }

    /// Starts or stops the MCP listener to match the toggle, and reports
    /// the result in Settings → Agents.
    @MainActor
    private func applyAgentAccess() async {
        guard agentAccessEnabled else {
            await agentAccess.stop()
            env.agentAccessPort = nil
            env.agentAccessStatus = "Off"
            return
        }
        let port = AgentAccess.configuredPort()
        do {
            let bound = try await agentAccess.start(port: port)
            env.agentAccessPort = bound
            env.agentAccessStatus = "On · 127.0.0.1:\(bound)"
        } catch is CancellationError {
            // Superseded by a later start/stop call; that call owns the
            // final status.
        } catch {
            Self.log.error("Agent Access failed to bind port \(port): \(error.localizedDescription)")
            env.agentAccessPort = nil
            env.agentAccessStatus = "Port \(port) in use"
        }
    }

    private static let log = Logger(subsystem: "com.applicaster.LoggerNext", category: "AgentAccess")

    /// One retention pass (D83); says what it did in a toast, or nothing.
    @MainActor
    private static func deleteOldSessions(env: AppEnvironment, toasts: ToastCenter) async {
        do {
            switch try await SessionRetention.run(store: env.store, live: Set(env.live.sessionIds)) {
            case .nothing:
                break
            case .notice(let pending):
                // The first pass after upgrade only announces (D83).
                let days = SessionRetention.current().rawValue
                toasts.show(
                    "From tomorrow Beaver deletes sessions older than \(days) days (\(pending) now). Set it in Settings (⌘,).",
                    icon: "info.circle.fill", tint: .accentColor, duration: 15,
                    action: ToastAction(title: "Keep All") {
                        UserDefaults.standard.set(SessionRetention.never.rawValue, forKey: SessionRetention.key)
                    })
            case .deleted(let count, let freed):
                toasts.show("Deleted \(count) old session\(count == 1 ? "" : "s"), freed \(freed.formatted(.byteCount(style: .file)))",
                            icon: "trash.circle.fill", tint: .accentColor, duration: 5)
            }
        } catch {
            retentionLog.error("Deleting old sessions failed: \(error.localizedDescription)")
        }
        env.storeSize = try? await env.store.databaseSize()
    }

    private static let retentionLog = Logger(subsystem: "com.applicaster.LoggerNext", category: "Retention")

    /// Only native sinks send a handshake, and they serve MCP (D75); a
    /// `register` client (D89) never does.
    private static func markMCP(_ client: DeviceMCPClient?, for handshake: ClientHandshake) async {
        if handshake.logsOnly { await client?.markLogsOnly() } else { await client?.markNative() }
    }

    private static func handleInbound(frame: Data, connection: UUID, sessionId: Int64, env: AppEnvironment) async {
        switch ProtocolDecoder.decode(frame) {
        case .success(.event(let event)):
            // Side-channel: detect cmdlist responses and populate the
            // command-help popover (see CommandHints.cmdListNames). The
            // reply to a cmdlist the person sent stays in the log feed;
            // one Beaver sent itself doesn't.
            if let names = CommandHints.cmdListNames(in: event) {
                let quiet = await MainActor.run {
                    env.live.receiveCmdlist(CommandHints.merge(sdkNames: names), for: sessionId)
                }
                if quiet { return }
            }
            await env.store.append(event, to: sessionId)
        case .success(.storage(let namespaces)):
            for (namespace, json) in namespaces {
                try? await env.store.recordStorageSnapshot(
                    sessionId: sessionId,
                    namespace: namespace,
                    dataJSON: json
                )
            }
            // D79: keep the app's config files as Zapp has them now, near
            // when the app loaded them. Off the inbound loop.
            let store = env.store
            Task.detached {
                await ConfigSnapshot.Gate.shared.run(sessionId) {
                    (try? await ConfigSnapshot.capture(store: store, sessionId: sessionId, http: .liveUncached)) ?? 0
                }
            }
        case .success(.network(let capture)):
            try? await env.store.recordNetworkEntry(capture, sessionId: sessionId)
        case .success(.clientHandshake(let handshake)):
            let client = await MainActor.run {
                env.live.setHandshake(handshake, for: connection)
                return env.mcpClients[connection]
            }
            await Self.markMCP(client, for: handshake)
            try? await env.store.applyHandshake(handshake, to: sessionId)
        case .success(.mcp(let message)):
            // D75: an answer to Beaver's request; not a log line.
            let client = await MainActor.run { env.mcpClients[connection] }
            await client?.receive(message)
        case .success(.unknown(let typeRaw)):
            // PROTOCOL.md §7: tolerate unknown types, log as a synthetic
            // event so the user sees them.
            await env.store.append(
                .syntheticInfo(
                    subsystem: "loggernext.protocol",
                    message: "unknown packet type: \(typeRaw)"
                ),
                to: sessionId
            )
        case .failure(let err):
            await env.store.append(
                .syntheticWarning(
                    subsystem: "loggernext.protocol",
                    message: "decode failed: \(err)"
                ),
                to: sessionId
            )
        }
    }
}

// MARK: - Helpers

/// A deleted live session (e.g., right after the user deleted every
/// session) leaves its device with nowhere to write: give each such
/// connection a fresh live session. Without this, events from the device
/// would be silently dropped until it reconnected.
///
/// Detaches first, before any await, so frames stop going to the deleted
/// rows at once (a write there fails its whole batch). The window follows
/// the device it showed; with none, it shows the first fresh session. A
/// device that leaves meanwhile gets its fresh session ended.
@MainActor
private func replaceDeletedLiveSessions(env: AppEnvironment, viewed: Int64?,
                                        deleted: (Int64) -> Bool) async {
    let viewedConnection = viewed.flatMap { env.live.connection(for: $0) }
    for connection in env.live.detach(where: deleted) {
        guard let fresh = try? await env.store.createSession(source: .live) else { continue }
        guard env.live.attach(connection, session: fresh.id) else {
            try? await env.store.endSession(fresh.id)
            continue
        }
        if let handshake = env.live.handshake(for: connection) {
            try? await env.store.applyHandshake(handshake, to: fresh.id)
        }
        if connection == viewedConnection || (viewedConnection == nil && env.viewingSessionId == nil) {
            env.viewingSessionId = fresh.id
        }
    }
}

// MARK: - Sparkle updater delegate

/// Provides the Sparkle appcast URL at runtime. We do this in code
/// rather than via `INFOPLIST_KEY_SUFeedURL` because Xcode's
/// GENERATE_INFOPLIST_FILE silently drops third-party plist keys
/// from the build settings → built Info.plist pipeline. The Ed25519
/// public key (`INFOPLIST_KEY_SUPublicEDKey`) IS reliably preserved
/// because Sparkle reads it via a documented path, but the URL needs
/// this delegate hook.
///
/// One source of truth, baked into the binary. If we ever need to
/// move the appcast (e.g., off GitHub Pages), bump this string and
/// ship a new version.
private final class BeaverUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://applicaster.github.io/Beaver/appcast.xml"
    }

    /// An update finished downloading in the background. A restart drops
    /// every connected device and agent, so ask instead of relaunching;
    /// "Later" leaves it to Sparkle, which installs it when Beaver quits.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // After returning: the handler only works once we've returned true.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Beaver \(item.displayVersionString) is ready to install"
            alert.informativeText = "Restarting disconnects every device and agent. If you choose Later, it installs the next time you quit Beaver."
            alert.addButton(withTitle: "Restart Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                immediateInstallHandler()
            }
        }
        return true
    }
}

// MARK: - Synthetic-event helpers

extension DecodedEvent {
    static func syntheticInfo(subsystem: String, message: String) -> DecodedEvent {
        DecodedEvent(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            level: .info,
            subsystem: subsystem,
            category: "loggernext",
            message: message,
            dataJSON: nil,
            contextJSON: nil
        )
    }

    static func syntheticWarning(subsystem: String, message: String) -> DecodedEvent {
        DecodedEvent(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            level: .warning,
            subsystem: subsystem,
            category: "loggernext",
            message: message,
            dataJSON: nil,
            contextJSON: nil
        )
    }
}
