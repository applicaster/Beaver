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

    var body: some View {
        @Bindable var env = env
        HStack(alignment: .top, spacing: 0) {
            form($env.schemeLink)
                .frame(minWidth: 380)
            Divider()
            preview(env.schemeLink)
                .frame(width: 300)
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
                    TextField("App scheme", text: link.scheme, prompt: Text("myapp"))
                        .help("The custom URL scheme registered by the app, without ://")
                } else {
                    TextField("Base URL", text: link.baseURL, prompt: Text("https://app.example.com/index.html"))
                        .help("The full path to the web app's index.html")
                }
                Picker("Template", selection: link.template) {
                    ForEach(SchemeLink.Template.available(in: link.wrappedValue.mode), id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(link.wrappedValue.effectiveTemplate.title) {
                switch link.wrappedValue.effectiveTemplate {
                case .screenType:
                    TextField("Screen type", text: link.screenType, prompt: Text("movie"))
                    TextField("ID (optional)", text: link.id, prompt: Text("abc123"))
                case .feedContent:
                    TextField("Feed locator URL", text: link.feedURL, prompt: Text("https://feeds.example.com/movies.json"))
                        .help("Percent-encoded automatically")
                    TextField("Entry ID (optional)", text: link.id, prompt: Text("abc123"))
                        .help("Use either the entry ID or the position")
                    TextField("Position (optional)", text: link.position, prompt: Text("0"))
                        .disabled(!link.wrappedValue.id.isEmpty)
                        .onChange(of: link.wrappedValue.position) { _, new in
                            let digits = new.filter(\.isNumber)
                            if digits != new { link.wrappedValue.position = digits }
                        }
                case .directScreen:
                    TextField("Screen ID", text: link.screenId, prompt: Text("MOVIE_SCREEN"))
                case .present:
                    TextField("Feed URL", text: link.feedURL, prompt: Text("https://feeds.example.com/movies.json"))
                        .help("Base64-encoded as data_source")
                    TextField("Screen ID", text: link.screenId, prompt: Text("MOVIE_SCREEN"))
                    TextField("Entry ID (optional)", text: link.id, prompt: Text("abc123"))
                        .help("Base64-encoded when it isn't URL-safe")
                }
            }

            Section("Optional parameters") {
                Picker("State", selection: link.state) {
                    Text("None").tag(SchemeLink.ScreenState?.none)
                    ForEach(SchemeLink.ScreenState.allCases, id: \.self) {
                        Text($0.rawValue).tag(Optional($0))
                    }
                }
                TextField("Title (optional)", text: link.title, prompt: Text("My Screen"))
            }

            Section {
                Button("Reset") { link.wrappedValue = SchemeLink() }
            }
        }
        .formStyle(.grouped)
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
