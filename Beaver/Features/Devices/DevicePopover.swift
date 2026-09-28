//
//  DevicePopover.swift
//  Beaver
//
//  D75/D76: what the viewed device runs, Disconnect, the agents' default,
//  and the app's toolboxes (read-only). Opened from the leading device badge.

import AppKit
import SwiftUI

struct DevicePopover: View {
    let session: Session
    let isLive: Bool
    /// Every session row — to resolve which live session among several
    /// sharing a device uid is the one agents' default actually targets.
    let sessions: [Session]
    /// The popover's width; nil inside the Sessions tab's details, which
    /// set their own width and padding.
    var width: CGFloat? = 360
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var load: ToolboxLoad = .loading
    @State private var openToolbox: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isLive {
                HStack {
                    Toggle("Default for agents", isOn: defaultBinding)
                        .toggleStyle(.checkbox)
                        .disabled(defaultIsAnotherSession)
                        .help(defaultIsAnotherSession
                              ? "Another session of this device is the default"
                              : "Agents' device tools use this app when a call names no device")
                    Spacer()
                    Button(role: .destructive) {
                        Task { await env.disconnect(session.id) }
                    } label: {
                        Label("Disconnect", systemImage: "eject")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Disconnect this device")
                }
                Divider()
                toolboxes
            }
        }
        .padding(width == nil ? 0 : 16)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .task(id: session.id) { if isLive { await reload() } }
    }

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
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
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
                Button("Retry") { Task { await reload() } }
            }
        case .failed(let message):
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await reload() } }
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
                DisclosureGroup(isExpanded: Binding(
                    get: { openToolbox == box.name },
                    set: { openToolbox = $0 ? box.name : nil }
                )) {
                    // Full width, leading: a toolbox with short descriptions
                    // was centred, so open lists looked different.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(box.tools, id: \.name) { ToolRow(tool: $0) }
                    }
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("\(box.name) · \(box.tools.count) tool\(box.tools.count == 1 ? "" : "s")")
                }
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
