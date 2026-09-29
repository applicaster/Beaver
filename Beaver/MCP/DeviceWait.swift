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

/// Follows one device across reconnects (D66). With several devices (D73)
/// a new live session continues the device when its device id matches
/// (D77); a different known device id is another device. Without device
/// ids, the fingerprint decides as a fallback; when either fingerprint is
/// still unknown, only the one session that came up since the last look.
// ponytail: the fingerprint heuristic is now the fallback for SDKs without a
// client handshake (D77). A session whose handshake lands after the 250 ms
// poll that sees it appear is judged by fingerprint on that poll.
struct DeviceFollower: Sendable {
    enum Step: Equatable { case same, moved(Int64), gone }

    private(set) var current: Int64
    private var lastLive: Set<Int64>
    /// Sessions live at the same time as `current`: another device, so
    /// never its restart — not even a twin with the same fingerprint.
    private var alongside: Set<Int64>

    init(start: Int64, live: [Int64]) {
        current = start
        lastLive = Set(live)
        alongside = Set(live)
    }

    /// nil while the set of live sessions hasn't changed since the last call.
    mutating func step(live: [Int64], store: LogStore) async -> Step? {
        let now = Set(live)
        guard now != lastLive else { return nil }
        let appeared = now.subtracting(lastLive)
        lastLive = now
        if now.contains(current) {
            alongside.formUnion(now)
            return .same
        }
        let sessions = (try? await store.sessions()) ?? []
        let candidates = sessions.filter { now.contains($0.id) && !alongside.contains($0.id) }
        // A deleted row (the user deleted a live session) knows no
        // fingerprint: the one session that came up since continues it.
        let ended = sessions.first(where: { $0.id == current })
            ?? Session(id: current, startedAt: .distantPast, source: .live)
        guard let next = Self.successor(of: ended, live: candidates, appeared: appeared) else { return .gone }
        current = next
        alongside = now
        return .moved(next)
    }

    static func successor(of ended: Session, live: [Session], appeared: Set<Int64>) -> Int64? {
        // D77: a known device id decides; a different known one is another device.
        let newer = live.filter {
            $0.id > ended.id && (ended.deviceUID == nil || $0.deviceUID == nil || $0.deviceUID == ended.deviceUID)
        }
        if let uid = ended.deviceUID, let same = newer.filter({ $0.deviceUID == uid }).map(\.id).max() {
            return same
        }
        if let print = ended.fingerprint,
           let same = newer.filter({ $0.fingerprint == print }).map(\.id).max() {
            return same
        }
        let unknown = newer.filter {
            appeared.contains($0.id) && (ended.fingerprint == nil || $0.fingerprint == nil)
        }
        return unknown.count == 1 ? unknown[0].id : nil
    }
}

extension Session {
    /// Which app on which device, to tell devices apart; nil until the SDK reports it.
    var fingerprint: [String]? {
        guard let appName else { return nil }
        return [appName, deviceModel ?? "", platform ?? ""]
    }
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
        let liveAtStart = await ui.snapshot().liveSessionIds
        var device = DeviceFollower(start: start.id, live: liveAtStart)
        let pinnedWasLive = !follows && liveAtStart.contains(start.id)
        var result = WaitResult(sessionId: start.id)
        result.liveSessionId = liveAtStart.contains(start.id) ? start.id : nil
        let deadline = ContinuousClock.now + timeout

        while true {
            (result.events, result.total) = try await read(segments, filter: filter, limit: limit)
            let done = (untilFirst && result.total > 0) || result.sessionEnded
            if done || ContinuousClock.now >= deadline || Task.isCancelled {
                result.sessionId = segments[segments.count - 1].sessionId
                result.timedOut = untilFirst && result.total == 0 && !result.sessionEnded
                return result
            }
            try? await Task.sleep(for: Self.pollInterval)
            guard let step = await device.step(live: await ui.snapshot().liveSessionIds, store: store) else { continue }
            switch step {
            case .same:
                result.deviceDisconnected = false
            case .moved(let next):
                result.liveSessionId = next
                result.deviceDisconnected = false
                if follows, !segments.contains(where: { $0.sessionId == next }) {
                    segments.append(WaitSegment(sessionId: next, afterId: 0))
                    result.sessionChanged = SessionChange(from: start.id, to: next)
                } else if pinnedWasLive {
                    result.sessionEnded = true
                }
            case .gone:
                result.liveSessionId = nil
                if follows {
                    result.deviceDisconnected = true
                } else if pinnedWasLive {
                    result.sessionEnded = true
                    result.deviceDisconnected = true
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
            if useDefault, let preferred = host.defaultDevice {
                if let id = preferred.liveSession(in: try await store.sessions(), live: live) { return (host, id) }
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
        return name + (host.defaultDevice != nil && (wanted == nil || wanted == "current") ? " (default)" : "")
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
    /// command, one system entry says so — written when it is back (with
    /// its new session) or when it hasn't come back within another `window`.
    /// Replaces any earlier command's watcher, so N commands before a restart
    /// write one entry, naming the last. `token` lets the caller stop it
    /// (`Watches.cancelDisconnectWatcher`).
    func watchForDisconnect(after command: String, sessionId: Int64, window: Duration = .seconds(30),
                            token: UUID = UUID()) async {
        // The command's session counts as live even if the app already
        // dropped before this snapshot (a restart that answers and exits).
        let liveNow = Array(Set(await ui.snapshot().liveSessionIds).union([sessionId]))
        await watches.setDisconnectWatcher(token: token, Task { [self] in
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
                    if case .moved(let id)? = await device.step(live: await ui.snapshot().liveSessionIds, store: store) {
                        back = id
                    }
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
