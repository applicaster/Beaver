import Testing
import Foundation
@testable import BeaverCore

@Suite("Window state")
struct UIStateTests {

    @Test("A change sets only what it names")
    func partial() {
        var s = UIState()
        s.sessionId = 1
        s.storageSearch = "token"
        var post = NetworkFilter()
        post.method = "POST"
        let t = s.applying(UIChange(tab: .network, networkFilter: post))
        #expect(t.tab == .network)
        #expect(t.networkFilter == post)
        #expect(t.storageSearch == "token")
        #expect(t.sessionId == 1)
    }

    @Test("Another session starts fresh, as a switch in the window does")
    func sessionSwitch() {
        var s = UIState()
        s.tab = .storages
        s.sessionId = 1
        s.logFilter = Filter(minLevel: .error, hiddenThroughEventId: 40)
        s.networkFilter.status = .errors
        s.storageLayer = .keychain
        s.storageSearch = "x"
        s.selectedEventId = 41
        s.selectedNetworkId = 7

        let t = s.applying(UIChange(sessionId: 2))
        #expect(t.sessionId == 2)
        #expect(t.tab == .storages)
        #expect(t.logFilter == Filter(minLevel: .error))   // carried over, Clear dropped (D42)
        #expect(t.networkFilter == NetworkFilter())
        #expect(t.storageLayer == .session)
        #expect(t.storageSearch == "")
        #expect(t.selectedEventId == nil)
        #expect(t.selectedNetworkId == nil)

        // The same session resets nothing, and the change's own fields win.
        #expect(s.applying(UIChange(sessionId: 1)) == s)
        let u = s.applying(UIChange(sessionId: 2, logFilter: Filter.none, selectedEventId: 99))
        #expect(u.selectedEventId == 99)
        #expect(u.logFilter == .none)
    }

    @Test("The snapshot's viewed session is the window's session")
    func snapshotAlias() {
        var host = HostSnapshot(viewingSessionId: 3)
        #expect(host.ui.sessionId == 3)
        host.ui.sessionId = 4
        #expect(host.viewingSessionId == 4)
    }

    @Test("The fake UI applies changes like the app and records them")
    func fake() async {
        let fake = FakeUI(value: HostSnapshot(viewingSessionId: 3))
        await fake.show(UIChange(tab: .network, reveal: true))
        let value = fake.value
        #expect(value.ui.tab == .network)
        #expect(value.viewingSessionId == 3)
        #expect(fake.changes == [UIChange(tab: .network, reveal: true)])
    }
}
