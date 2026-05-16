//
//  LoggerNextApp.swift
//  LoggerNext
//

import SwiftUI

@main
struct LoggerNextApp: App {

    @State private var env: AppEnvironment

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

        // Start the server and wire up the inbound pipeline.
        Task { [env = _env.wrappedValue] in
            await Self.bootstrap(env: env)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(env)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { /* disable new window */ }
            CommandGroup(after: .appInfo) {
                Button("Copy WebSocket Address") {
                    // Copy just `host:port` (no ws:// scheme).
                    let address = "\(NetworkInterface.bestAddress() ?? "localhost"):9080"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
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
            for await state in await env.server.state {
                env.serverState = state

                switch state {
                case .clientConnected:
                    if env.currentSessionId == nil {
                        if let session = try? await env.store.createSession(source: .live) {
                            env.didConnectSession(session.id)
                        }
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
            for await frame in await env.server.inbound {
                await Self.handleInbound(frame: frame, env: env)
            }
        }
    }

    private static func handleInbound(frame: Data, env: AppEnvironment) async {
        let sessionId = await MainActor.run { env.currentSessionId }
        guard let sessionId else { return }

        switch ProtocolDecoder.decode(frame) {
        case .success(.event(let event)):
            await env.store.append(event, to: sessionId)
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
