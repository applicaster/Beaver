//
//  Changelog.swift
//  Beaver
//
//  D92: CHANGELOG.md, bundled into the app, read into releases for the
//  What's New sheet. Only the shapes the file uses: `## [X.Y.Z] - date`,
//  `### Group`, `- ` bullets with wrapped lines, plain paragraphs.

import Foundation

public struct Changelog: Sendable, Equatable {
    public struct Release: Sendable, Equatable, Identifiable {
        public var id: String { version }
        public let version: String
        public let date: String?
        public let groups: [Group]
    }

    public struct Group: Sendable, Equatable {
        /// "Added", "Fixed"…; nil for text before the first `###`.
        public let title: String?
        public let blocks: [Block]
    }

    /// Inline Markdown (bold, `code`, links) left for the view to render.
    public enum Block: Sendable, Equatable {
        case bullet(String)
        case paragraph(String)
    }

    /// Newest first, as in the file. `[Unreleased]` and headings that
    /// aren't a version are left out.
    public let releases: [Release]

    public init(markdown: String) {
        var releases: [Release] = []
        var version: String?, date: String?
        var groups: [Group] = []
        var title: String?
        var blocks: [Block] = []
        var open: Block?

        func closeBlock() {
            if let block = open { blocks.append(block) }
            open = nil
        }
        func closeGroup() {
            closeBlock()
            if !blocks.isEmpty { groups.append(Group(title: title, blocks: blocks)) }
            title = nil; blocks = []
        }
        func closeRelease() {
            closeGroup()
            if let version { releases.append(Release(version: version, date: date, groups: groups)) }
            version = nil; date = nil; groups = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeRelease()
                if let match = line.wholeMatch(of: /## \[(\d+(?:\.\d+)*)\](?:\s*-\s*(.*))?/) {
                    version = String(match.1)
                    date = match.2.map { String($0) }.flatMap { $0.isEmpty ? nil : $0 }
                }
            } else if version == nil {
                continue
            } else if line.hasPrefix("### ") {
                closeGroup()
                title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty || line.hasPrefix("#") || line.contains(/^\[[^\]]+\]:\s/) {
                // Blank line, a deeper heading, or the link list at the end.
                closeBlock()
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                closeBlock()
                open = .bullet(String(line.dropFirst(2)))
            } else {
                switch open {
                case .bullet(let text): open = .bullet(text + " " + line)
                case .paragraph(let text): open = .paragraph(text + " " + line)
                case nil: open = .paragraph(line)
                }
            }
        }
        closeRelease()
        self.releases = releases
    }

    /// Releases newer than `lastSeen` (all when nil), up to and including
    /// `current`, newest first.
    public func releases(after lastSeen: String?, upTo current: String) -> [Release] {
        releases.filter { release in
            Self.compare(release.version, current) != .orderedDescending
                && lastSeen.map { Self.compare(release.version, $0) == .orderedDescending } ?? true
        }
    }

    /// Numeric, component by component; "1.0" equals "1.0.0". A part that
    /// isn't a number counts as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// The What's New sheet at launch (D92).
public enum WhatsNew {
    public static let lastSeenKey = "lastSeenVersion"

    /// What to show on this launch; records `current` as seen. `ranBefore`:
    /// Beaver had a store before this launch. An upgrade from a Beaver
    /// without What's New has no `lastSeenVersion`, so it gets the current
    /// version's notes; a fresh install gets nothing.
    public static func atLaunch(_ changelog: Changelog, current: String, ranBefore: Bool,
                                defaults: UserDefaults = .standard) -> [Changelog.Release] {
        let lastSeen = defaults.string(forKey: lastSeenKey)
        // A downgrade keeps the newer version, so going back up isn't news.
        if lastSeen.map({ Changelog.compare(current, $0) == .orderedDescending }) ?? true {
            defaults.set(current, forKey: lastSeenKey)
        }
        guard let lastSeen else {
            return ranBefore ? changelog.releases.filter { Changelog.compare($0.version, current) == .orderedSame } : []
        }
        return changelog.releases(after: lastSeen, upTo: current)
    }

    /// The menu item and the About tab: every release up to `current`,
    /// back to 1.0, newest first.
    public static func history(_ changelog: Changelog, current: String) -> [Changelog.Release] {
        changelog.releases(after: nil, upTo: current)
    }
}
