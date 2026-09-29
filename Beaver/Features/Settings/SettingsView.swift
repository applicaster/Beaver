//
//  SettingsView.swift
//  Beaver
//
//  D92 (amends D62): Beaver → Settings… (⌘,), also the gear at the bottom
//  of the sidebar. Everything that used to sit in the app menu as a
//  setting: session retention, Agent Access and its port, agent
//  notifications, the Zapp token, and About.

import AppKit
import Sparkle
import SwiftUI

enum SettingsTab: String {
    case general, agents, zapp, about
    /// Written before `openSettings()` to open a given tab (Info's token link).
    static let key = "settingsTab"
}

struct SettingsView: View {
    static let releasesURL = URL(string: "https://github.com/applicaster/Beaver/releases")!

    @Binding var retentionDays: Int
    @Binding var agentAccessEnabled: Bool
    /// Restarts the listener on the configured port, as the toggle does.
    let applyAgentAccess: () async -> Void
    let updater: SPUUpdater

    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings(retentionDays: $retentionDays)
            }
            Tab("Agents", systemImage: "sparkles", value: .agents) {
                AgentSettings(enabled: $agentAccessEnabled, apply: applyAgentAccess)
            }
            Tab("Zapp", systemImage: "key", value: .zapp) {
                ZappSettings()
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettings(updater: updater)
            }
        }
        .formStyle(.grouped)
        // Its own scene: it doesn't inherit the main window's selection.
        .textSelection(.enabled)
        .frame(width: 540, height: 440)
    }
}

/// A result shown right under the control that caused it, for a few
/// seconds. Settings has no room for a toast: its top is the system tab
/// bar, so a toast covered the form's first header.
struct StatusNote: Equatable {
    let text: String
    let ok: Bool
}

private struct StatusLine: View {
    @Binding var note: StatusNote?

    var body: some View {
        if let note {
            Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(note.ok ? .green : .red)
                .textSelection(.enabled)
                .transition(.opacity)
                .task(id: note.text) {
                    try? await Task.sleep(for: .seconds(4))
                    if self.note == note { withAnimation { self.note = nil } }
                }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Binding var retentionDays: Int
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingDeleteAll = false
    @State private var note: StatusNote?

    var body: some View {
        Form {
            Section {
                Picker("Delete sessions older than", selection: $retentionDays) {
                    ForEach(SessionRetention.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Database on disk",
                               value: env.storeSize.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                HStack {
                    Spacer()
                    Button(role: .destructive) { confirmingDeleteAll = true } label: {
                        Label("Delete All Sessions…", systemImage: "trash")
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Every session — past, imported and live — with its events, requests and storage")
                }
                StatusLine(note: $note)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Imported sessions, sessions with a bookmark and connected devices' sessions are kept. Changing the period deletes right away. The database also holds saved filters, command history and the agent journal, so it never reaches zero.")
                    .foregroundStyle(.secondary)
            }
        }
        // The same delete as Sessions → Delete all sessions…: a connected
        // device carries on in a fresh session.
        // The size follows every delete — here, in Sessions, by an agent or
        // by retention — not just the ones made from this tab.
        .task {
            env.storeSize = try? await env.store.databaseSize()
            for await change in await env.store.changes() {
                switch change {
                case .sessionsCleared, .sessionsDeleted:
                    env.storeSize = try? await env.store.databaseSize()
                default:
                    break
                }
            }
        }
        .confirmationDialog("Delete all sessions?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                Task {
                    do {
                        try await env.store.deleteAllSessions()
                        withAnimation { note = StatusNote(text: "All sessions deleted", ok: true) }
                    } catch {
                        withAnimation { note = StatusNote(text: "Couldn't delete sessions: \(error.localizedDescription)", ok: false) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded session — with its events, network requests, storage snapshots and bookmarks — is removed. This can't be undone.")
        }
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @Binding var enabled: Bool
    let apply: () async -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var portText = String(AgentAccess.configuredPort())
    @State private var note: StatusNote?

    private var portProblem: String? {
        Int(portText.trimmingCharacters(in: .whitespaces)).map(AgentAccess.portProblem) ?? "Enter a port number."
    }

    var body: some View {
        let notifier = AgentNotifier.shared
        Form {
            Section {
                Toggle("Agent Access (MCP)", isOn: $enabled)
                LabeledContent("Status", value: env.agentAccessStatus)
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText, prompt: Text(String(AgentAccess.defaultPort)))
                            .labelsHidden()
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(portProblem != nil || Int(portText) == Int(AgentAccess.configuredPort()))
                    }
                }
                if let portProblem {
                    Text(portProblem).font(.caption).foregroundStyle(.red)
                }
                Button("Copy MCP Setup Command") {
                    let command = AgentAccess.setupCommand(port: env.agentAccessPort ?? AgentAccess.configuredPort())
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    withAnimation { note = StatusNote(text: "Copied: \(command)", ok: true) }
                }
                .disabled(env.agentAccessPort == nil)
                StatusLine(note: $note)
            } header: {
                Text("Agent Access")
            } footer: {
                Text("AI agents on this Mac reach Beaver at http://127.0.0.1:\(String(AgentAccess.configuredPort()))/mcp. After changing the port, set your agents up again with the new command.")
                    .foregroundStyle(.secondary)
            }
            Section("Agent notifications") {
                Toggle("Notifications from the agent", isOn: Binding(get: { !notifier.muted }, set: { notifier.muted = !$0 }))
                LabeledContent("Now", value: AgentNotifications.status(for: notifier.state))
                if let strip = notifier.strip {
                    Text(strip.detail).font(.caption).foregroundStyle(.secondary)
                    Button(strip.button) { notifier.perform(strip.action) }
                }
                Button("Open Agent Panel") {
                    NSApp.activate()
                    notifier.openPanel()
                }
            }
        }
    }

    private func applyPort() {
        guard portProblem == nil, let port = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        if port == Int(AgentAccess.defaultPort) {
            UserDefaults.standard.removeObject(forKey: AgentAccess.portKey)
        } else {
            UserDefaults.standard.set(port, forKey: AgentAccess.portKey)
        }
        portText = String(port)
        Task { await apply() }
    }
}

// MARK: - Zapp

private struct ZappSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var hasToken = ZappToken.read() != nil
    @State private var newToken = ""
    @State private var checking = false
    @State private var result: (text: String, ok: Bool?)?

    var body: some View {
        Form {
            Section {
                LabeledContent("Token", value: hasToken ? "Set — kept in your login keychain" : "Not set")
                SecureField(hasToken ? "New token" : "Token", text: $newToken,
                            prompt: Text(hasToken ? "Paste a new token to replace it" : "Paste the token"))
                    .onSubmit(save)
                HStack {
                    Button(hasToken ? "Replace" : "Save", action: save)
                        .disabled(newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove", role: .destructive) {
                        ZappToken.write(nil)
                        result = ("Zapp token removed.", true)
                    }
                    .disabled(!hasToken)
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Test", action: test).disabled(!hasToken || checking)
                        .help("Asks the Zapp CMS for build parameters with the token")
                }
                if let result {
                    Label(result.text, systemImage: result.ok == true ? "checkmark.circle"
                          : result.ok == false ? "xmark.octagon" : "questionmark.circle")
                        .foregroundStyle(result.ok == true ? .green : result.ok == false ? .red : .orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Zapp access token")
            } footer: {
                Text("With your Zapp token, the Info tab asks the Zapp CMS for the app version's build parameters and exact config URLs, as zapptool does. Create one at accounts.applicaster.com → Users → your user → Access Tokens.")
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ZappToken.didChange)) { _ in
            hasToken = ZappToken.read() != nil
        }
    }

    private func save() {
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        if ZappToken.write(token) {
            newToken = ""
            result = ("Zapp token saved. Test it to check Zapp accepts it.", true)
        } else {
            result = ("Couldn't save the token to the keychain.", false)
        }
    }

    private func test() {
        guard let token = ZappToken.read() else { return }
        checking = true
        Task {
            let versionId: String? = if let sid = env.viewingSessionId {
                await AppInfoReport.versionId(store: env.store, sessionId: sid)
            } else { nil }
            result = switch await ZappTokenCheck.run(token: token, versionId: versionId) {
            case .accepted: ("Zapp accepted the token.", true)
            case .rejected: ("Zapp rejected the token — replace it.", false)
            case .unknown(let why): ("Couldn't tell: \(why)", nil)
            }
            checking = false
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    let updater: SPUUpdater
    @State private var showingWhatsNew = false

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text("Beaver").font(.title.weight(.semibold))
            Text("Version \(Changelog.appVersion) (\(Changelog.appBuild))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("What's New…") { showingWhatsNew = true }
                CheckForUpdatesView(updater: updater)
            }
            Link("Releases on GitHub", destination: SettingsView.releasesURL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewView(releases: WhatsNew.history(.bundled, current: Changelog.appVersion))
        }
    }
}
