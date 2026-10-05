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
            parts.append("The device came back in a new session: carried on from session #\(c.from) into #\(c.to).")
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

/// Follows one device across reconnects (D66). With several devices (D73)
/// a new live session continues the device when its device id matches
/// (D77); a different known device id is another device. Without device
/// ids, the fingerprint decides as a fallback; when either fingerprint is
/// still unknown, only the one session that came up since the last look.
///
/// D97: a reconnect of the same app launch carries on in a session the
/// follower was already in, so the return of any of them is `.same`. On the
/// way the connection opens a fresh session that is deleted a moment later:
/// a session that says nothing about itself (no device id, no fingerprint,
/// no event) isn't followed until it has been up for `settle`.
// ponytail: the fingerprint heuristic is now the fallback for SDKs without a
// client handshake (D77). A session whose handshake lands after the 250 ms
// poll that sees it appear is judged by fingerprint on that poll.
struct DeviceFollower: Sendable {
    enum Step: Equatable { case same, moved(Int64), gone }

    static let settle: Duration = .milliseconds(1500)

    private(set) var current: Int64
    /// Every session this follower has been in.
    private(set) var visited: [Int64]
    private var lastLive: Set<Int64>
    /// Sessions live at the same time as `current`: another device, so
    /// never its restart — not even a twin with the same fingerprint.
    private var alongside: Set<Int64>
    /// The device as last seen in the store: survives its row being deleted.
    private var identity: Session?
    private var seenAt: [Int64: ContinuousClock.Instant] = [:]
    /// Silent sessions not old enough yet: looked at again on the next call.
    private var settling: Set<Int64> = []
    /// Candidates already judged and passed over; not "just came up" again.
    private var considered: Set<Int64> = []
    private var lastStep: Step = .same

    init(start: Int64, live: [Int64]) {
        current = start
        visited = [start]
        lastLive = Set(live)
        alongside = Set(live)
    }

    /// nil while nothing changed since the last call.
    mutating func step(live: [Int64], store: LogStore, now: ContinuousClock.Instant = .now) async -> Step? {
        let nowLive = Set(live)
        guard nowLive != lastLive || !settling.isEmpty else { return nil }
        for id in nowLive.subtracting(lastLive) { seenAt[id] = now }
        lastLive = nowLive
        settling = []
        // Back in a session it was in (D97 reopens it), or never left.
        if let back = visited.last(where: nowLive.contains) {
            current = back
            alongside.formUnion(nowLive)
            considered = []
            return report(.same)
        }
        let sessions = (try? await store.sessions()) ?? []
        if let known = Self.identity(of: visited, in: sessions) { identity = known }
        var candidates: [(session: Session, latest: Int64)] = []
        for s in sessions where nowLive.contains(s.id) && !alongside.contains(s.id) {
            let latest = try? await store.latestEventId(sessionId: s.id)
            if s.deviceUID == nil, s.fingerprint == nil, latest == nil,
               now - (seenAt[s.id] ?? now) < Self.settle {
                settling.insert(s.id)
                continue
            }
            candidates.append((s, latest ?? 0))
        }
        // Least recently active first: `successor` takes the last match.
        let ordered = candidates.sorted { ($0.latest, $0.session.id) < ($1.latest, $1.session.id) }.map(\.session)
        // A deleted row (the user deleted a live session) knows no
        // fingerprint: the one session that came up since continues it.
        let ended = identity ?? Session(id: current, startedAt: .distantPast, source: .live)
        let appeared = Set(ordered.map(\.id)).subtracting(considered)
        guard let next = Self.successor(of: ended, live: ordered, appeared: appeared) else {
            considered.formUnion(ordered.map(\.id))
            return report(.gone)
        }
        current = next
        visited.append(next)
        alongside = nowLive
        considered = []
        return report(.moved(next))
    }

    /// A repeated `.gone` (re-checked while a session settles) is no news.
    private mutating func report(_ step: Step) -> Step? {
        defer { lastStep = step }
        return step == .gone && lastStep == .gone ? nil : step
    }

    /// The visited session that says most about the device: the latest with
    /// a device id, else with a fingerprint.
    private static func identity(of visited: [Int64], in sessions: [Session]) -> Session? {
        let rows = visited.reversed().compactMap { id in sessions.first { $0.id == id } }
        return rows.first { $0.deviceUID != nil } ?? rows.first { $0.fingerprint != nil } ?? rows.first
    }

    /// `live` is least recently active first; the last match wins (D97:
    /// session ids don't say which is newest).
    static func successor(of ended: Session, live: [Session], appeared: Set<Int64>) -> Int64? {
        if let same = live.last(where: ended.isSameDevice) { return same.id }
        let unknown = live.filter { appeared.contains($0.id) && !ended.canTellApart(from: $0) }
        return unknown.count == 1 ? unknown[0].id : nil
    }
}

extension Session {
    /// Which app on which device, to tell devices apart; nil until the SDK reports it.
    var fingerprint: [String]? {
        guard let appName else { return nil }
        return [appName, deviceModel ?? "", platform ?? ""]
    }

    /// Device ids (D77), or fingerprints, are known on both sides.
    func canTellApart(from other: Session) -> Bool {
        (deviceUID != nil && other.deviceUID != nil) || (fingerprint != nil && other.fingerprint != nil)
    }

    /// The same app on the same device: a known device id decides, and the
    /// fingerprint when both are known (one device runs several apps).
    /// `DeviceFollower` and a following watch's sessions use this one rule.
    func isSameDevice(_ other: Session) -> Bool {
        if let a = deviceUID, let b = other.deviceUID, a != b { return false }
        if let a = fingerprint, let b = other.fingerprint, a != b { return false }
        return canTellApart(from: other)
    }
}

extension LogStore {
    /// `ids` least recently active first, by their latest event; one with
    /// no event yet comes first. D97 continues an older session on
    /// reconnect, so the highest id isn't the newest.
    func byRecency(_ ids: [Int64]) async -> [Int64] {
        var latest: [Int64: Int64] = [:]
        for id in ids { latest[id] = try? await latestEventId(sessionId: id) }
        return ids.sorted { (latest[$0] ?? 0, $0) < (latest[$1] ?? 0, $1) }
    }
}

extension ToolContext {

    static let pollInterval: Duration = .milliseconds(250)
    /// How long a pinned session that dropped may take to come back before
    /// the wait says it ended: D97 reopens it when the same app launch
    /// reconnects (a background app, a network blip).
    static let reopenGrace: Duration = .seconds(3)

    /// Waits for events matching `filter` after `afterId`. `untilFirst`
    /// returns as soon as something matches (logs_wait); otherwise it
    /// collects for the whole window (commands_send). Polls the store and
    /// the app's live session every 250 ms.
    public func waitForEvents(from start: ResolvedSession, afterId: Int64, filter: Filter, limit: Int,
                              timeout: Duration, untilFirst: Bool) async throws -> WaitResult {
        let follows = start.how != .given
        var segments = [WaitSegment(sessionId: start.id, afterId: afterId)]
        let liveAtStart = await ui.snapshot().liveSessionIds
        var device = DeviceFollower(start: start.id, live: liveAtStart)
        let pinnedWasLive = !follows && liveAtStart.contains(start.id)
        var result = WaitResult(sessionId: start.id)
        result.liveSessionId = liveAtStart.contains(start.id) ? start.id : nil
        let deadline = ContinuousClock.now + timeout
        var endsAt: ContinuousClock.Instant?   // a pinned session dropped: ended unless back by then

        while true {
            if let endsAt, ContinuousClock.now >= endsAt { result.sessionEnded = true }
            (result.events, result.total) = try await read(segments, filter: filter, limit: limit)
            let done = (untilFirst && result.total > 0) || result.sessionEnded
            if done || ContinuousClock.now >= deadline || Task.isCancelled {
                result.sessionId = follows ? device.current : start.id
                result.timedOut = untilFirst && result.total == 0 && !result.sessionEnded
                return result
            }
            try? await Task.sleep(for: Self.pollInterval)
            guard let step = await device.step(live: await ui.snapshot().liveSessionIds, store: store) else { continue }
            switch step {
            case .same:
                // Live, or back in a session it was in (D97).
                result.deviceDisconnected = false
                result.liveSessionId = device.current
                endsAt = nil
                if follows {
                    result.sessionChanged = device.current == start.id
                        ? nil : SessionChange(from: start.id, to: device.current)
                }
            case .moved(let next):
                result.liveSessionId = next
                result.deviceDisconnected = false
                if follows {
                    if !segments.contains(where: { $0.sessionId == next }) {
                        segments.append(WaitSegment(sessionId: next, afterId: 0))
                    }
                    result.sessionChanged = SessionChange(from: start.id, to: next)
                } else if pinnedWasLive {
                    result.sessionEnded = true
                }
            case .gone:
                result.liveSessionId = nil
                if follows {
                    result.deviceDisconnected = true
                } else if pinnedWasLive {
                    result.deviceDisconnected = true
                    endsAt = endsAt ?? ContinuousClock.now + Self.reopenGrace
                }
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

    /// Design M25 / D73: tools that talk to a device take an optional
    /// deviceId — the device's live session id, as beaver_status lists it.
    /// With one device it may be omitted (or be "current", as before D73);
    /// with a default set (D76) an omitted one means the default; otherwise
    /// with several it may not. `call` is the tool's own example call; the
    /// error shows it with a deviceId filled in. `useDefault: false`
    /// (devices_disconnect) ignores the default: with several apps the
    /// caller must name one. A device that only sends logs (D89) is refused
    /// unless `logsOnlyOK` (it can still be disconnected or be the default).
    public func requireDevice(_ args: ToolArguments, doing what: String, call: String,
                              useDefault: Bool = true, logsOnlyOK: Bool = false) async throws
        -> (host: HostSnapshot, liveSessionId: Int64) {
        let (host, id) = try await pickDevice(args, doing: what, call: call, useDefault: useDefault)
        guard logsOnlyOK || !host.logsOnly.contains(id) else {
            let name = try await store.sessions().first { $0.id == id }.map(StatusTools.describeDevice) ?? "It"
            throw ToolError("Device \"\(id)\" (\(name)) only sends logs: it is a smart TV read over "
                + "DevTools, so Beaver can't \(what). Its logs are all there is. "
                + "Example: logs_query(sessionId: \(id), since: \"10m\").")
        }
        return (host, id)
    }

    private func pickDevice(_ args: ToolArguments, doing what: String, call: String,
                            useDefault: Bool) async throws -> (host: HostSnapshot, liveSessionId: Int64) {
        let host = await ui.snapshot()
        let live = host.liveSessionIds
        if try Self.isBeaver(args) {
            throw ToolError("deviceId \"beaver\" is Beaver itself, not an app, so it can't \(what). "
                + "Beaver's own tools: toolboxes_list(deviceId: \"beaver\"), or call them directly. "
                + "Example: beaver_status() for the apps' deviceIds.")
        }
        guard !live.isEmpty else {
            throw ToolError("No device is connected, so Beaver can't \(what). Ask the user to open the app with "
                + "remote assistance pointed at \(host.deviceURL ?? "Beaver"), then call beaver_status().")
        }
        let wanted = try args.string("deviceId")
        // args.string turns a number into text; accept "12", 12 and 12.0.
        if let wanted, let id = Int64(wanted) ?? Double(wanted).flatMap({ Int64(exactly: $0) }),
           live.contains(id) { return (host, id) }
        if wanted == nil || wanted == "current" {
            // D76: the default, when set, is the only fallback — never another device.
            // A `.session` default that ended never comes back: as if unset.
            if useDefault, let preferred = host.defaultDevice, !preferred.isGone(live: live) {
                let byRecency = await store.byRecency(live)
                if let id = preferred.liveSession(in: try await store.sessions(), live: byRecency) { return (host, id) }
                let list = try await describeDevices(live)
                let name = try await describeDefault(preferred)
                throw ToolError("The default device \(name) isn't connected; it may be restarting. "
                    + "Connected: \(list). Example: beaver_status() to see whether it is back, "
                    + "or devices_set_default(deviceId: null) to clear the default.")
            }
            if live.count == 1 { return (host, live[0]) }
        }
        let list = try await describeDevices(live)
        let lead = wanted.map { "No connected device \"\($0)\"." }
            ?? "\(live.count) devices are connected; say which one with deviceId."
        throw ToolError("\(lead) Connected: \(list). Example: \(Self.withDeviceId(call, live[0])).")
    }

    /// deviceId "beaver", in any case and with spaces around it.
    static func isBeaver(_ args: ToolArguments) throws -> Bool {
        try args.string("deviceId").flatMap(trimmedNonEmpty)?.lowercased() == ToolboxTools.beaverId
    }

    /// `Alpha 1.0 (iPhone 15, iOS 18.0)`, with ` (default)` when
    /// requireDevice picked it as the default: how a summary names the app
    /// a call went to.
    public func describeTarget(_ id: Int64, _ args: ToolArguments, _ host: HostSnapshot) async throws -> String {
        let name = try await store.sessions().first { $0.id == id }.map(StatusTools.describeDevice) ?? "device \"\(id)\""
        let wanted = try args.string("deviceId")
        let isDefault = host.defaultDevice.map { !$0.isGone(live: host.liveSessionIds) } ?? false
        return name + (isDefault && (wanted == nil || wanted == "current") ? " (default)" : "")
    }

    /// `commands_send(command: "x")` → `commands_send(deviceId: "12", command: "x")`.
    static func withDeviceId(_ call: String, _ id: Int64) -> String {
        guard let open = call.firstIndex(of: "(") else { return call }
        let rest = call[call.index(after: open)...]
        return String(call[...open]) + "deviceId: \"\(id)\"" + (rest.hasPrefix(")") ? "" : ", ") + rest
    }

    /// `"12" (Alpha 1.0 · iPhone 15, iOS 18.0), "14" (…)`.
    public func describeDevices(_ ids: [Int64]) async throws -> String {
        let sessions = try await store.sessions()
        return ids.map { id in
            "\"\(id)\"" + (sessions.first { $0.id == id }.map { " (\(StatusTools.describeDevice($0)))" } ?? "")
        }.joined(separator: ", ")
    }

    /// `Alpha 1.0 · iPhone 15, iOS 18.0`, or `"12" (…)` for a session default.
    public func describeDefault(_ device: DefaultDevice) async throws -> String {
        let sessions = try await store.sessions()
        switch device {
        case .session(let id):
            return "\"\(id)\"" + (sessions.first { $0.id == id }.map { " (\(StatusTools.describeDevice($0)))" } ?? "")
        case .uid(let uid):
            return sessions.first { $0.deviceUID == uid }.map(StatusTools.describeDevice) ?? "with device id \(uid)"
        }
    }

    /// Design §7.2: when the device drops within `window` after an agent's
    /// command, one system entry says so — written when it is back (in its
    /// new session, or the same one after a reconnect, D97) or when it
    /// hasn't come back within another `window`. Replaces an earlier
    /// command's watcher on the same device, so N commands before a restart
    /// write one entry, naming the last; other devices' watchers stay.
    /// `token` lets the caller stop it (`Watches.cancelDisconnectWatcher`).
    func watchForDisconnect(after command: String, sessionId: Int64, window: Duration = .seconds(30),
                            token: UUID = UUID()) async {
        // The command's session counts as live even if the app already
        // dropped before this snapshot (a restart that answers and exits).
        let liveNow = Array(Set(await ui.snapshot().liveSessionIds).union([sessionId]))
        await watches.setDisconnectWatcher(token: token, sessionId: sessionId, Task { [self] in
            var device = DeviceFollower(start: sessionId, live: liveNow)
            let dropDeadline = ContinuousClock.now + window
            while ContinuousClock.now < dropDeadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard let step = await device.step(live: await ui.snapshot().liveSessionIds, store: store),
                      step != .same else { continue }
                var back: Int64?
                if case .moved(let id) = step { back = id }
                let backDeadline = ContinuousClock.now + window
                while back == nil, ContinuousClock.now < backDeadline {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    switch await device.step(live: await ui.snapshot().liveSessionIds, store: store) {
                    case .moved(let id)?: back = id
                    case .same?: back = device.current   // reconnected into its session (D97)
                    default: break
                    }
                }
                guard !Task.isCancelled else { return }
                let outcome = back.map { $0 == sessionId ? " → back in session #\($0)" : " → session #\($0)" }
                    ?? "; not back after \(window.components.seconds) s"
                await AgentJournal(store: store).post(.system, "Device disconnected after \"\(command)\"\(outcome)",
                                                      sessionId: back ?? sessionId)
                return
            }
        })
    }
}
