//
//  BeaverApp.swift
//  Beaver
//

import Sparkle
import SwiftUI

@main
struct BeaverApp: App {

    @State private var env: AppEnvironment

    /// Window-level toast surface. Single instance shared across every
    /// view that wants to confirm an action ("Copied!", "Bookmark
    /// added", …). Lives at the App level so it survives every
    /// tab / window mutation.
    @State private var toasts = ToastCenter()

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
        do {
            let url = try LogStore.defaultStoreURL()
            store = try LogStore(source: .onDisk(url))
        } catch {
            fatalError("Failed to open log store: \(error)")
        }
        let server = WSServer(port: 9080)
        _env = State(initialValue: AppEnvironment(store: store, server: server))

        // Sparkle: `startingUpdater: true` schedules the first
        // appcast check shortly after launch. Subsequent checks run
        // on Sparkle's default 24-hour interval; users can also
        // trigger one manually via the "Check for Updates…" menu
        // item below.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        // Start the server and wire up the inbound pipeline.
        Task { [env = _env.wrappedValue] in
            await Self.bootstrap(env: env)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(env)
                .environment(toasts)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { /* disable new window */ }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
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
            }
        }
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

                switch state {
                case .clientConnected:
                    if env.currentSessionId == nil {
                        if let session = try? await env.store.createSession(source: .live) {
                            env.didConnectSession(session.id)
                        }
                    }
                    // Ask the SDK for its command list so the command-bar
                    // help popover has something to show. Brief delay so
                    // the SDK has finished registering its handlers.
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await env.server.send(command: "cmdlist")
                    }
                case .clientDisconnected:
                    if let sid = env.currentSessionId {
                        try? await env.store.endSession(sid)
                        env.didDisconnectSession()
                    }
                default:
                    break
                }
            }
        }

        // Forward inbound frames into the decoder + store.
        Task {
            for await frame in env.server.inbound {
                await Self.handleInbound(frame: frame, env: env)
            }
        }

        // Keep the toolbar's "are there events to act on?" count fresh,
        // and react to session deletions so the viewing/current pointers
        // don't dangle on rows that no longer exist.
        Task { @MainActor in
            for await change in await env.store.changes() {
                switch change {
                case .appended(let sid, _) where sid == env.viewingSessionId:
                    await env.refreshViewingEventCount()
                case .cleared(let sid) where sid == env.viewingSessionId:
                    await env.refreshViewingEventCount()
                case .sessionStarted, .sessionEnded:
                    await env.refreshViewingEventCount()
                case .sessionDeleted(let id):
                    if env.viewingSessionId == id { env.viewingSessionId = nil }
                    if env.currentSessionId == id { env.currentSessionId = nil }
                    await ensureLiveSessionIfConnected(env: env)
                    await env.refreshViewingEventCount()
                case .sessionsCleared:
                    env.viewingSessionId = nil
                    env.currentSessionId = nil
                    await ensureLiveSessionIfConnected(env: env)
                    await env.refreshViewingEventCount()
                default:
                    break
                }
            }
        }
    }

    private static func handleInbound(frame: Data, env: AppEnvironment) async {
        let sessionId = await MainActor.run { env.currentSessionId }
        guard let sessionId else { return }

        switch ProtocolDecoder.decode(frame) {
        case .success(.event(let event)):
            await env.store.append(event, to: sessionId)
            // Side-channel: detect cmdlist responses and populate the
            // command-help popover. Identified by the GeneralHandler
            // subsystem + "Registered commands:" prefix. Event still
            // appears in the log feed normally.
            if isCmdListResponse(event) {
                let names = parseCmdListMessage(event.message)
                await MainActor.run {
                    env.availableCommands = CommandHints.merge(sdkNames: names)
                }
            }
        case .success(.storage(let namespaces)):
            for (namespace, json) in namespaces {
                try? await env.store.recordStorageSnapshot(
                    sessionId: sessionId,
                    namespace: namespace,
                    dataJSON: json
                )
            }
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

/// If a device is currently connected but `currentSessionId` is nil
/// (e.g., right after the user deleted every session), create a fresh
/// live session so the inbound WebSocket pipeline has somewhere to
/// write. Without this, events from the live device would be silently
/// dropped until the user reconnected the device.
@MainActor
private func ensureLiveSessionIfConnected(env: AppEnvironment) async {
    guard case .clientConnected = env.serverState else { return }
    guard env.currentSessionId == nil else { return }
    if let session = try? await env.store.createSession(source: .live) {
        env.didConnectSession(session.id)
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
}

// MARK: - cmdlist response detection

/// True iff the event looks like the SDK's reply to `cmdlist`.
/// Documented format (empirically captured 2026-05-16):
/// - level: info
/// - subsystem: `DebugFeatures/ConsoleCommands/GeneralHandler`
/// - message: `"Registered commands:\n<name>\n<name>\n…"`
private func isCmdListResponse(_ event: DecodedEvent) -> Bool {
    event.subsystem == "DebugFeatures/ConsoleCommands/GeneralHandler"
        && event.message.hasPrefix("Registered commands:")
}

/// Pull the command names out of a cmdlist response message. Drops the
/// header line and any blank lines; trims whitespace from each entry.
private func parseCmdListMessage(_ message: String) -> [String] {
    message
        .split(separator: "\n", omittingEmptySubsequences: true)
        .dropFirst()  // "Registered commands:"
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
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
