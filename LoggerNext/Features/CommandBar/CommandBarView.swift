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

    @State private var showingCommandHelp = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                // Info button — opens the available-commands popover.
                Button {
                    showingCommandHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Available commands")
                .popover(isPresented: $showingCommandHelp, arrowEdge: .top) {
                    CommandHelpPopover(
                        commands: env.availableCommands,
                        onPick: { hint in
                            vm.input = hint.syntax ?? hint.name
                            showingCommandHelp = false
                        },
                        onRefresh: {
                            Task { await env.server.send(command: "cmdlist") }
                        }
                    )
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isClientConnected ? 1.0 : 0.4)

                TextField(
                    isClientConnected
                        ? "Enter command…"
                        : "Not connected — connect a device to send commands",
                    text: $vm.input
                )
                    .textFieldStyle(.plain)
                    .disabled(!isClientConnected)
                    .foregroundStyle(isClientConnected ? .primary : .secondary)
                    .onKeyPress(.upArrow) {
                        vm.previousHistory()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        vm.nextHistory()
                        return .handled
                    }
                    .onSubmit {
                        if isClientConnected { vm.submit() }
                    }

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
                    .fill(isClientConnected
                          ? Color(.controlBackgroundColor)
                          // Distinctly grey so it actually reads as disabled
                          // — the system controlBackground is too light to
                          // visually communicate the disabled state on its own.
                          : Color.secondary.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isClientConnected
                            ? Color(.separatorColor)
                            : Color.secondary.opacity(0.3),
                        lineWidth: 1
                    )
            )

            Button("Send") { vm.submit() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isClientConnected || trimmedInput.isEmpty)
                .opacity(isClientConnected ? 1.0 : 0.5)
                .help(isClientConnected
                      ? "Send command"
                      : "Connect a client to send commands")
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

// MARK: - Command help popover

/// Lists every command the connected SDK advertised via `cmdlist`,
/// grouped by prefix, with syntax help from `CommandRegistry` where
/// available. Click a row to insert it into the TextField.
private struct CommandHelpPopover: View {
    let commands: [CommandHint]
    let onPick: (CommandHint) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if commands.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                ForEach(group.hints) { hint in
                                    CommandHelpRow(hint: hint, onTap: { onPick(hint) })
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Color(.windowBackgroundColor))
                            }
                        }
                    }
                }
                .frame(width: 440, height: 360)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Available commands")
                    .font(.caption.weight(.semibold))
                Text("Click any row to insert it into the command bar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Re-fetch the list from the connected device")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No commands yet")
                .font(.caption)
            Text("LoggerNext asked the connected device for its command list. If this stays empty, click ⟳ to retry.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 320)
    }

    /// Sectioned view of the hints — known groups in fixed order
    /// (Storage / Debug / Layout / General), then an "Unknown to
    /// LoggerNext" section for commands the registry doesn't cover.
    private var groups: [(title: String, hints: [CommandHint])] {
        let known = commands.filter { $0.syntax != nil }
        let unknown = commands.filter { $0.syntax == nil }

        let order = ["Storage", "Debug", "Layout", "General"]
        var result: [(String, [CommandHint])] = []
        for group in order {
            let inGroup = known.filter { $0.group == group }.sorted { $0.name < $1.name }
            if !inGroup.isEmpty {
                result.append((group, inGroup))
            }
        }
        if !unknown.isEmpty {
            result.append(("Unknown to LoggerNext", unknown.sorted { $0.name < $1.name }))
        }
        return result
    }
}

private struct CommandHelpRow: View {
    let hint: CommandHint
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(hint.syntax ?? hint.name)
                .font(.system(.caption, design: .monospaced))
            if let description = hint.description {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if hint.syntax == nil {
                Text("Syntax unknown — refer to SDK docs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
    }
}
