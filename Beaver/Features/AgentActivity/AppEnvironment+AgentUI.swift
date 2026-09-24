//
//  AppEnvironment+AgentUI.swift
//  Beaver
//

import Foundation

extension AppEnvironment: AgentUI {
    nonisolated public func snapshot() async -> HostSnapshot {
        await MainActor.run {
            let (connected, state): (Bool, String) = switch serverState {
            case .stopped: (false, "stopped")
            case .listening: (false, "listening")
            case .clientConnected: (true, "clientConnected")
            case .clientDisconnected(let reason): (false, "clientDisconnected: \(reason)")
            case .failed(let reason): (false, "failed: \(reason)")
            }
            return HostSnapshot(
                serverState: state,
                deviceConnected: connected,
                liveSessionId: currentSessionId,
                viewingSessionId: viewingSessionId,
                commands: availableCommands,
                deviceURL: NetworkInterface.bestAddress().map { "ws://\($0):9080" },
                beaverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                mcpPort: agentAccessPort ?? 0
            )
        }
    }

    nonisolated public func didSendCommand(_ command: String) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .beaverCommandSent, object: command)
        }
    }
}
