//
//  AgentActivityView.swift
//  Beaver
//
//  The Agent panel (design §7.2): what an agent did through MCP.

import AppKit
import SwiftUI

struct AgentActivityView: View {
    @Bindable var model: AgentActivityViewModel
    /// A row's link was clicked: get the popover out of the way.
    var onOpened: () -> Void = {}
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppEnvironment.self) private var env
    @State private var screen = Screen.activity
    @State private var hoveringHideReads = false
    @State private var showingHideReadsHint = false

    private enum Screen { case activity, setup, capabilities }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .activity: activity
            case .setup: setup
            case .capabilities: capabilities
            }
        }
        // Fill the popover whatever the content, so the header stays at
        // the top when the list is empty.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        HStack {
            Text("Agent activity").font(.headline)
            Spacer()
            Button("Connect agent") { screen = .setup }
                .help("How to connect Claude Code, Cursor or another MCP client to Beaver")
            capabilitiesButton
            Button("Copy") {
                model.copy()
                toasts.success("Copied agent activity")
            }
            .disabled(model.visible.isEmpty)
            Button("Clear", role: .destructive) { model.clear() }
                .disabled(model.entries.isEmpty)
            Toggle("Hide reads", isOn: $model.hideReads)
                .toggleStyle(.checkbox)
                // .help() tooltips don't show inside this popover; a hover popover stands in.
                .onHover { hovering in
                    hoveringHideReads = hovering
                    if !hovering { showingHideReadsHint = false; return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if hoveringHideReads { showingHideReadsHint = true }
                    }
                }
                .popover(isPresented: $showingHideReadsHint, arrowEdge: .bottom) {
                    Text(Self.hideReadsHint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 260)
                        .padding(10)
                }
                .accessibilityHint(Self.hideReadsHint)
        }
        .padding(10)
        Divider()
        NotificationStrip()
        if model.visible.isEmpty && !model.entries.isEmpty {
            // Everything is hidden by the toggle, not missing.
            ContentUnavailableView {
                Label("Only reads so far", systemImage: "eye.slash")
            } description: {
                Text("The agent has only read data — no changes and no failed calls.")
            } actions: {
                Button("Show reads") { model.hideReads = false }
            }
            .frame(maxHeight: .infinity)
        } else if model.visible.isEmpty {
            ContentUnavailableView {
                Label("No agent activity", systemImage: "sparkles")
            } description: {
                Text("Calls from an MCP client appear here.")
            } actions: {
                HStack {
                    Button("How to connect an agent") { screen = .setup }
                    capabilitiesButton
                }
                .fixedSize()
            }
            .frame(maxHeight: .infinity)
        } else {
            List(model.visible) { entry in
                AgentActivityRow(entry: entry) { link in
                    // Dismiss first, so the window is visible behind it,
                    // then show what the link points at.
                    onOpened()
                    Task { await open(link) }
                }
            }
            .listStyle(.plain)
        }
    }

    /// Shows what a journal link points at, through the same path
    /// `ui_show` uses. A person's click, not an agent call: not journaled,
    /// and `reveal: false` — the popover closing already brings the window
    /// into view.
    private func open(_ link: JournalLink) async {
        do {
            try await env.open(link, reveal: false)
        } catch let error as ToolError {
            toasts.error(error.personMessage)
        } catch {
            toasts.error(error.localizedDescription)
        }
    }


    // MARK: - Setup

    private var port: UInt16 { env.agentAccessPort ?? AgentAccess.configuredPort() }

    private static let hideReadsHint = "Reads are calls where the agent only looked — at logs, requests or storage. Turn on to list only calls that changed something, and failed calls."

    private var capabilitiesButton: some View {
        Button { screen = .capabilities } label: {
            Image(systemName: "info.circle")
        }
        .help("What an agent can do in Beaver")
        .accessibilityLabel("What an agent can do in Beaver")
    }

    private var back: some View {
        Button {
            screen = .activity
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
    }

    @ViewBuilder
    private var capabilities: some View {
        HStack {
            back
            Text("What an agent can do").font(.headline)
            Spacer()
            Button("Connect agent") { screen = .setup }
        }
        .padding(10)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Through Beaver's MCP server an agent reads everything Beaver collected from the app and acts on it. Ask in plain words — every call shows up in this panel, and deletions and notes that need you also show a toast.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AgentAccess.capabilities, id: \.title) { capability in
                    CapabilityCard(capability: capability) {
                        copy(capability.example)
                        toasts.success("Copied the prompt")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var setup: some View {
        HStack {
            back
            Text("Connect an agent").font(.headline)
            Spacer()
            Button("Copy all") {
                copy(AgentAccess.setupInstructions(port: port))
                toasts.success("Copied the setup instructions")
            }
        }
        .padding(10)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if env.agentAccessPort == nil {
                    Label("Agent Access is off. Turn it on in the app menu → Agent Access (MCP).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Beaver's MCP server is at http://127.0.0.1:\(port)/mcp. Set a client up once; after that just ask it to use beaver.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(AgentAccess.setupSteps(port: port), id: \.title) { step in
                    SetupCard(step: step) {
                        copy(step.code)
                        toasts.success("Copied: \(step.title)")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One client (or check) on the Connect agent screen.
private struct SetupCard: View {
    let step: AgentAccess.SetupStep
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.title).font(.title3.weight(.semibold))
                Spacer()
                Button("Copy", action: onCopy)
            }
            Text(step.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct CapabilityCard: View {
    let capability: AgentAccess.Capability
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: capability.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(capability.title).font(.title3.weight(.semibold))
                Text(capability.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Text(capability.example)
                        .font(.callout.italic())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy", action: onCopy)
                        .controlSize(.small)
                        .help("Copy this prompt")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                Text(capability.tools.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct AgentActivityRow: View {
    let entry: AgentActivity
    let onOpen: (JournalLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.at, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(entry.client ?? "agent").foregroundStyle(.secondary)
                Text(title).fontWeight(.medium)
                Spacer()
                if entry.isError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel("Failed")
                } else if entry.kind == .destructive {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Destructive")
                } else if entry.kind == .system {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("System")
                }
            }
            .font(.caption)
            Text(entry.summary)
                .font(entry.kind == .note ? .callout.weight(.medium) : .callout)
                .lineLimit(entry.kind == .note ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // What the entry points at (design §7.2): a click shows it.
            let links = entry.shownLinks
            if !links.isEmpty {
                HStack(spacing: 10) {
                    ForEach(links, id: \.self) { link in
                        Button { onOpen(link) } label: {
                            Label(link.label, systemImage: Self.icon(link))
                        }
                        .buttonStyle(.link)
                        .help("Show it in Beaver")
                    }
                }
                .font(.caption)
            }
            if !entry.isError, let notice = entry.error {
                HStack(spacing: 6) {
                    Label(notice, systemImage: "bell.slash").font(.caption).foregroundStyle(.orange)
                    if let strip = AgentNotifier.shared.strip {
                        Button(strip.button) { AgentNotifier.shared.perform(strip.action) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .opacity(entry.kind == .read && !entry.isError ? 0.75 : 1)
        .padding(.vertical, 4)
        .padding(.horizontal, entry.kind == .note ? 6 : 0)
        .background {
            if entry.kind == .note {
                RoundedRectangle(cornerRadius: 6)
                    .fill(entry.isAttention ? Color.orange.opacity(0.12) : Color.accentColor.opacity(0.08))
            }
        }
    }

    private var title: String {
        entry.kind == .note ? "★ note" : (entry.tool ?? entry.kind.rawValue)
    }

    private static func icon(_ link: JournalLink) -> String {
        switch link {
        case .event: "text.alignleft"
        case .network: "network"
        case .savedFilter: "line.3.horizontal.decrease.circle"
        case .session: "clock.arrow.circlepath"
        }
    }
}

/// Design M28: while notifications can't reach the person, say so and
/// offer the one action that works; when they can, a switch to mute them.
private struct NotificationStrip: View {
    var body: some View {
        let notifier = AgentNotifier.shared
        if let strip = notifier.strip {
            VStack(alignment: .leading, spacing: 6) {
                Label(strip.title, systemImage: "bell.slash")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(strip.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let error = notifier.lastRequestError {
                    Text("macOS refused: \(error). Turn it on in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(strip.button) { notifier.perform(strip.action) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            Divider()
        } else {
            Toggle("Notifications from the agent",
                   isOn: Binding(get: { !notifier.muted }, set: { notifier.muted = !$0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .help("macOS notifications for the agent's attention notes while Beaver is in the background")
            Divider()
        }
    }
}

/// The toolbar button: icon, unseen count, one pulse per new entry.
struct AgentToolbarButton: View {
    let model: AgentActivityViewModel
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ToolbarButtonLabel(systemImage: "sparkles", title: "Agent")
                .symbolEffect(.bounce, value: model.arrivals)
                .overlay(alignment: .topTrailing) {
                    if model.unseen > 0 {
                        Text(model.unseen > 99 ? "99+" : "\(model.unseen)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.red))
                            .foregroundStyle(.white)
                            .offset(x: 6, y: -4)
                            .accessibilityLabel("\(model.unseen) new agent actions")
                    }
                }
        }
        .buttonStyle(.plain)
        .help("What an AI agent did through Beaver's MCP server")
    }
}
