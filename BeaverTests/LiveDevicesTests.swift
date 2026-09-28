import Testing
import Foundation
@testable import BeaverCore

@Suite("Live devices (D73)")
struct LiveDevicesTests {

    @Test("The first device takes the window; a second one doesn't while a live one is viewed")
    func connect() {
        var live = LiveDevices()
        let a = UUID(), b = UUID()
        let first = live.connect(a, session: 1, viewing: nil)
        let second = live.connect(b, session: 2, viewing: 1)
        #expect(first)
        #expect(!second)
        #expect(live.sessionIds == [1, 2])
        #expect(live.isLive(2))
        #expect(live.connection(for: 2) == b)
        #expect(live.session(for: a) == 1)
    }

    @Test("A new device takes the window over a past or imported session")
    func connectOverPast() {
        var live = LiveDevices()
        let takes = live.connect(UUID(), session: 7, viewing: 3)
        #expect(takes)
    }

    @Test("Disconnect forgets the session and its commands")
    func disconnect() {
        var live = LiveDevices()
        let a = UUID()
        _ = live.connect(a, session: 1, viewing: nil)
        live.setCommands([CommandHint(name: "cmdlist", syntax: nil, description: nil)], for: 1)
        let dropped = live.disconnect(a)
        #expect(dropped == 1)
        #expect(!live.isLive(1))
        #expect(live.commands[1] == nil)
        let again = live.disconnect(a)
        #expect(again == nil)
        #expect(!live.isLive(nil))
    }

    @Test("Deleted sessions stop receiving at once; the device gets a fresh one")
    func detachAttach() {
        var live = LiveDevices()
        let a = UUID(), b = UUID()
        _ = live.connect(a, session: 1, viewing: nil)
        _ = live.connect(b, session: 2, viewing: 1)
        let waiting = live.detach { $0 == 1 }
        #expect(waiting == [a])
        #expect(live.session(for: a) == nil)
        #expect(live.session(for: b) == 2)
        let attached = live.attach(a, session: 9)
        #expect(attached)
        #expect(live.session(for: a) == 9)
        #expect(!live.isLive(1))
    }

    @Test("A device that leaves while waiting for a fresh session gets none")
    func detachThenDisconnect() {
        var live = LiveDevices()
        let a = UUID()
        _ = live.connect(a, session: 1, viewing: nil)
        _ = live.detach { _ in true }
        let ended = live.disconnect(a)
        #expect(ended == nil)
        let attached = live.attach(a, session: 9)
        #expect(!attached)
        #expect(live.sessionIds.isEmpty)
    }

    @Test("The device menu: connected first, then the 5 newest other live sessions, no imports")
    func menu() {
        func s(_ id: Int64, _ source: Session.Source = .live) -> Session {
            Session(id: id, startedAt: Date(timeIntervalSince1970: Double(id)), source: source)
        }
        let newestFirst = (1...9).reversed().map { s(Int64($0)) } + [s(0, .imported)]
        let m = DeviceMenu.sections(sessions: newestFirst, live: [9, 4])
        #expect(m.connected.map(\.id) == [9, 4])
        #expect(m.recent.map(\.id) == [8, 7, 6, 5, 3])
    }
}
