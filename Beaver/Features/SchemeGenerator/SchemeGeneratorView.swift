//
//  SchemeGeneratorView.swift
//  Beaver
//

import AppKit
import SwiftUI

/// Builds a deep link into a Zapp app, as zapp-support's Scheme Generator
/// does. The form lives in `env.schemeLink`, so `scheme_build` and
/// `ui_state` see and change what is on screen (D54).
struct SchemeGeneratorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    /// The scheme this view last filled in from a session, so a later one
    /// replaces it but never a scheme the person typed.
    @State private var autoScheme: String?

    var body: some View {
        @Bindable var env = env
        HStack(alignment: .top, spacing: 0) {
            form($env.schemeLink)
                .frame(minWidth: 380)
            Divider()
            preview(env.schemeLink)
                .frame(width: 300)
        }
        // The active session's app scheme by default, also when its
        // storage arrives after the tab opened.
        .task(id: env.viewingSessionId) {
            guard let sid = env.viewingSessionId else { return }
            await applySessionScheme(sid)
            for await change in await env.store.changes() {
                if case .storageUpdated(let s, _) = change, s == sid { await applySessionScheme(sid) }
            }
        }
        .onChange(of: env.schemeLink.mode) {
            if env.schemeLink.template != env.schemeLink.effectiveTemplate {
                env.schemeLink.template = env.schemeLink.effectiveTemplate
            }
        }
    }

    // MARK: - Form

    private func form(_ link: Binding<SchemeLink>) -> some View {
        Form {
            Section {
                Picker("Mode", selection: link.mode) {
                    Text("Mobile  myapp://").tag(SchemeLink.Mode.mobile)
                    Text("Web  index.html?").tag(SchemeLink.Mode.web)
                }
                .pickerStyle(.segmented)
                if link.wrappedValue.mode == .mobile {
                    HStack {
                        TextField("App scheme", text: link.scheme, prompt: Text("myapp"))
                            .help("The custom URL scheme registered by the app, without ://")
                        Button("From session") { Task { await useSessionScheme(link) } }
                            .disabled(env.viewingSessionId == nil)
                            .help("Use the scheme the app reports in its storage (applicaster.v2.urlScheme)")
                    }
                } else {
                    TextField("Base URL", text: link.baseURL, prompt: Text("https://app.example.com/index.html"))
                        .help("The full path to the web app's index.html")
                }
                Picker("Template", selection: link.template) {
                    ForEach(SchemeLink.Template.available(in: link.wrappedValue.mode), id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                if link.wrappedValue.mode == .web {
                    Text("Web links open a screen on Vizio; a layout switch works on every web platform.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(link.wrappedValue.effectiveTemplate.title) {
                switch link.wrappedValue.effectiveTemplate {
                case .screenType:
                    TextField("Content type", text: link.screenType, prompt: Text("movie"))
                        .help("Opens the screen mapped to this content type")
                    TextField("ID (optional)", text: link.id, prompt: Text("abc123"))
                case .feedContent:
                    TextField("Feed locator URL", text: link.feedURL, prompt: Text("https://feeds.example.com/movies.json"))
                        .help("Percent-encoded automatically")
                    TextField("Entry ID (optional)", text: link.id, prompt: Text("abc123"))
                        .help("Use either the entry ID or the position")
                    TextField("Position (optional)", text: digits(link.position), prompt: Text("1"))
                        .help("Counted from 1; without ID or position the first entry opens")
                        .disabled(!link.wrappedValue.id.isEmpty)
                case .directScreen:
                    TextField("Screen ID", text: link.screenId, prompt: Text("MOVIE_SCREEN"))
                case .present:
                    TextField("Feed URL", text: link.feedURL, prompt: Text("https://feeds.example.com/movies.json"))
                        .help("Base64-encoded as data_source")
                    TextField("Screen ID", text: link.screenId, prompt: Text("MOVIE_SCREEN"))
                    TextField("Entry ID (optional)", text: link.id, prompt: Text("abc123"))
                        .help("The entry with this id in the feed")
                    TextField("Resume at, seconds (optional)", text: digits(link.resumeTime), prompt: Text("120"))
                        .disabled(link.wrappedValue.id.isEmpty)
                    Toggle("Push over the current screen", isOn: link.pushScreen)
                case .webPage:
                    TextField("Page URL", text: link.linkURL, prompt: Text("https://example.com/help"))
                    TextField("Content type (optional)", text: link.contentType, prompt: Text("link"))
                    TextField("Screen ID (optional)", text: link.screenId, prompt: Text("WEBVIEW_SCREEN"))
                    Toggle("Show navigation bar", isOn: link.showNavBar)
                    Toggle("Push over the current screen", isOn: link.pushScreen)
                case .layout:
                    TextField("Layout ID", text: link.layoutId, prompt: Text("rivers_configuration_id"))
                        .help("Reloads the app with this rivers configuration")
                case .xray:
                    Picker("Action", selection: link.xrayAction) {
                        ForEach(SchemeLink.XrayAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: link.wrappedValue.xrayAction) { _, action in
                        let value = link.wrappedValue.xrayValue
                        if action == .connect, value.isEmpty { link.wrappedValue.xrayValue = beaverURL }
                        if action == .pin, !value.allSatisfy(\.isNumber) { link.wrappedValue.xrayValue = "" }
                    }
                    if link.wrappedValue.xrayAction == .connect {
                        HStack {
                            TextField("Connect to", text: link.xrayValue, prompt: Text("ws://192.168.1.5:9080"))
                            Button("This Beaver") { link.wrappedValue.xrayValue = beaverURL }
                        }
                        Text("Debug and TestFlight builds only; release builds need a PIN.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if link.wrappedValue.xrayAction == .pin {
                        TextField("PIN", text: digits(link.xrayValue), prompt: Text("1234"))
                    }
                    Picker("File log level", selection: link.fileLogLevel) {
                        Text("Unchanged").tag(String?.none)
                        ForEach(SchemeLink.logLevels, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    triState("Floating button", link.floatingButton)
                    triState("Shortcut", link.shortcutEnabled)
                    triState("App's MCP server", link.mcpServer)
                    Text("The app keeps the log level and shortcut only when the floating button is set too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .resetUUID:
                    Text("The app asks, then makes a new device ID and reloads.")
                        .foregroundStyle(.secondary)
                case .externalAccount:
                    Text("Opens the app's external account link (iOS, where payments are allowed).")
                        .foregroundStyle(.secondary)
                case .custom:
                    TextField("Host", text: link.host, prompt: Text("plugin"))
                        .help("A plugin's host, or plugin with pluginIdentifier=… below")
                }
            }

            Section("Optional parameters") {
                if link.wrappedValue.effectiveTemplate.host == "open" {
                    Picker("Player state", selection: link.state) {
                        Text("Default (fullscreen)").tag(SchemeLink.ScreenState?.none)
                        ForEach(SchemeLink.ScreenState.allCases, id: \.self) {
                            Text($0.rawValue).tag(Optional($0))
                        }
                    }
                    TextField("Title (optional)", text: link.title, prompt: Text("My Screen"))
                }
                TextField("More parameters", text: link.extras, prompt: Text("key=value, one per line"), axis: .vertical)
                    .lineLimit(1...5)
                    .help("Added to the query. Open passes unknown ones to the screen as entry fields.")
            }

            Section {
                Button("Reset") {
                    link.wrappedValue = SchemeLink()
                    if let sid = env.viewingSessionId { Task { await applySessionScheme(sid) } }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Digits only, for numeric fields.
    private func digits(_ value: Binding<String>) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.filter { $0.isASCII && $0.isNumber } })
    }

    /// Unchanged / On / Off.
    private func triState(_ title: String, _ value: Binding<Bool?>) -> some View {
        Picker(title, selection: value) {
            Text("Unchanged").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }

    /// Where the device reaches this Beaver, as Copy IP gives it.
    private var beaverURL: String { "ws://\(NetworkInterface.bestAddress() ?? "localhost"):9080" }

    /// Fills in the session's app scheme unless the person typed their own.
    private func applySessionScheme(_ sid: Int64) async {
        guard let first = ((try? await SchemeLink.appSchemes(store: env.store, sessionId: sid)) ?? nil)?.first,
              sid == env.viewingSessionId else { return }
        let current = env.schemeLink.scheme
        guard current.isEmpty || current == SchemeLink().scheme || current == autoScheme else { return }
        autoScheme = first
        if current != first { env.schemeLink.scheme = first }
    }

    /// The viewed session's app scheme, as `scheme_build` reads it.
    private func useSessionScheme(_ link: Binding<SchemeLink>) async {
        guard let sid = env.viewingSessionId else { return }
        let found = (try? await SchemeLink.appSchemes(store: env.store, sessionId: sid)) ?? nil
        guard let first = found?.first else {
            toasts.error(found == nil ? "Session #\(sid) has no storage yet" : "Session #\(sid)'s storage has no URL scheme")
            return
        }
        link.wrappedValue.scheme = first
        autoScheme = first
        toasts.success("Scheme \(first) from session #\(sid)")
    }

    // MARK: - Preview

    private func preview(_ link: SchemeLink) -> some View {
        let url = link.url
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generated URL").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    toasts.success("Copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.textBackgroundColor)))

            if link.mode == .mobile, let qr = qrImage(url) {
                Text("QR Code").font(.headline).padding(.top, 8)
                Text("Scan to trigger the deep link on a device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let image = SchemeLink.qrImage(text) else { return nil }
        let rep = NSCIImageRep(ciImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}
