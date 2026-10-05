//
//  DevicePopover.swift
//  Beaver
//
//  D75/D76: what the viewed device runs, Disconnect, the agents' default,
//  and the app's toolboxes. The Sessions tab's details show all of it; the
//  device badge's popover leaves the toolboxes to them (D86).

import AppKit
import SwiftUI

struct DevicePopover: View {
    /// D98: what Disconnect does depends on the app's X-Ray SDK.
    static let disconnectHelp = "Disconnect this device. An app whose X-Ray SDK supports close code 4000 stays disconnected until it returns to the foreground or is relaunched; older SDKs may reconnect on their own."

    let session: Session
    let isLive: Bool
    /// Every session row — to resolve which live session among several
    /// sharing a device uid is the one agents' default actually targets.
    let sessions: [Session]
    /// The popover's width; nil inside the Sessions tab's details, which
    /// set their own width and padding.
    var width: CGFloat? = 360
    /// The toolboxes live in the Sessions details; the badge's popover
    /// points there instead of listing them twice.
    var showsToolboxes = true
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var load: ToolboxLoad = .loading
    /// Bumped by Reload and Retry: part of the load task's identity.
    @State private var attempt = 0
    @State private var openToolbox: String?
    @State private var showingDefaultHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isLive {
                HStack {
                    Toggle("Default for agents", isOn: defaultBinding)
                        .toggleStyle(.checkbox)
                        .disabled(defaultIsAnotherSession)
                        .help(defaultIsAnotherSession ? Self.defaultTakenHelp : Self.defaultHelp)
                    // A tooltip alone is easy to miss (and doesn't show in
                    // every container): ⓘ says it on a click.
                    Button { showingDefaultHelp.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("What Default for agents does")
                        .accessibilityLabel("What Default for agents does")
                        .popover(isPresented: $showingDefaultHelp, arrowEdge: .bottom) {
                            Text(defaultIsAnotherSession ? Self.defaultTakenHelp : Self.defaultHelp)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 300, alignment: .leading)
                                .padding(12)
                        }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await env.disconnect(session.id) }
                    } label: {
                        Label("Disconnect", systemImage: "eject")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help(Self.disconnectHelp)
                }
                Divider()
                if logsOnly {
                    Text("A smart TV read over DevTools: it sends logs only, so it has no commands, storage or toolboxes.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if showsToolboxes {
                    toolboxes
                } else {
                    Button {
                        dismiss()
                        env.selectedTab = .sessions
                    } label: {
                        Label("Toolboxes in Sessions", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.link)
                    .help("The app's toolboxes and their tools are in the Sessions tab's details for this session")
                }
            }
        }
        .padding(width == nil ? 0 : 16)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        // Keyed on liveness too: with D97 an ended session comes back live
        // when its app launch reconnects, and its toolboxes load again. One
        // task for every load, so a switch to another session cancels it
        // before it can show the first one's toolboxes.
        .task(id: ToolboxLoadKey(sessionId: session.id, isLive: isLive, attempt: attempt)) {
            if isLive && !logsOnly && showsToolboxes { await reload() }
        }
    }

    /// D76, said so a person knows what ticking it changes.
    static let defaultHelp = """
        When several apps are connected, an AI agent's commands, storage changes and \
        app tools go to this app if the agent doesn't name one. Without a default, \
        such a call fails and the agent has to pick a device.
        Only one app is the default: ticking this one unticks the other.
        Follows this device across app restarts (by its device id). \
        Kept until Beaver quits. Reading logs, network and storage isn't affected.
        """
    static let defaultTakenHelp = """
        Another live session of this same device is already the agents' default \
        (it follows the device across restarts). Untick it there to change it.
        """

    /// A `register` client (D89).
    private var logsOnly: Bool { env.live.logsOnlySessions.contains(session.id) }

    private var title: String {
        (session.appName ?? session.appPackage ?? "Device #\(session.id)")
            + (session.appVersion.map { " " + $0 } ?? "")
    }

    private var deviceLine: String {
        [session.deviceModel, session.osVersion.map { (session.platform ?? "OS") + " " + $0 }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var stateLine: String {
        if isLive { return "Connected since " + session.startedAt.formatted(date: .omitted, time: .shortened) }
        if let ended = session.endedAt { return "Ended " + ended.formatted(date: .abbreviated, time: .shortened) }
        return session.source == .imported ? "Imported" : "Not connected"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(2)
            if let package = session.appPackage {
                Text(package).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !deviceLine.isEmpty {
                Text(deviceLine).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let uid = session.deviceUID {
                HStack(spacing: 4) {
                    Text(uid).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uid, forType: .string)
                        toasts.success("Copied device id")
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy device id")
                        .accessibilityLabel("Copy device id")
                }
            }
            Text(stateLine).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Several live sessions can share a device uid: only the one
    /// `liveSession` resolves to is the actual default, not every session
    /// `matches()` would accept.
    private var isDefault: Bool {
        env.defaultDevice?.liveSession(in: sessions, live: env.live.sessionIds) == session.id
    }

    /// The default is this device, but another of its live sessions: the
    /// toggle shows unticked, and ticking it would set the same device again
    /// and change nothing.
    private var defaultIsAnotherSession: Bool {
        env.defaultDevice?.matches(session) == true && !isDefault
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { isDefault },
            set: { on in
                env.setDefaultDeviceByUser(on ? DefaultDevice(session: session) : nil,
                                           name: title, sessionId: session.id)
            }
        )
    }

    @ViewBuilder
    private var toolboxes: some View {
        HStack {
            Text("Toolboxes").font(.subheadline.weight(.semibold))
            Spacer()
            Button { attempt += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Ask the app for its toolboxes again")
                .accessibilityLabel("Reload toolboxes")
                .disabled(load == .loading)
        }
        switch load {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .unsupported:
            HStack {
                Text("This app doesn't answer MCP — it needs quick-brick-xray's native WebSocket sink.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // A native app is never latched as unsupported, but one can
                // be before its handshake arrives. The handshake clears the
                // latch, so Retry then loads its toolboxes (as after a failed load).
                Button("Retry") { attempt += 1 }
            }
        case .failed(let message):
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { attempt += 1 }
            }
        case .loaded(let boxes) where boxes.isEmpty:
            Text("This app has no toolboxes.").font(.caption).foregroundStyle(.secondary)
        case .loaded(let boxes):
            // The Sessions details scroll as a whole; a ScrollView inside
            // theirs would collapse to nothing.
            if width == nil {
                toolboxList(boxes)
            } else {
                ScrollView { toolboxList(boxes) }
                    .frame(maxHeight: 420)
            }
        }
    }

    private func toolboxList(_ boxes: [Toolbox]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(boxes, id: \.name) { box in
                // Our own disclosure, not DisclosureGroup: on macOS its rows
                // pop in; this slides and fades them.
                let isOpen = openToolbox == box.name
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { openToolbox = isOpen ? nil : box.name }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                            Text("\(box.name) · \(box.tools.count) tool\(box.tools.count == 1 ? "" : "s")")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isOpen {
                        // Full width, leading: a toolbox with short descriptions
                        // was centred, so open lists looked different.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(box.tools, id: \.name) { ToolRow(tool: $0) }
                        }
                        .padding(.leading, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .clipped()
            }
        }
    }

    private func reload() async {
        load = .loading
        let fetched = await ToolboxLoad.fetch(from: env, sessionId: session.id)
        guard !Task.isCancelled else { return }
        load = fetched
    }
}

private struct ToolboxLoadKey: Equatable {
    let sessionId: Int64
    let isLive: Bool
    let attempt: Int
}

private struct ToolRow: View {
    let tool: DeviceTool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tool.name)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            if !tool.description.isEmpty {
                Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4).help(tool.description)
            }
            ForEach(tool.parameters, id: \.name) { p in
                Text(p.line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
