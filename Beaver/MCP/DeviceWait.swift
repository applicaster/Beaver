//
//  DeviceWait.swift
//  Beaver
//
//  Design M26 (D66): an omitted sessionId follows the device across a
//  reconnect; a given one is pinned and reports that it ended.

import Foundation

public struct SessionChange: Sendable, Equatable {
    public let from: Int64
    public let to: Int64
}

public struct WaitResult: Sendable {
    public var events: [EventRecord] = []
    public var total = 0
    /// Where the wait ended up: the new session after a reconnect.
    public var sessionId: Int64
    public var sessionChanged: SessionChange?
    /// A pinned session stopped being the live one during the wait.
    public var sessionEnded = false
    public var liveSessionId: Int64?
    /// The device dropped and wasn't back when the wait ended.
    public var deviceDisconnected = false
    public var timedOut = false

    /// What happened to the device, for the summary; empty when nothing did.
    public var followText: String {
        var parts: [String] = []
        if let c = sessionChanged {
            parts.append("The device reconnected: carried on from session #\(c.from) into #\(c.to).")
        }
        if sessionEnded {
            parts.append("The session ended" + (liveSessionId.map { "; the device is now in session #\($0)." } ?? "."))
        }
        if deviceDisconnected { parts.append("The device is disconnected and hasn't come back.") }
        return parts.joined(separator: " ")
    }

    public var followFields: [String: JSON] {
        [
            "sessionChanged": sessionChanged.map { ["from": JSON($0.from), "to": JSON($0.to)] } ?? .null,
            "sessionEnded": .bool(sessionEnded),
            "deviceDisconnected": .bool(deviceDisconnected),
            "liveSessionId": JSON(liveSessionId),
        ]
    }
}

struct WaitSegment: Sendable {
    let sessionId: Int64
    let afterId: Int64
}

extension ToolContext {

    static let pollInterval: Duration = .milliseconds(250)

    /// Waits for events matching `filter` after `afterId`. `untilFirst`
    /// returns as soon as something matches (logs_wait); otherwise it
    /// collects for the whole window (commands_send). Polls the store and
    /// the app's live session every 250 ms.
    public func waitForEvents(from start: ResolvedSession, afterId: Int64, filter: Filter, limit: Int,
                              timeout: Duration, untilFirst: Bool) async throws -> WaitResult {
        let follows = start.how != .given
        var segments = [WaitSegment(sessionId: start.id, afterId: afterId)]
        var lastLive = await ui.snapshot().liveSessionId
        let pinnedWasLive = !follows && lastLive == start.id
        var result = WaitResult(sessionId: start.id)
        let deadline = ContinuousClock.now + timeout

        while true {
            (result.events, result.total) = try await read(segments, filter: filter, limit: limit)
            let done = (untilFirst && result.total > 0) || result.sessionEnded
            if done || ContinuousClock.now >= deadline || Task.isCancelled {
                result.sessionId = segments[segments.count - 1].sessionId
                result.liveSessionId = lastLive
                result.timedOut = untilFirst && result.total == 0 && !result.sessionEnded
                return result
            }
            try? await Task.sleep(for: Self.pollInterval)
            let live = await ui.snapshot().liveSessionId
            guard live != lastLive else { continue }
            lastLive = live
            if follows {
                if let live {
                    if !segments.contains(where: { $0.sessionId == live }) {
                        segments.append(WaitSegment(sessionId: live, afterId: 0))
                        result.sessionChanged = SessionChange(from: start.id, to: live)
                    }
                    result.deviceDisconnected = false
                } else {
                    result.deviceDisconnected = true
                }
            } else if pinnedWasLive {
                result.sessionEnded = true
                result.deviceDisconnected = live == nil
            }
        }
    }

    private func read(_ segments: [WaitSegment], filter: Filter, limit: Int) async throws -> ([EventRecord], Int) {
        var events: [EventRecord] = []
        var total = 0
        for segment in segments {
            let page = try await store.eventPage(sessionId: segment.sessionId, filter: filter,
                                                 afterId: segment.afterId,
                                                 limit: max(0, limit - events.count), newestFirst: false)
            events += page.events
            total += page.total
        }
        return (events, total)
    }

    /// Design M25: tools that talk to the device take an optional deviceId;
    /// today there is one device, "current".
    public func requireDevice(_ args: ToolArguments, doing what: String) async throws
        -> (host: HostSnapshot, liveSessionId: Int64) {
        let host = await ui.snapshot()
        if let id = try args.string("deviceId"), id != "current" {
            throw ToolError("No device \"\(id)\". Connected: \(host.deviceConnected ? "\"current\"" : "none"). "
                + "Example: omit deviceId — Beaver has one device at a time.")
        }
        guard host.deviceConnected, let live = host.liveSessionId else {
            throw ToolError("No device is connected, so Beaver can't \(what). Ask the user to open the app with "
                + "remote assistance pointed at \(host.deviceURL ?? "Beaver"), then call beaver_status().")
        }
        return (host, live)
    }

    /// Design §7.2: when the device drops within `window` after an agent's
    /// command, one system entry says so — written when it is back (with
    /// its new session) or when it hasn't come back within another `window`.
    /// Replaces any earlier command's watcher, so N commands before a restart
    /// write one entry, naming the last.
    func watchForDisconnect(after command: String, sessionId: Int64, window: Duration = .seconds(30)) async {
        await watches.setDisconnectWatcher(Task { [self] in
            let dropDeadline = ContinuousClock.now + window
            while ContinuousClock.now < dropDeadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard await ui.snapshot().liveSessionId != sessionId else { continue }
                let backDeadline = ContinuousClock.now + window
                var back = await ui.snapshot().liveSessionId
                while back == nil, ContinuousClock.now < backDeadline {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    back = await ui.snapshot().liveSessionId
                }
                guard !Task.isCancelled else { return }
                let outcome = back.map { " → session #\($0)" } ?? "; not back after \(window.components.seconds) s"
                await AgentJournal(store: store).post(.system, "Device disconnected after \"\(command)\"\(outcome)",
                                                      sessionId: back ?? sessionId)
                return
            }
        })
    }
}
