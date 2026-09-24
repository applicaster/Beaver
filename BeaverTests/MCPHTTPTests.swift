import Testing
import Foundation
@testable import BeaverCore

@Suite("MCP HTTP parsing and routing")
struct MCPHTTPTests {

    private func raw(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    @Test("A complete POST")
    func complete() {
        let data = raw("POST /mcp HTTP/1.1\nHost: x\nContent-Length: 2\nUser-Agent: claude-code/2\n\n{}")
        guard case .complete(let req) = HTTPRequest.parse(data) else { Issue.record("not complete"); return }
        #expect(req.method == "POST")
        #expect(req.path == "/mcp")
        #expect(req.headers["user-agent"] == "claude-code/2")
        #expect(req.body == Data("{}".utf8))
    }

    @Test("Waits for the rest of the headers and body")
    func incomplete() {
        #expect(HTTPRequest.parse(raw("POST /mcp HTTP/1.1\nContent-Length: 5\n")) == .incomplete)
        #expect(HTTPRequest.parse(raw("POST /mcp HTTP/1.1\nContent-Length: 5\n\n{}")) == .incomplete)
    }

    @Test("Rejects what it can't serve", arguments: [
        ("POST /mcp HTTP/1.1\nTransfer-Encoding: chunked\n\n", 411),
        ("POST /mcp HTTP/1.1\nContent-Length: 99999999\n\n", 413),
        ("POST /mcp HTTP/1.1\nContent-Length: -3\n\n", 400),
        ("GARBAGE\n\n", 400),
    ])
    func invalid(request: String, status: Int) {
        guard case .invalid(let got, _) = HTTPRequest.parse(raw(request)) else { Issue.record("not invalid"); return }
        #expect(got == status)
    }

    @Test("Oversized headers without an end are rejected")
    func hugeHeader() {
        let data = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000)).utf8)
        guard case .invalid(let status, _) = HTTPRequest.parse(data) else { Issue.record("not invalid"); return }
        #expect(status == 431)
    }

    @Test("Origins", arguments: [
        (nil as String?, true), ("null", false), ("http://localhost:3000", true),
        ("http://127.0.0.1", true), ("http://[::1]:8080", true),
        ("https://evil.example", false), ("http://localhost.evil.example", false),
    ])
    func origins(origin: String?, allowed: Bool) {
        #expect(MCPHTTP.originAllowed(origin) == allowed)
    }

    private let echo: MCPHTTP.Handler = { body, _ in body.isEmpty ? nil : body }

    private func request(_ method: String, _ path: String = "/mcp", body: String = "", headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test("Routes")
    func routes() async {
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["content-type": "application/json"]), handler: echo).status == 200)
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["content-type": "application/json"]), handler: echo).headers["Content-Type"] == "application/json")
        #expect(await MCPHTTP.route(request("POST"), handler: echo).status == 202)
        #expect(await MCPHTTP.route(request("GET"), handler: echo).status == 405)
        #expect(await MCPHTTP.route(request("POST", "/other", body: "{}", headers: ["content-type": "application/json"]), handler: echo).status == 404)
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["origin": "https://evil.example", "content-type": "application/json"]), handler: echo).status == 403)
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["origin": "null", "content-type": "application/json"]), handler: echo).status == 403)
        #expect(await MCPHTTP.route(request("POST", "/mcp?x=1", body: "{}", headers: ["content-type": "application/json"]), handler: echo).status == 200)
    }

    @Test("A POST body must be application/json (media type only, params ignored, case-insensitive)")
    func contentType() async {
        #expect(await MCPHTTP.route(request("POST", body: "hi", headers: ["content-type": "text/plain"]), handler: echo).status == 415)
        #expect(await MCPHTTP.route(request("POST", body: "{}"), handler: echo).status == 415)
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["content-type": "application/json; charset=utf-8"]), handler: echo).status == 200)
        #expect(await MCPHTTP.route(request("POST", body: "{}", headers: ["content-type": "APPLICATION/JSON"]), handler: echo).status == 200)
        // A notification/response body (nil reply) is empty, so no Content-Type is required to send it.
        #expect(await MCPHTTP.route(request("POST"), handler: echo).status == 202)
    }

    @Test("Serialized response")
    func serialized() {
        let text = String(decoding: HTTPResponse(status: 202, headers: [:], body: Data()).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
}
