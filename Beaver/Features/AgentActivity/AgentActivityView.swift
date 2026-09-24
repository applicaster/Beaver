//
//  AgentActivityView.swift
//  Beaver
//
//  The Agent panel (design §7.2): what an agent did through MCP.

import SwiftUI

struct AgentActivityView: View {
    @Bindable var model: AgentActivityViewModel
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent activity").font(.headline)
                Spacer()
                Toggle("Hide reads", isOn: $model.hideReads)
                    .toggleStyle(.checkbox)
                Button("Copy") {
                    model.copy()
                    toasts.success("Copied agent activity")
                }
                .disabled(model.visible.isEmpty)
                Button("Clear", role: .destructive) { model.clear() }
                    .disabled(model.entries.isEmpty)
            }
            .padding(10)
            Divider()
            if model.visible.isEmpty {
                ContentUnavailableView("No agent activity",
                                       systemImage: "sparkles",
                                       description: Text("Calls from an MCP client appear here. App menu → Copy MCP Setup Command to connect one."))
            } else {
                List(model.visible) { entry in
                    AgentActivityRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct AgentActivityRow: View {
    let entry: AgentActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.at, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(entry.client ?? "agent").foregroundStyle(.secondary)
                Text(entry.tool ?? entry.kind.rawValue).fontWeight(.medium)
                Spacer()
                if entry.isError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel("Failed")
                } else if entry.kind == .destructive {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Destructive")
                }
            }
            .font(.caption)
            Text(entry.summary)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .opacity(entry.kind == .read && !entry.isError ? 0.6 : 1)
        .padding(.vertical, 2)
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
