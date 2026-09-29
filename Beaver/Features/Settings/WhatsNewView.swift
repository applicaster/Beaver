//
//  WhatsNewView.swift
//  Beaver
//
//  D92: the What's New sheet — CHANGELOG.md, bundled into the app, as
//  releases. Shown on the first launch of a new version, from Beaver →
//  What's New… and from Settings → About.

import SwiftUI

extension Changelog {
    /// The CHANGELOG.md in the app bundle; empty when it's missing.
    static let bundled: Changelog = {
        let text = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return Changelog(markdown: text ?? "")
    }()

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

struct WhatsNewView: View {
    let releases: [Changelog.Release]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New in Beaver \(releases.first?.version ?? Changelog.appVersion)")
                .font(.title2.weight(.semibold))
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if releases.isEmpty {
                        Text("No release notes in this build.").foregroundStyle(.secondary)
                    }
                    ForEach(releases) { ReleaseNotes(release: $0) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Link("All releases on GitHub", destination: SettingsView.releasesURL)
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .textSelection(.enabled)
    }
}

private struct ReleaseNotes: View {
    let release: Changelog.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.version).font(.title3.weight(.semibold))
                if let date = release.date { Text(date).foregroundStyle(.secondary) }
            }
            if release.groups.isEmpty {
                Text("No user-facing changes.").foregroundStyle(.secondary)
            }
            ForEach(release.groups.indices, id: \.self) { i in
                let group = release.groups[i]
                if let title = group.title {
                    Text(title).font(.headline).foregroundStyle(.secondary)
                }
                ForEach(group.blocks.indices, id: \.self) { j in
                    switch group.blocks[j] {
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                        }
                    case .paragraph(let text):
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Bold, `code` and links; the raw text if it isn't valid Markdown.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
