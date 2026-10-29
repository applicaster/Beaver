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
    public var lastError: String?
    /// What Play Next would play now; nil when there's nothing next (or an older QuickBrick).
    public var nextTitle: String?

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
        streamType = json["live"]?.bool.map { live in
            live ? ((seekableDuration ?? 0) > 0 ? .liveDvr : .live) : .vod
        }
        drm = json["drm"]?.array?.compactMap(\.string)
        lastError = json["lastError"]?["message"]?.string ?? json["lastError"]?.string
        nextTitle = json["next"].flatMap { $0["title"]?.string ?? $0["id"]?.string }
    }

    public var isLive: Bool { streamType == .live || streamType == .liveDvr }

    /// Where the bar's thumb is and how long the bar is, on the content's clock.
    /// None on live: engines count live positions differently, so the bar would lie.
    public var timeline: (position: Double, length: Double)? {
        guard !isLive, let position = contentPosition ?? position,
              let length = contentDuration ?? duration, length > 0 else { return nil }
        return (position, length)
    }

    /// No seeking on live (v1): the app's own controls seek live by offset,
    /// and engines disagree on which way a live position counts.
    public var canSeek: Bool { active && !ad && !isLive && seekableDuration != 0 }
}

public enum PlayerCommand: Sendable, Equatable {
    case play, pause, offset(Double), seek(Double), next

    public var tool: String {
        switch self {
        case .play: "player.play"
        case .pause: "player.pause"
        case .offset: "player.offset"
        case .seek: "player.seek"
        case .next: "player.next"
        }
    }

    public func arguments(_ state: PlayerState?) -> JSON {
        switch self {
        case .play, .pause, .next: [:]
        case .offset(let s): ["seconds": .number(s)]
        case .seek(let p): ["position": .number(p)]
        }
    }
}

/// Ad breaks Beaver saw while polling: the content position under the ad when
/// the app reports it, else that of the last poll before `ad` turned true (up
/// to one poll early). VOD only: a live DVR window slides under fixed ticks.
/// A new entry clears them.
public struct SeenAdBreaks: Sendable, Equatable {
    static let sameBreak = 2.0

    public private(set) var positions: [Double] = []
    private var entryId: String?
    private var lastContent: Double?
    private var wasAd = false

    public init() {}

    public mutating func observe(_ state: PlayerState) {
        guard state.active, !state.isLive else { return }
        if state.entryId != entryId { self = SeenAdBreaks(); entryId = state.entryId }
        if state.ad, !wasAd, let at = state.contentPosition ?? lastContent,
           !positions.contains(where: { abs($0 - at) < Self.sameBreak }) {
            positions.append(at)
            positions.sort()
        }
        wasAd = state.ad
        if !state.ad { lastContent = state.contentPosition ?? state.position }
    }

    /// A seek moved the playhead: the last position no longer says where an ad starts.
    public mutating func forgetPosition() { lastContent = nil }
}

/// Polls the viewed app's `player.state` and sends the block's commands.
/// The view's `.task(id:)` runs `run()` and cancels it when the viewed
/// session changes or stops being live.
@MainActor @Observable
public final class PlayerPoller {
    /// The app has the `player` toolbox: the block shows.
    public private(set) var available = false
    public private(set) var state: PlayerState?
    /// Why the last call failed, one line; nil after a good poll.
    public private(set) var reason: String?
    public private(set) var failures = 0
    public private(set) var seen = SeenAdBreaks()
    /// The bar's position and length on the content's clock. During an ad
    /// on an app that doesn't report `contentPosition`, the last content values.
    public private(set) var timeline: (position: Double, length: Double)?

    @ObservationIgnored public let sessionId: Int64
    @ObservationIgnored private let device: any DeviceLink
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var polling = false
    /// A command is on its way: further clicks are dropped, so they don't
    /// queue on the device's one-at-a-time line ahead of agents' calls.
    public private(set) var sending = false

    /// Short, so a slow app never keeps an agent's tools_call waiting behind a poll for long.
    static let pollTimeout: Duration = .seconds(3)
    static let slowInterval: Duration = .seconds(5)
    static let rediscoverInterval: Duration = .seconds(10)

    public init(device: any DeviceLink, sessionId: Int64, interval: Duration = .seconds(1)) {
        self.device = device
        self.sessionId = sessionId
        self.interval = interval
    }

    /// Until cancelled: look for the toolbox every 10 s, then poll every
    /// second (every 5 s after three failures in a row).
    public func run() async {
        while !Task.isCancelled {
            if !available { await discover() }
            if available { await poll() }
            let wait = !available ? Self.rediscoverInterval : failures >= 3 ? Self.slowInterval : interval
            try? await Task.sleep(for: wait)
        }
    }

    public func discover() async {
        let tools = try? await device.mcp("tools/list", params: [:], to: sessionId,
                                          timeout: DeviceMCPClient.listTimeout, onSent: nil)
        available = tools.map { Toolboxes.tools(fromListResult: $0).contains { $0.name == "player.state" } } ?? false
    }

    /// One at a time: a poll already on its way answers for this one too.
    public func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let answer: AppBuild.Answer
        do {
            answer = AppBuild.answer(fromCallResult: try await call("player.state", [:], timeout: Self.pollTimeout))
        } catch {
            answer = .failed(Self.line(error))
        }
        switch answer {
        case .value(let json):
            let s = PlayerState(json: json)
            if s.entryId != state?.entryId { timeline = nil }
            state = s
            seen.observe(s)
            if !s.active { timeline = nil } else if !s.ad || s.contentPosition != nil { timeline = s.timeline }
            reason = nil
            failures = 0
        case .noTool:
            available = false
            state = nil
        case .failed(let why):
            reason = why
            failures += 1
        }
    }

    /// The command, then a poll at once; the command's error outlives the poll.
    public func send(_ command: PlayerCommand) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        switch command {
        case .seek, .offset: seen.forgetPosition()
        case .play, .pause, .next: break
        }
        var failure: String?
        do {
            let reply = try await call(command.tool, command.arguments(state), timeout: DeviceMCPClient.callTimeout)
            if reply["isError"]?.bool == true {
                let text = reply["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
                failure = text.isEmpty ? "The app refused \(command.tool)." : String(text.prefix(200))
            }
        } catch {
            failure = Self.line(error)
        }
        await poll()
        if let failure { reason = failure }
    }

    private func call(_ tool: String, _ arguments: JSON, timeout: Duration) async throws -> JSON {
        try await device.mcp("tools/call", params: ["name": .string(tool), "arguments": arguments],
                             to: sessionId, timeout: timeout, onSent: nil)
    }

    static func line(_ error: any Error) -> String {
        switch error as? DeviceMCPError {
        case .timeout: "The app didn't answer in time."
        case .disconnected: "The app disconnected."
        case .unsupported: "The app has no toolboxes."
        case .notSent(let why): why.prefix(1).uppercased() + why.dropFirst() + "."
        case .rpc(_, let message): message
        case nil: error.localizedDescription
        }
    }
}
