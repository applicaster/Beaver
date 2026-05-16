//
//  CommandBarView.swift
//  LoggerNext
//

import SwiftUI

/// Bottom-of-window command input. Sends arbitrary strings to the
/// connected client via `WSServer.send(command:)`. Up/Down arrows
/// navigate the in-memory history. Send is gated by whether text is
/// present — *not* by connection state — so the user can compose
/// commands while waiting for a client to connect. If no client is
/// active when Send fires, `WSServer.send(command:)` is a no-op.
struct CommandBarView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm: CommandBarViewModel?

    var body: some View {
        Group {
            if let vm {
                CommandBarContent(vm: vm)
            } else {
                Color.clear.frame(height: 36)
            }
        }
        .task {
            if vm == nil {
                vm = CommandBarViewModel(server: env.server)
            }
        }
    }
}

/// Extracted so `@Bindable var vm` sits at the struct level rather
/// than inside a `@ViewBuilder` function — that's the pattern that
/// reliably wires SwiftUI Observation through to the disabled
/// binding.
private struct CommandBarContent: View {
    @Bindable var vm: CommandBarViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Enter command…", text: $vm.input)
                    .textFieldStyle(.plain)
                    .onKeyPress(.upArrow) {
                        vm.previousHistory()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        vm.nextHistory()
                        return .handled
                    }
                    .onSubmit { vm.submit() }

                if !vm.input.isEmpty {
                    Button {
                        vm.input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.separatorColor), lineWidth: 1)
            )

            Button("Send") { vm.submit() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(trimmedInput.isEmpty)
                .help(isClientConnected
                      ? "Send command"
                      : "Send (no client connected — command will be ignored)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var trimmedInput: String {
        vm.input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
    }
}
