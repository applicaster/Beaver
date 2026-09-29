import Testing
import Foundation
import Network
import Synchronization
@testable import BeaverCore

/// D94: Beaver reads a smart TV over the Chrome DevTools Protocol itself.
@Suite("Connect a TV (native CDP bridge, D94)")
struct TVConnectTests {

    private static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - toEvent, ported from zapp-support's scripts/test-tv-bridge.mjs

    @Test("Console, exception and log entries map like tv-bridge.mjs's toEvent")
    func mapsLikeTheScript() throws {
        let now: UInt64 = 1_727_512_345_678
        let log = try #require(CDP.event(method: "Runtime.consoleAPICalled", params: Self.json("""
            {"type": "warning", "args": [{"type": "string", "value": "hi"}, {"type": "object", "value": {"a": 1}},
                                         {"type": "function", "description": "f()"}]}
            """), now: now))
        #expect([log.level, log.category, log.message] == ["warning", "console", #"hi {"a":1} f()"#])
        let exception = CDP.event(method: "Runtime.exceptionThrown", params: Self.json("""
            {"exceptionDetails": {"text": "Uncaught", "exception": {"description": "Error: x"}}}
            """), now: now)
        #expect(exception?.message == "Error: x")
        #expect(exception?.level == "error")
        #expect(exception?.category == "exception")
        let entry = CDP.event(method: "Log.entryAdded", params: Self.json("""
            {"entry": {"source": "network", "level": "verbose", "text": "t", "timestamp": 5}}
            """), now: now)
        #expect(entry?.category == "log:network")
        #expect(entry?.level == "debug")
        #expect(CDP.event(method: "Page.loadEventFired", params: [:], now: now) == nil)
    }

    @Test("Levels, argument texts and a text-only exception")
    func details() throws {
        let now: UInt64 = 1_000_000_000_000
        for (type, level) in [("log", "info"), ("info", "info"), ("warn", "warning"), ("error", "error"),
                              ("assert", "error"), ("debug", "debug"), ("table", "info")] {
            #expect(CDP.event(method: "Runtime.consoleAPICalled", params: ["type": type, "args": []], now: now)?.level == level)
        }
        let args = CDP.event(method: "Runtime.consoleAPICalled", params: Self.json("""
            {"type": "log", "args": [{"type": "number", "value": 3}, {"type": "number", "value": 1.5},
              {"type": "boolean", "value": true}, {"type": "object", "subtype": "null", "value": null},
              {"type": "undefined"}, {"type": "object", "className": "Object", "description": "Object"},
              {"type": "object", "value": ["a/b", 2]}]}
            """), now: now)
        #expect(args?.message == #"3 1.5 true null undefined Object ["a/b",2]"#)
        let text = CDP.event(method: "Runtime.exceptionThrown",
                             params: Self.json(#"{"exceptionDetails": {"text": "Uncaught SyntaxError"}}"#), now: now)
        #expect(text?.message == "Uncaught SyntaxError")
    }

    @Test("The TV's own time is kept when plausible; an unset TV clock falls back to Beaver's")
    func timestamps() {
        let now: UInt64 = 1_727_512_345_678
        let earlier = Double(now) - 2_500.75
        #expect(CDP.event(method: "Runtime.consoleAPICalled", params: ["type": "log", "args": [], "timestamp": earlier],
                          now: now)?.timestampMillis == UInt64(earlier))
        #expect(CDP.event(method: "Runtime.exceptionThrown", params: ["exceptionDetails": [:], "timestamp": earlier],
                          now: now)?.timestampMillis == UInt64(earlier))
        #expect(CDP.event(method: "Log.entryAdded", params: ["entry": ["source": "js", "timestamp": earlier]],
                          now: now)?.timestampMillis == UInt64(earlier))
        // 1970 (an unset clock), seconds instead of milliseconds, nothing at all.
        for raw: Any? in [5.0, Double(now) / 1000, nil] {
            #expect(CDP.event(method: "Runtime.consoleAPICalled", params: ["type": "log", "args": [], "timestamp": raw as Any],
                              now: now)?.timestampMillis == now)
        }
    }

    @Test("A failed CDP command is a bridge warning; a reply is nothing")
    func cdpMessages() {
        let error = CDP.event(Data(#"{"id":2,"error":{"code":-32601,"message":"'Log.enable' wasn't found"}}"#.utf8), now: 7)
        #expect(error == CDP.Event(category: "bridge", level: "warning", timestampMillis: 7,
                                   message: "CDP error: 'Log.enable' wasn't found"))
        #expect(CDP.event(Data(#"{"id":1,"result":{}}"#.utf8), now: 7) == nil)
    }

    @Test("Frames decode in Beaver like the script's: a TV that only sends logs")
    func framesDecode() throws {
        let register = Data(CDP.frame("register", ["deviceId": "cdp-10.0.0.5:9555", "appName": "Zapp @ 10.0.0.5:9555",
                                                    "deviceName": "Zapp @ 10.0.0.5:9555", "platform": "tv-cdp"]).utf8)
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(register) else { Issue.record("register"); return }
        #expect(h == ClientHandshake(deviceId: "cdp-10.0.0.5:9555", deviceName: "Zapp @ 10.0.0.5:9555",
                                     model: "TV (DevTools)", platform: "tv-cdp", appName: "Zapp @ 10.0.0.5:9555", logsOnly: true))
        let event = Data(CDP.frame("event", ["category": "console", "subsystem": "tv-cdp", "level": "warning",
                                             "timestamp": UInt64(1_727_512_345_678), "message": "a/b \"q\""]).utf8)
        guard case .success(.event(let e)) = ProtocolDecoder.decode(event) else { Issue.record("event"); return }
        #expect(e.level == .warning)
        #expect(e.timestampMillis == 1_727_512_345_678)
        #expect(e.message == "a/b \"q\"")
        #expect(e.category == "console")
        #expect(e.subsystem == "tv-cdp")
    }

    // MARK: - Finding the app's page

    @Test("The first free page is the app's; busy and missing pages say what to do")
    func pagePicking() throws {
        let list = Data("""
            [{"type": "service_worker", "title": "sw", "webSocketDebuggerUrl": "ws://tv/sw"},
             {"type": "page", "title": "Busy"},
             {"type": "page", "title": "Zapp App", "webSocketDebuggerUrl": "ws://10.0.0.5:9555/devtools/page/2"}]
            """.utf8)
        let pages = try #require(CDP.pages(list))
        #expect(try CDP.pick(pages) == CDP.Page(type: "page", title: "Zapp App",
                                                 socket: URL(string: "ws://10.0.0.5:9555/devtools/page/2")))
        #expect(throws: TVBridgeError.pageBusy) { try CDP.pick(Array(pages.prefix(2))) }
        #expect(throws: TVBridgeError.noPage) { try CDP.pick(Array(pages.prefix(1))) }
        #expect(throws: TVBridgeError.noPage) { try CDP.pick([]) }
        #expect(CDP.pages(Data("<html>".utf8)) == nil)
        #expect(CDP.pages(Data(#"{"Browser": "x"}"#.utf8)) == nil)
    }

    @Test("Addresses: the target and device id are host:port, like the script's")
    func addresses() throws {
        let tv = try TVBridge(host: " 192.168.1.40 ", port: 9555)
        #expect(tv.target == "192.168.1.40:9555")
        #expect(tv.deviceId == "cdp-192.168.1.40:9555")
        #expect(try TVBridge(host: "fe80::1", port: 9222).target == "[fe80::1]:9222")
        #expect(throws: TVBridgeError.self) { try TVBridge(host: "", port: 9222) }
        #expect(throws: TVBridgeError.self) { try TVBridge(host: "10.0.0.5", port: 0) }
        #expect(throws: TVBridgeError.self) { try TVBridge(host: "10.0.0.5/json", port: 9222) }
        #expect(throws: TVBridgeError.self) { try TVBridge(host: "my tv", port: 9222) }
    }

    // MARK: - End to end: a fake TV, the bridge, Beaver's WebSocket server

    @Test("Connect: register, the TV's lines, a page reload re-registers, Disconnect stops the bridge")
    func endToEnd() async throws {
        let server = WSServer(port: 19_090)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        let inbound = Inbox()
        let drain = Task { for await item in server.inbound { inbound.add(item) } }
        let tv = try await FakeTV.start()
        defer { drain.cancel(); tv.stop() }

        let bridge = try TVBridge(host: "127.0.0.1", port: Int(tv.httpPort),
                                  beaver: URL(string: "ws://127.0.0.1:19090")!, retryDelay: .milliseconds(100))
        try await bridge.start()
        #expect(await bridge.isRunning)

        // Beaver: a new device that registers as the TV.
        let register = try await inbound.first { $0.handshake != nil }
        let h = try #require(register.handshake)
        #expect(h.deviceId == "cdp-127.0.0.1:\(tv.httpPort)")
        #expect(h.appName == "Zapp App @ 127.0.0.1:\(tv.httpPort)")
        #expect(h.platform == "tv-cdp")
        #expect(h.logsOnly)
        try await until { tv.methods == ["Runtime.enable", "Log.enable"] }

        // The TV's lines arrive as events, with the TV's own time.
        let at = Date().timeIntervalSince1970 * 1000 - 1_000
        tv.push(#"{"method":"Runtime.consoleAPICalled","params":{"type":"error","timestamp":\#(at),"args":[{"type":"string","value":"boom"}]}}"#)
        let boom = try await inbound.first { $0.event?.message == "boom" }
        #expect(boom.event?.level == .error)
        #expect(boom.event?.category == "console")
        #expect(boom.event?.timestampMillis == UInt64(at))
        #expect(inbound.events.contains { $0.category == "bridge" && $0.message.contains("Attached to \"Zapp App\"") })

        // The app reloads: the page goes, the bridge finds it again and re-registers.
        tv.title = "Zapp App 2"
        tv.closePage()
        _ = try await inbound.first { $0.handshake?.appName == "Zapp App 2 @ 127.0.0.1:\(tv.httpPort)" }
        try await until { tv.methods.count == 4 }
        #expect(inbound.events.contains { $0.category == "bridge" && $0.level == .warning })

        // Disconnect in Beaver closes the connection: the bridge stops and lets go of the TV.
        guard case .frame(let connection, _) = register else { Issue.record("no connection"); return }
        await server.disconnect(connection)
        try await until { await !bridge.isRunning }
        try await until { tv.openPages == 0 }
        await server.stop()
    }

    @Test("A TV that can't be read says why, and nothing reaches Beaver")
    func errors() async throws {
        let tv = try await FakeTV.start()
        defer { tv.stop() }
        func start(_ port: Int = 0, beaver: String = "ws://127.0.0.1:19091") async throws {
            try await TVBridge(host: "127.0.0.1", port: port == 0 ? Int(tv.httpPort) : port,
                               beaver: URL(string: beaver)!).start()
        }
        tv.pages = { _ in "[]" }
        await #expect(throws: TVBridgeError.noPage) { try await start() }
        tv.pages = { _ in #"[{"type":"page","title":"Zapp App"}]"# }
        await #expect(throws: TVBridgeError.pageBusy) { try await start() }
        tv.pages = { _ in "Not DevTools" }
        await #expect(throws: TVBridgeError.noDevTools(target: "127.0.0.1:\(tv.httpPort)")) { try await start() }
        // Nothing listens on port 1: the port is wrong.
        await #expect(throws: TVBridgeError.noDevTools(target: "127.0.0.1:1")) { try await start(1) }
        // The TV is fine but Beaver isn't listening.
        tv.pages = FakeTV.onePage
        await #expect(throws: TVBridgeError.beaverUnavailable) { try await start() }
        #expect(tv.openPages == 0)
    }

    // MARK: - MCP

    @Test("devices_connect_tv connects through the app and names the TV; errors say what to check")
    func tool() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.applyHandshake(ClientHandshake(deviceId: "cdp-10.0.0.5:9555", model: "TV (DevTools)",
                                                       platform: "tv-cdp", appName: "Living room", logsOnly: true), to: s.id)
        let device = FakeDevice(onConnectTV: { host, _ in
            guard host == "10.0.0.5" else { throw TVBridgeError.pageBusy }
            return s.id
        })
        let ctx = makeContext(store, device: device)
        let result = try await CommandTools.connectTV.run(
            ToolArguments(["host": " 10.0.0.5 ", "port": "9555", "name": "  "]), ctx)
        #expect(result.summary == "Connected the TV Living room (TV (DevTools), tv-cdp) as device \"\(s.id)\"; it only sends logs.")
        #expect(result.structured["deviceId"] == .string(String(s.id)))
        #expect(result.next.contains { $0.contains("devices_disconnect(deviceId: \"\(s.id)\")") })
        #expect(device.connectedTVs.map(\.host) == ["10.0.0.5"])
        #expect(device.connectedTVs.map(\.port) == [9555])
        #expect(device.connectedTVs.first?.name == nil)

        do {
            _ = try await CommandTools.connectTV.run(ToolArguments(["host": "10.0.0.6"]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("close any DevTools window"))
            #expect(error.message.contains("Example: devices_connect_tv(host: \"10.0.0.6\", port: 9222)"))
        }
        #expect(device.connectedTVs.last?.port == 9222)
        await #expect(throws: ToolError.self) { try await CommandTools.connectTV.run(ToolArguments([:]), ctx) }
        #expect(CommandTools.connectTV.kind == .change)
    }
}

// MARK: - Helpers

private struct Timeout: Error {}

private func until(_ timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Timeout()
}

private extension WSServer.Inbound {
    var decoded: ProtocolDecoder.InboundPacket? {
        guard case .frame(_, let data) = self, case .success(let p) = ProtocolDecoder.decode(data) else { return nil }
        return p
    }
    var handshake: ClientHandshake? { if case .clientHandshake(let h)? = decoded { h } else { nil } }
    var event: DecodedEvent? { if case .event(let e)? = decoded { e } else { nil } }
}

/// What Beaver's server received.
private final class Inbox: Sendable {
    private let items = Mutex<[WSServer.Inbound]>([])
    func add(_ item: WSServer.Inbound) { items.withLock { $0.append(item) } }
    var events: [DecodedEvent] { items.withLock { $0 }.compactMap(\.event) }
    func first(where match: @Sendable (WSServer.Inbound) -> Bool) async throws -> WSServer.Inbound {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let found = items.withLock({ $0.first(where: match) }) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout()
    }
}

/// A TV's DevTools on loopback: `/json/list` over HTTP, and the app's page
/// as a WebSocket that records the methods it's sent.
private final class FakeTV: Sendable {
    static let onePage: @Sendable (UInt16) -> String = { ws in
        #"[{"type":"page","title":"Zapp App","webSocketDebuggerUrl":"ws://127.0.0.1:\#(ws)/devtools/page/1"}]"#
    }

    private struct State {
        var pages: @Sendable (UInt16) -> String = FakeTV.onePage
        var title = "Zapp App"
        var methods: [String] = []
        var page: NWConnection?
        var open = 0
    }
    private let state = Mutex(State())
    private let http: NWListener
    private let ws: NWListener
    private let queue = DispatchQueue(label: "FakeTV")
    let httpPort: UInt16
    let wsPort: UInt16

    var pages: @Sendable (UInt16) -> String {
        get { state.withLock { $0.pages } }
        set { state.withLock { $0.pages = newValue } }
    }
    var title: String {
        get { state.withLock { $0.title } }
        set { state.withLock { $0.title = newValue } }
    }
    var methods: [String] { state.withLock { $0.methods } }
    var openPages: Int { state.withLock { $0.open } }

    private init(http: NWListener, ws: NWListener) {
        self.http = http; self.ws = ws
        httpPort = http.port?.rawValue ?? 0; wsPort = ws.port?.rawValue ?? 0
    }

    static func start() async throws -> FakeTV {
        let http = try NWListener(using: .tcp, on: .any)
        let params = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let ws = try NWListener(using: params, on: .any)
        let queue = DispatchQueue(label: "FakeTV.start")
        for listener in [http, ws] {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let once = Mutex(false)
                listener.newConnectionHandler = { $0.cancel() }
                listener.stateUpdateHandler = { if case .ready = $0, !once.withLock({ let was = $0; $0 = true; return was }) { done.resume() } }
                listener.start(queue: queue)
            }
        }
        let tv = FakeTV(http: http, ws: ws)
        http.newConnectionHandler = { [weak tv] in tv?.serveHTTP($0) }
        ws.newConnectionHandler = { [weak tv] in tv?.servePage($0) }
        return tv
    }

    func stop() {
        http.cancel(); ws.cancel()
        state.withLock { $0.page?.cancel() }
    }

    private func serveHTTP(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
            guard let self else { return }
            let body = state.withLock { s in s.pages(wsPort).replacingOccurrences(of: "Zapp App", with: s.title) }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func servePage(_ c: NWConnection) {
        state.withLock { $0.page = c; $0.open += 1 }
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed: c.cancel()
            case .cancelled: self?.state.withLock { $0.open -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let method = m["method"] as? String {
                state.withLock { $0.methods.append(method) }
            }
            if error == nil, context?.isFinal != true { receive(c) } else { c.cancel() }
        }
    }

    /// A CDP notification from the TV.
    func push(_ text: String) {
        guard let c = state.withLock({ $0.page }) else { return }
        let context = NWConnection.ContentContext(identifier: "cdp", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        c.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// The app reloads: its page's socket closes.
    func closePage() { state.withLock { $0.page }?.cancel() }
}
