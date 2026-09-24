import AppKit
import XCTest

/// M12 end to end: an agent's `ui_show` changes the window without taking
/// focus; only `reveal: true` brings Beaver forward. Which app is in front
/// comes from NSWorkspace — no Accessibility grant, no synthetic input
/// toward Beaver.
final class AgentFocusUITests: XCTestCase {
    /// Its own port, so a Beaver left running on 9081 can't answer.
    private let port = 19_581
    private let beaver = "com.applicaster.LoggerNext"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUIShowStaysInBackgroundUntilReveal() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mcpPort", "\(port)", "-agentAccessEnabled", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let serverUp = await eventually(timeout: .seconds(10)) {
            (try? await self.post(["jsonrpc": "2.0", "id": 0, "method": "ping"])) != nil
        }
        XCTAssertTrue(serverUp, "MCP server didn't answer on \(port)")

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        let finderInFront = await eventually { self.frontmost != self.beaver }
        XCTAssertTrue(finderInFront, "Finder didn't come forward")

        try await call("ui_show", ["tab": "network"])
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotEqual(frontmost, beaver, "ui_show without reveal took focus")

        try await call("ui_show", ["tab": "logs", "reveal": true])
        let beaverInFront = await eventually { self.frontmost == self.beaver }
        XCTAssertTrue(beaverInFront, "ui_show(reveal: true) didn't bring Beaver forward")
    }

    private var frontmost: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    @MainActor
    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    @MainActor
    private func call(_ tool: String, _ arguments: [String: Any]) async throws {
        let reply = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                    "params": ["name": tool, "arguments": arguments]])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "no result: \(reply)")
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) failed: \(result)")
    }

    @MainActor
    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
