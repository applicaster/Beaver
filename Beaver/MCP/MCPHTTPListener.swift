//
//  MCPHTTPListener.swift
//  Beaver
//
//  The smallest HTTP/1.1 an MCP client needs (design §4): one POST per
//  connection, Content-Length bodies, the reply, close.

import Foundation
import Network
import os

public struct HTTPRequest: Sendable, Equatable {
    public enum Parse: Sendable, Equatable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int, reason: String)
    }

    public static let maxBody = 4 * 1024 * 1024
    public static let maxHeader = 32 * 1024

    public let method: String
    public let path: String
    /// Names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }

    /// `buffer` must start at index 0 (the listener accumulates into a fresh `Data`).
    public static func parse(_ buffer: Data) -> Parse {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeader ? .invalid(status: 431, reason: "Headers too large.") : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "Headers are not UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else {
            return .invalid(status: 400, reason: "Bad request line.")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411, reason: "Send a Content-Length body; chunked bodies are not supported.")
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .invalid(status: 400, reason: "Bad Content-Length.")
        }
        guard length <= maxBody else { return .invalid(status: 413, reason: "Body over 4 MB.") }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    public func serialized() -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static let reasons = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large",
        431: "Request Header Fields Too Large",
    ]
}

public enum MCPHTTP {
    public typealias Handler = @Sendable (_ body: Data, _ headers: [String: String]) async -> Data?

    public static func route(_ request: HTTPRequest, handler: Handler) async -> HTTPResponse {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/" else {
            return .text(404, "Not found. The MCP endpoint is /mcp.")
        }
        // DNS-rebinding defense the MCP spec asks for (design §4).
        guard originAllowed(request.headers["origin"]) else {
            return .text(403, "Origin not allowed.")
        }
        guard request.method == "POST" else {
            var r = HTTPResponse.text(405, "Use POST with one JSON-RPC message.")
            r.headers["Allow"] = "POST"
            return r
        }
        guard let reply = await handler(request.body, request.headers) else {
            return HTTPResponse(status: 202, headers: [:], body: Data())
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: reply)
    }

    public static func originAllowed(_ origin: String?) -> Bool {
        guard let origin, origin != "null" else { return true }
        guard let host = URL(string: origin)?.host() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// Loopback HTTP listener for the MCP endpoint (design M2, M3).
public actor MCPHTTPListener {
    private let handler: MCPHTTP.Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.applicaster.LoggerNext.MCP")

    public init(handler: @escaping MCPHTTP.Handler) {
        self.handler = handler
    }

    /// Binds 127.0.0.1:`port` (0 = any free port) and returns the bound
    /// port once listening. Throws if the port is taken.
    public func start(port: UInt16) async throws -> UInt16 {
        stop()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Off on purpose: with reuse, a second Beaver could bind the same
        // port and the two would split the requests.
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let listener = try NWListener(using: parameters)
        let handler = self.handler
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            Self.serve(connection, queue: queue, handler: handler)
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let outcome: Result<UInt16, Error>?
                switch state {
                case .ready:
                    outcome = .success(listener.port?.rawValue ?? port)
                case .failed(let error), .waiting(let error):
                    // A taken port can show up as .waiting(EADDRINUSE) rather than .failed.
                    listener.cancel()
                    outcome = .failure(error)
                case .cancelled:
                    outcome = .failure(CancellationError())
                default:
                    outcome = nil
                }
                // Resume exactly once: the first of ready / failed / waiting / cancelled.
                guard let outcome, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        return bound
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - One connection = one request

    private static let readTimeout: DispatchTimeInterval = .seconds(10)

    private nonisolated static func serve(_ connection: NWConnection, queue: DispatchQueue,
                                          handler: @escaping MCPHTTP.Handler) {
        let complete = OSAllocatedUnfairLock(initialState: false)
        connection.start(queue: queue)
        receive(connection, buffer: Data(), handler: handler, complete: complete)
        // Drop a client that never finishes its request. Once it has, the
        // handler may take as long as it needs (logs_wait: up to 60 s).
        queue.asyncAfter(deadline: .now() + readTimeout) {
            if !complete.withLock({ $0 }) { connection.cancel() }
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data,
                                            handler: @escaping MCPHTTP.Handler,
                                            complete: OSAllocatedUnfairLock<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                receive(connection, buffer: buffer, handler: handler, complete: complete)
            case .invalid(let status, let reason):
                complete.withLock { $0 = true }
                send(.text(status, reason), on: connection)
            case .complete(let request):
                complete.withLock { $0 = true }
                Task {
                    let response = await MCPHTTP.route(request, handler: handler)
                    send(response, on: connection)
                }
            }
        }
    }

    private nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
