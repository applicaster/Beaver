//
//  PlayerControl.swift
//  Beaver
//
//  D99: the Log feed's player block drives the viewed app's X-Ray `player`
//  toolbox (QuickBrick's playerToolbox.ts). Every field past what
//  QuickBrick v16.0.0-rc.108 sends is optional: an older app shows less.

import Foundation

public enum StreamType: String, Sendable {
    case vod, live, liveDvr
}

/// One `player.state` answer.
public struct PlayerState: Sendable, Equatable {
    public var active = false
    public var entryId: String?
    public var title: String?
    public var position: Double?
    public var duration: Double?
    /// On the content's clock even during an ad, where `position` and
    /// `duration` are the ad's.
    public var contentPosition: Double?
    public var contentDuration: Double?
    /// What a seek can reach: the DVR window on live, the content on VOD.
    public var seekableDuration: Double?
    public var playing = false
    public var buffering = false
    public var ad = false
    public var muted = false
    public var casting = false
    public var role: String?
    public var streamType: StreamType?
    /// Key systems, e.g. ["widevine"].
    public var drm: [String]?
    public var adBreaks: [Double]?
    public var lastError: String?

    public init(json: JSON) {
        active = json["active"]?.bool ?? false
        casting = json["casting"]?.bool ?? false
        guard active else { return }
        entryId = json["entry"]?["id"]?.string ?? json["entry"]?["id"]?.int.map(String.init)
        title = json["entry"]?["title"]?.string
        position = json["position"]?.double
        duration = json["duration"]?.double
        contentPosition = json["contentPosition"]?.double
        contentDuration = json["contentDuration"]?.double
        seekableDuration = json["seekableDuration"]?.double
        playing = json["playing"]?.bool ?? false
        buffering = json["buffering"]?.bool ?? false
        ad = json["ad"]?.bool ?? false
        muted = json["muted"]?.bool ?? false
        role = json["role"]?.string
        streamType = json["streamType"]?.string.flatMap(StreamType.init)
            ?? json["live"]?.bool.map { $0 ? .live : .vod }
        drm = json["drm"]?.array?.compactMap(\.string)
        adBreaks = json["adBreaks"]?.array?.compactMap(\.double).sorted()
        lastError = json["lastError"]?["message"]?.string ?? json["lastError"]?.string
    }

    /// Where the bar's thumb is and how long the bar is, on the content's clock.
    public var timeline: (position: Double, length: Double)? {
        guard let position = contentPosition ?? position,
              let length = streamType == .liveDvr ? seekableDuration : (contentDuration ?? duration),
              length > 0 else { return nil }
        return (position, length)
    }

    /// A missing `seekableDuration` (older QuickBrick) leaves it to the app to refuse.
    public var canSeek: Bool { active && !ad && seekableDuration != 0 }
}

public enum PlayerCommand: Sendable, Equatable {
    case play, pause, offset(Double), seek(Double), goLive

    public var tool: String {
        switch self {
        case .play: "player.play"
        case .pause: "player.pause"
        case .offset: "player.offset"
        case .seek, .goLive: "player.seek"
        }
    }

    /// Go live seeks to the end of the DVR window; the app clamps it.
    public func arguments(_ state: PlayerState?) -> JSON {
        switch self {
        case .play, .pause: [:]
        case .offset(let s): ["seconds": .number(s)]
        case .seek(let p): ["position": .number(p)]
        case .goLive: ["position": .number(state?.seekableDuration ?? .greatestFiniteMagnitude)]
        }
    }
}

/// Ad breaks Beaver saw while polling: the content position of the last
/// poll before `ad` turned true. Up to one poll early. A new entry clears them.
public struct SeenAdBreaks: Sendable, Equatable {
    static let sameBreak = 2.0

    public private(set) var positions: [Double] = []
    private var entryId: String?
    private var lastContent: Double?
    private var wasAd = false

    public init() {}

    public mutating func observe(_ state: PlayerState) {
        guard state.active else { return }
        if state.entryId != entryId { self = SeenAdBreaks(); entryId = state.entryId }
        if state.ad, !wasAd, let at = lastContent, !positions.contains(where: { abs($0 - at) < Self.sameBreak }) {
            positions.append(at)
            positions.sort()
        }
        wasAd = state.ad
        if !state.ad { lastContent = state.contentPosition ?? state.position }
    }

    /// Reported breaks, plus the seen ones no reported break is near.
    public func merged(with reported: [Double]?) -> [Double] {
        let reported = reported ?? []
        return (reported + positions.filter { p in !reported.contains { abs($0 - p) < Self.sameBreak } }).sorted()
    }
}
