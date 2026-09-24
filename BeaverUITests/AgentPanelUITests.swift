import XCTest

/// The Agent panel end to end: the toolbar keeps its buttons, the Agent
/// button opens the inspector, and Hide reads / Copy / Clear are there.
/// Needs at least one journal row in the store (any MCP call made while
/// Beaver was running leaves one); skips otherwise. Screenshots are kept
/// in the test result for a visual check.
final class AgentPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentPanelOpensAndListsActivity() throws {
        let app = XCUIApplication()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Regression: `.inspector` on the split view once hid every toolbar item.
        let importButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Import'")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Toolbar buttons are missing")

        let agentButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Agent'")).firstMatch
        XCTAssertTrue(agentButton.exists, "Agent toolbar button is missing")
        attach("toolbar")

        agentButton.click()

        let title = app.staticTexts["Agent activity"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Agent panel did not open")
        attach("agent-panel")

        let empty = app.staticTexts["No agent activity"]
        try XCTSkipIf(empty.exists, "Journal is empty — make one MCP call and rerun")

        let hideReads = app.checkBoxes["Hide reads"]
        XCTAssertTrue(hideReads.exists, "Hide reads toggle is missing")
        XCTAssertTrue(app.buttons["Copy"].exists, "Copy button is missing")
        XCTAssertTrue(app.buttons["Clear"].exists, "Clear button is missing")

        hideReads.click()
        attach("hide-reads")
        hideReads.click()

        // Closing the panel keeps the toolbar intact.
        agentButton.click()
        XCTAssertTrue(importButton.exists)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIApplication().windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
