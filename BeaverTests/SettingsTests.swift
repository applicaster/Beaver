import Testing
import Foundation
@testable import BeaverCore

/// The checks behind the Settings window (D92).
@Suite("Settings (D92)")
struct SettingsTests {

    @Test("Agents → Port: only usable ports")
    func port() {
        #expect(AgentAccess.portProblem(9082) == nil)
        #expect(AgentAccess.portProblem(65_535) == nil)
        #expect(AgentAccess.portProblem(80) != nil)
        #expect(AgentAccess.portProblem(70_000) != nil)
        #expect(AgentAccess.portProblem(9080) != nil)
    }
}
