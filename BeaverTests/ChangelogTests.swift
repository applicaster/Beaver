import Foundation
import Testing
@testable import BeaverCore

@Suite("Changelog and What's New (D92)")
struct ChangelogTests {

    static let sample = """
        # Beaver — Changelog

        Intro with a [link](https://example.com).

        ## [Unreleased]

        ### Added
        - Not released yet.

        ## [4.2.0] - 2026-09-29

        ### Added
        - **Bold** thing with `code`,
          wrapped onto a second line.
        - Second.

        ### Fixed
        - A fix.

        ## [4.1.0] - 2026-09-28

        ### Changed
        * Star bullet.

        ## [4.0.1]

        Plumbing only.
        Two lines.

        ## [1.0] - 2026-05-18

        Initial release.

        [Unreleased]: https://example.com/compare/4.2.0...HEAD
        [1.0]: https://example.com/releases/tag/1.0
        """

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ChangelogTests-\(UUID().uuidString)")!
    }

    @Test("Sections, dates and groups; Unreleased is skipped")
    func sections() {
        let log = Changelog(markdown: Self.sample)
        #expect(log.releases.map(\.version) == ["4.2.0", "4.1.0", "4.0.1", "1.0"])
        #expect(log.releases.map(\.date) == ["2026-09-29", "2026-09-28", nil, "2026-05-18"])
        let first = log.releases[0]
        #expect(first.groups.map(\.title) == ["Added", "Fixed"])
        #expect(first.groups[0].blocks == [
            .bullet("**Bold** thing with `code`, wrapped onto a second line."),
            .bullet("Second."),
        ])
        #expect(log.releases[1].groups[0].blocks == [.bullet("Star bullet.")])
        #expect(log.releases[2].groups == [.init(title: nil, blocks: [.paragraph("Plumbing only. Two lines.")])])
        // The link list at the end isn't part of 1.0.
        #expect(log.releases[3].groups == [.init(title: nil, blocks: [.paragraph("Initial release.")])])
    }

    @Test("Malformed input gives what it can, never crashes")
    func malformed() {
        #expect(Changelog(markdown: "").releases.isEmpty)
        #expect(Changelog(markdown: "- a bullet\n### Added\nno versions").releases.isEmpty)
        let odd = Changelog(markdown: "## [4.0.0 - broken\n- x\n## [beta] - 2026\n- y\n## [3.0.0] - \n- z\n### \n")
        #expect(odd.releases.map(\.version) == ["3.0.0"])
        #expect(odd.releases[0].groups.flatMap(\.blocks) == [.bullet("z")])
    }

    @Test("Versions compare numerically")
    func compare() {
        #expect(Changelog.compare("4.10.0", "4.9.0") == .orderedDescending)
        #expect(Changelog.compare("1.0", "1.0.0") == .orderedSame)
        #expect(Changelog.compare("4.14.1", "4.15") == .orderedAscending)
    }

    @Test("Releases newer than the last seen, up to the running one")
    func since() {
        let log = Changelog(markdown: Self.sample)
        #expect(log.releases(after: "4.0.1", upTo: "4.2.0").map(\.version) == ["4.2.0", "4.1.0"])
        #expect(log.releases(after: "4.1.0", upTo: "4.1.0").isEmpty)
        // A section newer than the build (a dev build's file) isn't shown.
        #expect(log.releases(after: "1.0", upTo: "4.1.0").map(\.version) == ["4.1.0", "4.0.1"])
        #expect(log.releases(after: nil, upTo: "4.0.1").map(\.version) == ["4.0.1", "1.0"])
    }

    @Test("At launch: fresh install shows nothing, upgrade shows what's new, once")
    func atLaunch() {
        let log = Changelog(markdown: Self.sample)

        let fresh = freshDefaults()
        #expect(WhatsNew.atLaunch(log, current: "4.2.0", ranBefore: false, defaults: fresh).isEmpty)
        #expect(fresh.string(forKey: WhatsNew.lastSeenKey) == "4.2.0")

        // Upgraded from a Beaver without What's New: only this version.
        let old = freshDefaults()
        #expect(WhatsNew.atLaunch(log, current: "4.2.0", ranBefore: true, defaults: old).map(\.version) == ["4.2.0"])

        let seen = freshDefaults()
        seen.set("4.0.1", forKey: WhatsNew.lastSeenKey)
        #expect(WhatsNew.atLaunch(log, current: "4.2.0", ranBefore: true, defaults: seen).map(\.version) == ["4.2.0", "4.1.0"])
        #expect(WhatsNew.atLaunch(log, current: "4.2.0", ranBefore: true, defaults: seen).isEmpty)

        // A downgrade shows nothing and keeps the newer version as seen.
        #expect(WhatsNew.atLaunch(log, current: "4.1.0", ranBefore: true, defaults: seen).isEmpty)
        #expect(seen.string(forKey: WhatsNew.lastSeenKey) == "4.2.0")
    }

    @Test("Recent: the latest few up to the running version")
    func history() {
        let log = Changelog(markdown: Self.sample)
        #expect(WhatsNew.history(log, current: "4.1.0").map(\.version) == ["4.1.0", "4.0.1", "1.0"])
    }

    @Test("The repo's CHANGELOG.md parses")
    func repoChangelog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let log = Changelog(markdown: try String(contentsOf: url, encoding: .utf8))
        #expect(log.releases.count > 20)
        #expect(log.releases.last?.version == "1.0")
        #expect(log.releases.filter { !$0.groups.isEmpty }.count > 20)  // 4.1.0 is an empty "### Added"
        // Newest first, strictly.
        for (a, b) in zip(log.releases, log.releases.dropFirst()) {
            #expect(Changelog.compare(a.version, b.version) == .orderedDescending, "\(a.version) before \(b.version)")
        }
    }
}
