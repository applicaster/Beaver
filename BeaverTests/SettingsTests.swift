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

    @Test("Zapp → Test: 200 and 404 got past the token, 401 and 403 didn't")
    func tokenVerdict() {
        #expect(ZappTokenCheck(status: 200) == .accepted)
        #expect(ZappTokenCheck(status: 404) == .accepted)
        #expect(ZappTokenCheck(status: 401) == .rejected)
        #expect(ZappTokenCheck(status: 403) == .rejected)
        #expect(ZappTokenCheck(status: 500) == .unknown("Zapp answered 500"))
        // The probe id passes the request's own id check.
        #expect(ZappHTTP.buildParamsRequest(versionId: ZappTokenCheck.probeVersionId, token: "t") != nil)
        #expect(ZappHTTP.buildParamsRequest(versionId: "bad id", token: "t") == nil)
    }
}
