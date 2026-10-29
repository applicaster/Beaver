import Testing
import Foundation
@testable import BeaverCore

@Suite("Player controls: state, commands, seen ad breaks (D99)")
struct PlayerControlTests {

    /// `player.state` as QuickBrick v16.0.0-rc.108 answers it.
    static let today: JSON = [
        "active": true, "playerId": "p", "entry": ["id": "e1", "title": "T"], "position": 12, "duration": 100,
        "playing": true, "buffering": false, "readyToPlay": true, "ad": false, "live": false, "muted": false,
        "role": "Primary", "casting": false,
    ]

    static func with(_ base: JSON, _ extra: [String: JSON]) -> JSON {
        .object((base.object ?? [:]).merging(extra) { $1 })
    }

    static func state(entry: String = "e1", position: Double, ad: Bool) -> PlayerState {
        PlayerState(json: with(today, ["entry": ["id": .string(entry)], "position": .number(position), "ad": .bool(ad)]))
    }

    @Test("Today's shape: entry, VOD from live:false, timeline from position/duration, seekable")
    func stateParsesToday() {
        let s = PlayerState(json: Self.today)
        #expect(s.active)
        #expect(s.entryId == "e1")
        #expect(s.title == "T")
        #expect(s.playing)
        #expect(s.role == "Primary")
        #expect(s.streamType == .vod)
        #expect(s.drm == nil)
        #expect(s.adBreaks == nil)
        #expect(s.timeline?.position == 12)
        #expect(s.timeline?.length == 100)
        #expect(s.canSeek)
    }

    @Test("The richer shape: DVR timeline, DRM, reported breaks, last error")
    func stateParsesRich() {
        let s = PlayerState(json: Self.with(Self.today, [
            "live": true, "streamType": "liveDvr", "seekableDuration": 3600, "contentPosition": 3500,
            "drm": ["widevine"], "adBreaks": [0, 600], "lastError": ["message": "403", "detail": "Response code: 403"],
        ]))
        #expect(s.streamType == .liveDvr)
        #expect(s.timeline?.position == 3500)
        #expect(s.timeline?.length == 3600)
        #expect(s.drm == ["widevine"])
        #expect(s.adBreaks == [0, 600])
        #expect(s.lastError == "403")
    }

    @Test("Live without streamType is plain live")
    func liveWithoutType() {
        #expect(PlayerState(json: Self.with(Self.today, ["live": true])).streamType == .live)
    }

    @Test("Nothing playing: inactive, no seek, no timeline")
    func inactive() {
        let s = PlayerState(json: ["active": false, "casting": false])
        #expect(!s.active)
        #expect(!s.canSeek)
        #expect(s.timeline == nil)
    }

    @Test("No seeking during an ad or with an empty seekable range")
    func noSeekDuringAdOrZeroRange() {
        #expect(!PlayerState(json: Self.with(Self.today, ["ad": true])).canSeek)
        #expect(!PlayerState(json: Self.with(Self.today, ["seekableDuration": 0])).canSeek)
    }

    @Test("Commands map to the player toolbox's tools")
    func commands() {
        #expect(PlayerCommand.play.tool == "player.play")
        #expect(PlayerCommand.pause.tool == "player.pause")
        #expect(PlayerCommand.offset(-10).tool == "player.offset")
        #expect(PlayerCommand.offset(-10).arguments(nil) == ["seconds": -10])
        #expect(PlayerCommand.seek(42).arguments(nil) == ["position": 42])
        let dvr = PlayerState(json: Self.with(Self.today, ["seekableDuration": 3600]))
        #expect(PlayerCommand.goLive.tool == "player.seek")
        #expect(PlayerCommand.goLive.arguments(dvr) == ["position": 3600])
    }

    @Test("A break is the content position of the last poll before the ad")
    func seenBreaksRecordAdStart() {
        var seen = SeenAdBreaks()
        for (p, ad) in [(100.0, false), (101, true), (101, true), (102, false)] { seen.observe(Self.state(position: p, ad: ad)) }
        #expect(seen.positions == [100])
    }

    @Test("A pre-roll has no content position before it: no marker")
    func seenBreaksIgnorePreroll() {
        var seen = SeenAdBreaks()
        seen.observe(Self.state(position: 5, ad: true))
        seen.observe(Self.state(position: 0, ad: false))
        #expect(seen.positions == [])
    }

    @Test("A new entry starts with no seen breaks")
    func seenBreaksResetOnNewEntry() {
        var seen = SeenAdBreaks()
        seen.observe(Self.state(position: 100, ad: false))
        seen.observe(Self.state(position: 100, ad: true))
        seen.observe(Self.state(entry: "e2", position: 3, ad: false))
        #expect(seen.positions == [])
    }

    @Test("Reported breaks win; a seen one within 2 s of a reported one is the same break")
    func mergeWithin2s() {
        var seen = SeenAdBreaks()
        seen.observe(Self.state(position: 100, ad: false))
        seen.observe(Self.state(position: 100, ad: true))
        #expect(seen.merged(with: [99, 600]) == [99, 600])
        #expect(seen.merged(with: nil) == [100])
        #expect(seen.merged(with: [600]) == [100, 600])
    }
}
