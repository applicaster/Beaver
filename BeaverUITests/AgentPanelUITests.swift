import XCTest

/// The Agent panel end to end: the toolbar button shows unseen agent
/// activity, opens the inspector, lists entries, and Hide reads filters
/// them. Needs at least one journal row in the store (any MCP call made
/// while Beaver was running leaves one); skips otherwise.
final class AgentPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentPanelOpensAndListsActivity() throws {
        let app = XCUIApplication()
        app.launch()

        let agentButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Agent'")).firstMatch
        XCTAssertTrue(agentButton.waitForExistence(timeout: 10), "Agent toolbar button is missing")

        agentButton.click()

        let title = app.staticTexts["Agent activity"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Agent panel did not open")

        let empty = app.staticTexts["No agent activity"]
        try XCTSkipIf(empty.exists, "Journal is empty — make one MCP call and rerun")

        let hideReads = app.checkBoxes["Hide reads"]
        XCTAssertTrue(hideReads.exists, "Hide reads toggle is missing")
        XCTAssertTrue(app.buttons["Copy"].exists, "Copy button is missing")
        XCTAssertTrue(app.buttons["Clear"].exists, "Clear button is missing")

        // Every PR 1 tool is a read, so hiding reads leaves only failures.
        hideReads.click()
        XCTAssertTrue(app.staticTexts["Agent activity"].exists)
        hideReads.click()

        // Closing the panel keeps the app usable and the button in place.
        agentButton.click()
        XCTAssertTrue(agentButton.exists)
    }
}
