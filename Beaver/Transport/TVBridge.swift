//
//  TVBridge.swift
//  Beaver
//
//  D94: a smart TV read over the Chrome DevTools Protocol (CDP), from
//  Beaver itself. A port of zapp-support's `scripts/tv-bridge.mjs` (D89):
//  it reads the TV's console, exceptions and log entries and sends Beaver
//  the same `register` and `event` frames, over ws://127.0.0.1:9080, so the
//  TV is the same logs-only device whichever bridge connects it.
//

import Foundation
import Synchronization

/// Why a TV can't be read. The texts are what the Connect a TV sheet shows.
public enum TVBridgeError: Error, Equatable, LocalizedError {
    case badAddress(String)
    case unreachable(target: String, reason: String)
    case noDevTools(target: String)
    case noPage
    case pageBusy
    /// The page was found but didn't answer `Runtime.enable`.
    case attachFailed(target: String, reason: String)
    case beaverUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .badAddress(let text):
            "\"\(text)\" isn't a TV address. Type the TV's IP address, e.g. 192.168.1.40, and its DevTools port."
        case .unreachable(let target, let reason):
            "Can't reach the TV at \(target) (\(reason)). Is it on, and on this Mac's network? Check its IP address too."
        case .noDevTools(let target):
            "The TV at \(target) has no DevTools on that port (nothing listens there, or something else answers). "
                + "Check the port (Vizio 9555, Vidaa 9226, others usually 9222) and that the TV's developer mode is on."
        case .noPage:
            "The TV has no app open. Launch the app on the TV, then connect again."
        case .pageBusy:
            "The app's page is busy: close any DevTools window on the TV (chrome://inspect), then connect again."
        case .attachFailed(let target, let reason):
            "The TV at \(target) has the app's page but didn't let Beaver read it (\(reason)). Close any DevTools "
                + "window on the TV (chrome://inspect), relaunch the app, then connect again."
        case .beaverUnavailable(let reason):
            "The TV has nowhere to send its logs: \(reason). The connection pill in Beaver's toolbar (or the "
                + "main window, with no device) says whether Beaver is taking devices on port 9080."
        }
    }
}

/// The pure part of the bridge: what a TV's DevTools answers mean.
public enum CDP {

    /// The `platform` a DevTools bridge registers with: the one client that sends logs only.
    public static let platform = "tv-cdp"

    /// One entry of the TV's `/json/list`.
    public struct Page: Equatable, Sendable {
        public var type: String
        public var title: String
        /// Missing while another DevTools client is attached.
        public var socket: URL?
        /// What the page shows: the app's address, or about:blank, chrome://…
        public var url = ""
    }

    /// A log line from the TV, as `tv-bridge.mjs`'s `toEvent` builds it.
    public struct Event: Equatable, Sendable {
        public var category: String
        public var level: String
        public var timestampMillis: UInt64
        public var message: String
    }

    /// `/json/list`, or nil when the answer isn't one.
    public static func pages(_ data: Data) -> [Page]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.map {
            Page(type: $0["type"] as? String ?? "", title: $0["title"] as? String ?? "",
                 socket: ($0["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)),
                 url: $0["url"] as? String ?? "")
        }
    }

    /// The app's page: the first free one, the TV's own pages (about:blank,
    /// chrome://…) only when there's nothing else. A page without a
    /// debugger URL has another DevTools client attached (the TV takes one
    /// at a time); a busy app page isn't swapped for a free system page.
    // ponytail: URL-prefix heuristic; a TV whose launcher is an http page
    // still needs the app listed first.
    public static func pick(_ pages: [Page]) throws -> Page {
        let candidates = pages.filter { $0.type == "page" }
        let apps = candidates.filter { page in !["about:", "chrome", "devtools:"].contains { page.url.hasPrefix($0) } }
        if let free = (apps.isEmpty ? candidates : apps).first(where: { $0.socket != nil }) { return free }
        throw candidates.isEmpty ? TVBridgeError.noPage : TVBridgeError.pageBusy
    }

    /// A reply to one of the bridge's commands: its id, and the error text when it failed.
    static func reply(_ data: Data) -> (id: Int, error: String?)? {
        guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = m["id"] as? Int
        else { return nil }
        return (id, (m["error"] as? [String: Any]).map { $0["message"] as? String ?? "unknown" })
    }

    /// What a failed `GET /json/list` means. Only a refused connection
    /// (ECONNREFUSED: the TV is up, the port closed) is "no DevTools";
    /// a TV that is off, asleep or elsewhere is unreachable.
    public static func discoveryError(_ error: any Error, target: String) -> any Error {
        guard let error = error as? URLError else {
            return error is CancellationError ? error : TVBridgeError.unreachable(target: target, reason: error.localizedDescription)
        }
        let info = [error.userInfo, (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.userInfo ?? [:]]
        let refused = info.contains { $0["_kCFStreamErrorDomainKey"] as? Int == 1 && $0["_kCFStreamErrorCodeKey"] as? Int == Int(ECONNREFUSED) }
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost where refused:
            return TVBridgeError.noDevTools(target: target)
        case .notConnectedToInternet:
            return TVBridgeError.unreachable(target: target, reason: "no network — does Beaver have Local Network "
                + "access? System Settings → Privacy & Security → Local Network")
        case .timedOut:
            return TVBridgeError.unreachable(target: target, reason: "it doesn't answer")
        default:
            return TVBridgeError.unreachable(target: target, reason: error.localizedDescription)
        }
    }

    static let levels = ["warning": "warning", "warn": "warning", "error": "error", "assert": "error",
                         "debug": "debug", "verbose": "debug"]

    /// A CDP message → a log line, or nil when it isn't one. A failed
    /// command (e.g. `Log.enable` on a TV without that domain) becomes a
    /// warning, which the script printed to its terminal.
    public static func event(_ data: Data, now: UInt64) -> Event? {
        guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = m["error"] as? [String: Any] {
            return Event(category: "bridge", level: "warning", timestampMillis: now,
                         message: "CDP error: \(error["message"] as? String ?? "unknown")")
        }
        guard let method = m["method"] as? String, let p = m["params"] as? [String: Any] else { return nil }
        return event(method: method, params: p, now: now)
    }

    /// Port of `toEvent` (tv-bridge.mjs). The time is CDP's own where the
    /// message has one; the script used its own clock.
    public static func event(method: String, params p: [String: Any], now: UInt64) -> Event? {
        switch method {
        case "Runtime.consoleAPICalled":
            let args = p["args"] as? [[String: Any]] ?? []
            return Event(category: "console", level: levels[p["type"] as? String ?? ""] ?? "info",
                         timestampMillis: time(p["timestamp"], now: now),
                         message: args.map(argText).joined(separator: " "))
        case "Runtime.exceptionThrown":
            let d = p["exceptionDetails"] as? [String: Any] ?? [:]
            let description = (d["exception"] as? [String: Any])?["description"] as? String
            return Event(category: "exception", level: "error", timestampMillis: time(p["timestamp"], now: now),
                         message: description ?? d["text"] as? String ?? "")
        case "Log.entryAdded":
            let e = p["entry"] as? [String: Any] ?? [:]
            return Event(category: "log:\(e["source"] as? String ?? "other")",
                         level: levels[e["level"] as? String ?? ""] ?? "info",
                         timestampMillis: time(e["timestamp"], now: now), message: e["text"] as? String ?? "")
        default:
            return nil
        }
    }

    /// A console argument as the console prints it: a value (objects as
    /// JSON), else its description ("f()", "Object"), else its type.
    static func argText(_ a: [String: Any]) -> String {
        if let value = a["value"] {
            switch value {
            case let s as String: return s
            case is NSNull: return "null"
            case let n as NSNumber:
                return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            default:
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
        }
        return a["description"] as? String ?? a["type"] as? String ?? ""
    }

    /// CDP's timestamp (milliseconds since 1970) when it's plausible.
    // ponytail: a TV clock more than a day off (unset, 1970) falls back to
    // Beaver's; an offset correction would need a reference event.
    static func time(_ raw: Any?, now: UInt64) -> UInt64 {
        guard let t = (raw as? NSNumber)?.doubleValue, t.isFinite, abs(t - Double(now)) < 86_400_000 else { return now }
        return UInt64(t)
    }

    /// A Beaver frame, the way the script sends it: fields as a JSON string
    /// in `event` (PROTOCOL.md §4.1, §4.6).
    static func frame(_ type: String, _ fields: [String: Any]) -> String {
        func json(_ o: Any) -> String {
            // Strings and numbers only: serialization can't fail.
            String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data(),
                   as: UTF8.self)
        }
        return json(["id": UUID().uuidString, "type": type, "event": json(fields)])
    }
}

/// One TV, read until Beaver closes its connection (the Disconnect button,
/// `devices_disconnect`). Its tasks keep it alive while it runs.
public actor TVBridge {
    /// `host:port`, as the script takes it; `cdp-<target>` is the device id
    /// both bridges register, so Beaver follows the TV across them.
    public nonisolated let target: String
    public nonisolated var deviceId: String { "cdp-\(target)" }

    private nonisolated let base: URL
    private let name: String?
    private let beaver: URL
    private let retryDelay: Duration
    private let pingInterval: Duration
    /// How long the TV may take to answer: `/json/list`, `Runtime.enable`, a ping.
    private let timeout: Duration
    private let http = URLSession.shared
    private var relay: URLSessionWebSocketTask?
    private var cdp: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var lastStatus: String?
    /// The page socket the ping gave up on: its end is "stopped answering".
    private var stalled: URLSessionWebSocketTask?
    /// The newest TV time sent per page (its debugger URL). `Runtime.enable`
    /// and `Log.enable` replay what the page kept, so a reattach to the same
    /// page drops lines at or before it.
    private var newest: [URL: UInt64] = [:]
    public private(set) var isRunning = false

    /// A host is lowercased, so "TV.local" and "tv.local" are one device id.
    // ponytail: a hostname and its IP are still two ids; resolving the name
    // here would block, and the script registers what it was typed too.
    public init(host: String, port: Int, name: String? = nil,
                beaver: URL = URL(string: "ws://127.0.0.1:9080")!, retryDelay: Duration = .seconds(3),
                ping: Duration = .seconds(10), timeout: Duration = .seconds(5)) throws {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard !host.isEmpty, (1...65_535).contains(port), !host.contains(where: { " /?#@".contains($0) }),
              let base = URL(string: "http://\(bracketed):\(port)"), base.host != nil
        else { throw TVBridgeError.badAddress(port > 0 ? "\(host):\(port)" : host) }
        self.target = "\(bracketed):\(port)"
        self.base = base
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.beaver = beaver
        self.retryDelay = retryDelay
        self.pingInterval = ping
        self.timeout = timeout
    }

    /// Finds the app's page, attaches to it (the TV answered
    /// `Runtime.enable`) and starts streaming it into Beaver. Throws
    /// `TVBridgeError` when the TV can't be read, `CancellationError` when
    /// cancelled; then nothing reached Beaver.
    public func start() async throws {
        guard !isRunning else { return }
        let page = try await discover()
        let (ws, early) = try await open(page)
        let relay = http.webSocketTask(with: beaver)
        relay.resume()
        do {
            try await relay.send(.string(registerFrame(page)))
        } catch {
            relay.cancel()
            ws.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw TVBridgeError.beaverUnavailable(reason: "Beaver's WebSocket server didn't take the connection "
                + "(\(error.localizedDescription))")
        }
        self.relay = relay
        isRunning = true
        Task { await watch(relay) }
        loop = Task { await run(page, ws, early) }
    }

    /// `start()`, then waits up to `wait` for `session` to find the TV in
    /// Beaver. Whatever goes wrong after the start — an error, a cancel, no
    /// session in time — stops the bridge again, so a cancelled Connect
    /// leaves no TV behind.
    public func connect(wait: Duration = .seconds(5), session: @Sendable () async throws -> Int64?) async throws -> Int64 {
        try await start()
        do {
            let deadline = ContinuousClock.now.advanced(by: wait)
            while ContinuousClock.now < deadline {
                if let id = try await session() { return id }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TVBridgeError.beaverUnavailable(reason: "Beaver opened no session for it in \(wait.components.seconds) s")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops reading the TV; Beaver ends its session.
    public func stop() {
        loop?.cancel()
        loop = nil
        cdp?.cancel()
        relay?.cancel(with: .normalClosure, reason: nil)
        relay = nil
        isRunning = false
    }

    // MARK: - Beaver's side

    /// Beaver sends a `register` client only its greeting; the socket
    /// closing is Disconnect, and the bridge stops with it.
    private func watch(_ relay: URLSessionWebSocketTask) async {
        while (try? await relay.receive()) != nil {}
        if self.relay === relay { stop() }
    }

    private func registerFrame(_ page: CDP.Page) -> String {
        let shown = name ?? (page.title.isEmpty ? target : "\(page.title) @ \(target)")
        return CDP.frame("register", ["deviceId": deviceId, "appName": shown, "deviceName": shown, "platform": CDP.platform])
    }

    private func send(_ e: CDP.Event) async {
        let frame = CDP.frame("event", ["category": e.category, "subsystem": "tv-cdp", "level": e.level,
                                        "timestamp": e.timestampMillis, "message": e.message])
        try? await relay?.send(.string(frame))
    }

    /// The bridge's own news, once per change: the script printed it.
    private func status(_ message: String, level: String) async {
        guard message != lastStatus else { return }
        lastStatus = message
        await send(CDP.Event(category: "bridge", level: level, timestampMillis: Self.now(), message: message))
    }

    // MARK: - The TV's side

    private func run(_ first: CDP.Page, _ firstSocket: URLSessionWebSocketTask, _ firstLines: [CDP.Event]) async {
        var page = first, ws = firstSocket, early = firstLines
        var attached = "Attached to \"\(page.title)\""
        while !Task.isCancelled {
            await status(attached, level: "info")
            let ended = await stream(ws, page: page, early: early)
            guard !Task.isCancelled else { return }
            await status(ended, level: "warning")
            let lastSocket = page.socket
            while true {
                try? await Task.sleep(for: retryDelay)
                guard !Task.isCancelled else { return }
                do {
                    page = try await discover()
                    (ws, early) = try await open(page)
                    break
                } catch {
                    guard !Task.isCancelled else { return }
                    await status("\(error.localizedDescription) Retrying every \(retryDelay.components.seconds) s.",
                                 level: "warning")
                }
            }
            attached = page.socket == lastSocket
                ? "Reattached to \"\(page.title)\"; lines it already sent are skipped"
                : "Attached to \"\(page.title)\""
            try? await relay?.send(.string(registerFrame(page)))
        }
    }

    /// Opens a page and enables its domains; returns once the TV answered
    /// `Runtime.enable`, with the lines it sent meanwhile (the replay).
    private func open(_ page: CDP.Page) async throws -> (URLSessionWebSocketTask, [CDP.Event]) {
        guard let url = page.socket else { throw TVBridgeError.pageBusy }
        let ws = http.webSocketTask(with: url)
        ws.maximumMessageSize = 64 << 20
        ws.resume()
        let started = ContinuousClock.now
        let watchdog = Task { [timeout] in
            try await Task.sleep(for: timeout)
            ws.cancel()
        }
        defer { watchdog.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await ws.send(.string(#"{"id":1,"method":"Runtime.enable"}"#))
                try await ws.send(.string(#"{"id":2,"method":"Log.enable"}"#))
                var early: [CDP.Event] = []
                while true {
                    let data = Self.data(try await ws.receive())
                    if let reply = CDP.reply(data), reply.id == 1 {
                        if let error = reply.error { throw TVBridgeError.attachFailed(target: target, reason: error) }
                        return (ws, early)
                    }
                    if let e = CDP.event(data, now: Self.now()) { early.append(e) }
                }
            } onCancel: {
                ws.cancel()
            }
        } catch {
            ws.cancel()
            if Task.isCancelled { throw CancellationError() }
            if error is TVBridgeError { throw error }
            let late = started.duration(to: .now) >= timeout
            throw TVBridgeError.attachFailed(target: target, reason: late
                ? "no answer in \(timeout.components.seconds) s" : error.localizedDescription)
        }
    }

    /// Streams one page until it goes; returns why, for the status line.
    private func stream(_ ws: URLSessionWebSocketTask, page: CDP.Page, early: [CDP.Event]) async -> String {
        cdp = ws
        defer { ws.cancel() }
        let pinger = Task { await ping(ws) }
        defer { pinger.cancel() }
        let cutoff = page.socket.flatMap { newest[$0] }
        for e in early { await forward(e, page: page.socket, cutoff: cutoff) }
        do {
            while !Task.isCancelled {
                let data = Self.data(try await ws.receive())
                if let e = CDP.event(data, now: Self.now()) { await forward(e, page: page.socket, cutoff: cutoff) }
            }
        } catch {
            if stalled === ws { return "The TV stopped answering (asleep, or off the network?) — reconnecting" }
            if ws.closeCode != .invalid { return "The TV closed the app's page — reconnecting" }
            return "Lost the connection to the TV's page (\(error.localizedDescription)) — reconnecting"
        }
        return ""
    }

    /// A TV that sleeps or leaves the network sends nothing, not even a
    /// close: a ping every `pingInterval` with no pong in `timeout` ends the
    /// page's socket, and `run` finds the TV again.
    private func ping(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pingInterval)
            guard !Task.isCancelled else { return }
            let answered = await Self.pong(ws, within: timeout)
            guard !Task.isCancelled else { return }
            if !answered {
                stalled = ws
                ws.cancel()
                return
            }
        }
    }

    private static func pong(_ ws: URLSessionWebSocketTask, within timeout: Duration) async -> Bool {
        let waiting = Mutex<CheckedContinuation<Bool, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let answer: @Sendable (Bool) -> Void = { ok in waiting.withLock { $0.take() }?.resume(returning: ok) }
            ws.sendPing { answer($0 == nil) }
            Task {
                try? await Task.sleep(for: timeout)
                answer(false)
            }
        }
    }

    /// Sends a TV line, unless the page replays it on a reattach.
    private func forward(_ e: CDP.Event, page: URL?, cutoff: UInt64?) async {
        if e.category != "bridge", let page {
            if let cutoff, e.timestampMillis <= cutoff { return }
            newest[page] = max(newest[page] ?? 0, e.timestampMillis)
        }
        await send(e)
    }

    private func discover() async throws -> CDP.Page {
        for path in ["json/list", "json"] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let data: Data, response: URLResponse
            do {
                (data, response) = try await http.data(for: request)
            } catch {
                throw CDP.discoveryError(error, target: target)
            }
            if (response as? HTTPURLResponse)?.statusCode == 200, let pages = CDP.pages(data) {
                return try CDP.pick(pages)
            }
        }
        throw TVBridgeError.noDevTools(target: target)
    }

    private static func data(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }

    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}

/// One Connect per TV at a time (D94): a second Connect for a TV that is
/// still connecting waits for the first one's result instead of starting a
/// second bridge.
@MainActor public final class TVConnects {
    private var running: [String: Task<Int64, any Error>] = [:]

    public init() {}

    public func run(_ deviceId: String, _ connect: @escaping @MainActor () async throws -> Int64) async throws -> Int64 {
        if let first = running[deviceId] { return try await first.value }
        let task = Task { try await connect() }
        running[deviceId] = task
        defer { running[deviceId] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
