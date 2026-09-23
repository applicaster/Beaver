import Testing
import Foundation
@testable import BeaverCore

/// A failed `NWListener` never recovers by itself, and the usual cause —
/// a second copy of the app holding the port — clears the moment that
/// process quits. These cover the server noticing and re-binding without
/// being restarted.
// Serialized: all three bind the same port, and in parallel they block
// each other — a rebind or a "stays stopped" assertion can then pass or
// fail for a reason that has nothing to do with the code under test.
@Suite("WSServer rebind", .serialized)
struct WSServerRebindTests {

    /// Away from 9080 so a running Beaver doesn't take part in the test.
    private static let port: UInt16 = 19_080

    /// Collect states until `predicate` matches, or give up.
    private func waitForState(
        _ server: WSServer,
        timeout: Duration = .seconds(30),
        matching predicate: @escaping @Sendable (WSServer.State) -> Bool
    ) async -> WSServer.State? {
        await race(timeout: timeout) {
            for await state in server.state where predicate(state) {
                return state
            }
            return nil
        } ?? nil
    }

    @Test("A port that is already taken reports failure instead of dying quietly")
    func bindConflictIsReported() async throws {
        let holder = WSServer(port: Self.port)
        try await holder.start()
        let ready = await waitForState(holder) { if case .listening = $0 { return true }; return false }
        #expect(ready != nil, "the first server should bind")

        let blocked = WSServer(port: Self.port)
        try await blocked.start()
        let failure = await waitForState(blocked) { if case .failed = $0 { return true }; return false }

        guard case .failed(let reason)? = failure else {
            Issue.record("expected the second server to report .failed, got \(String(describing: failure))")
            await holder.stop(); await blocked.stop()
            return
        }
        // The message has to say what to do about it, and that the
        // server hasn't given up.
        #expect(reason.contains("Port in use"))
        #expect(reason.contains("retrying"))

        await blocked.stop()
        await holder.stop()
    }

    @Test("The listener comes back on its own once the port frees up")
    func rebindsAfterThePortIsReleased() async throws {
        let holder = WSServer(port: Self.port)
        try await holder.start()
        _ = await waitForState(holder) { if case .listening = $0 { return true }; return false }

        let blocked = WSServer(port: Self.port)
        try await blocked.start()
        _ = await waitForState(blocked) { if case .failed = $0 { return true }; return false }

        // The whole point: nobody restarts anything.
        await holder.stop()

        let recovered = await waitForState(blocked) {
            if case .listening = $0 { return true }
            return false
        }
        #expect(recovered != nil, "the blocked server should re-bind by itself")

        await blocked.stop()
    }

    @Test("Stopping cancels a pending retry")
    func stopWinsOverAPendingRetry() async throws {
        let holder = WSServer(port: Self.port)
        try await holder.start()
        _ = await waitForState(holder) { if case .listening = $0 { return true }; return false }

        let blocked = WSServer(port: Self.port)
        try await blocked.start()
        _ = await waitForState(blocked) { if case .failed = $0 { return true }; return false }

        // Stop while a retry is queued, then free the port. A retry that
        // survived `stop()` would resurrect a server the user switched off.
        await blocked.stop()
        await holder.stop()

        // Backoff is 1s then 2s, so three seconds gives a surviving
        // retry two chances to fire before we check.
        try await Task.sleep(for: .seconds(3))

        let resurrected = WSServer(port: Self.port)
        try await resurrected.start()
        let ready = await waitForState(resurrected) { if case .listening = $0 { return true }; return false }
        #expect(ready != nil, "the port should be free — the stopped server must not have taken it")

        await resurrected.stop()
    }
}
