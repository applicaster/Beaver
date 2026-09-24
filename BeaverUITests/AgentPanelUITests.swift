import XCTest

/// The Agent panel end to end: the toolbar keeps its buttons (an
/// `.inspector` on the split view once hid every one of them) and the
/// Agent button opens its popover.
///
/// macOS 26 doesn't expose SwiftUI toolbar popovers to XCUITest, so the
/// popover's contents (rows, Hide reads, Copy, Clear) can't be queried;
/// the test keeps screenshots of the toolbar and the open popover in the
/// result bundle for a visual check instead.
final class AgentPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToolbarAndAgentPopover() throws {
        let app = XCUIApplication()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let importButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Import'")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Toolbar buttons are missing")

        let agentButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Agent'")).firstMatch
        XCTAssertTrue(agentButton.exists, "Agent toolbar button is missing")
        attach("toolbar")

        agentButton.click()
        sleep(1)
        attach("agent-popover")

        // Closing the popover keeps the toolbar intact.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(importButton.exists)
        XCTAssertTrue(agentButton.exists)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIApplication().windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
