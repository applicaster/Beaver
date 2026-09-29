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

/// Why a TV can't be read. The texts are what the Connect a TV sheet shows.
public enum TVBridgeError: Error, Equatable, LocalizedError {
    case badAddress(String)
    case unreachable(target: String, reason: String)
    case noDevTools(target: String)
    case noPage
    case pageBusy
    case beaverUnavailable

    public var errorDescription: String? {
        switch self {
        case .badAddress(let text):
            "\"\(text)\" isn't a TV address. Type the TV's IP address, e.g. 192.168.1.40, and its DevTools port."
        case .unreachable(let target, let reason):
            "Can't reach the TV at \(target) (\(reason)). Check its IP address, that it's on, and on this Mac's network."
        case .noDevTools(let target):
            "The TV at \(target) has no DevTools on that port. Check the port (Vizio 9555, Vidaa 9226, "
                + "others usually 9222) and that the TV's developer mode is on."
        case .noPage:
            "The TV has no app open. Launch the app on the TV, then connect again."
        case .pageBusy:
            "The app's page is busy: close any DevTools window on the TV (chrome://inspect), then connect again."
        case .beaverUnavailable:
            "Beaver isn't listening for devices on port 9080 (Settings… shows why), so the TV has nowhere to send its logs."
        }
    }
}

/// The pure part of the bridge: what a TV's DevTools answers mean.
public enum CDP {

    /// One entry of the TV's `/json/list`.
    public struct Page: Equatable, Sendable {
        public var type: String
        public var title: String
        /// Missing while another DevTools client is attached.
        public var socket: URL?
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
                 socket: ($0["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// The app's page: the first free one. A page without a debugger URL
    /// has another DevTools client attached (the TV takes one at a time).
    public static func pick(_ pages: [Page]) throws -> Page {
        let candidates = pages.filter { $0.type == "page" }
        if let free = candidates.first(where: { $0.socket != nil }) { return free }
        throw candidates.isEmpty ? TVBridgeError.noPage : TVBridgeError.pageBusy
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
    private let http = URLSession.shared
    private var relay: URLSessionWebSocketTask?
    private var cdp: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var lastStatus: String?
    public private(set) var isRunning = false

    public init(host: String, port: Int, name: String? = nil,
                beaver: URL = URL(string: "ws://127.0.0.1:9080")!, retryDelay: Duration = .seconds(3)) throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard !host.isEmpty, (1...65_535).contains(port), !host.contains(where: { " /?#@".contains($0) }),
              let base = URL(string: "http://\(bracketed):\(port)"), base.host != nil
        else { throw TVBridgeError.badAddress(port > 0 ? "\(host):\(port)" : host) }
        self.target = "\(bracketed):\(port)"
        self.base = base
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.beaver = beaver
        self.retryDelay = retryDelay
    }

    /// Finds the app's page and starts streaming it into Beaver. Throws
    /// `TVBridgeError` when the TV can't be read; then nothing reached Beaver.
    public func start() async throws {
        guard !isRunning else { return }
        let page = try await discover()
        let relay = http.webSocketTask(with: beaver)
        relay.resume()
        self.relay = relay
        do {
            try await relay.send(.string(registerFrame(page)))
        } catch {
            relay.cancel()
            self.relay = nil
            throw TVBridgeError.beaverUnavailable
        }
        isRunning = true
        Task { await watch(relay) }
        loop = Task { await run(page) }
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
        return CDP.frame("register", ["deviceId": deviceId, "appName": shown, "deviceName": shown, "platform": "tv-cdp"])
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

    private func run(_ first: CDP.Page) async {
        var page = first
        while !Task.isCancelled {
            await attach(page)
            guard !Task.isCancelled else { return }
            await status("The TV closed the app's page — reconnecting", level: "warning")
            while true {
                try? await Task.sleep(for: retryDelay)
                guard !Task.isCancelled else { return }
                do {
                    page = try await discover()
                    break
                } catch {
                    await status("\(error.localizedDescription) Retrying every \(retryDelay.components.seconds) s.",
                                 level: "warning")
                }
            }
            try? await relay?.send(.string(registerFrame(page)))
        }
    }

    /// Streams one page until it closes.
    private func attach(_ page: CDP.Page) async {
        guard let url = page.socket else { return }
        let ws = http.webSocketTask(with: url)
        ws.maximumMessageSize = 64 << 20
        cdp = ws
        ws.resume()
        defer { ws.cancel() }
        do {
            try await ws.send(.string(#"{"id":1,"method":"Runtime.enable"}"#))
            try await ws.send(.string(#"{"id":2,"method":"Log.enable"}"#))
            await status("Attached to \"\(page.title)\"", level: "info")
            while !Task.isCancelled {
                let data: Data = switch try await ws.receive() {
                case .string(let s): Data(s.utf8)
                case .data(let d): d
                @unknown default: Data()
                }
                if let e = CDP.event(data, now: Self.now()) { await send(e) }
            }
        } catch {}
    }

    private func discover() async throws -> CDP.Page {
        for path in ["json/list", "json"] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let data: Data, response: URLResponse
            do {
                (data, response) = try await http.data(for: request)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                throw TVBridgeError.noDevTools(target: target)
            } catch let error as URLError where error.code == .notConnectedToInternet {
                throw TVBridgeError.unreachable(target: target, reason: "no network — does Beaver have Local Network "
                    + "access? System Settings → Privacy & Security → Local Network")
            } catch {
                throw TVBridgeError.unreachable(target: target, reason: error.localizedDescription)
            }
            if (response as? HTTPURLResponse)?.statusCode == 200, let pages = CDP.pages(data) {
                return try CDP.pick(pages)
            }
        }
        throw TVBridgeError.noDevTools(target: target)
    }

    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
