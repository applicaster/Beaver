import Testing
@testable import BeaverCore

@Suite("CommandHints")
struct CommandHintsTests {

    private func event(subsystem: String, category: String = "", message: String) -> DecodedEvent {
        DecodedEvent(timestampMillis: 1, level: .info, subsystem: subsystem,
                     category: category, message: message, dataJSON: nil, contextJSON: nil)
    }

    private let reply = "Registered commands:\ncmdlist\n storage.local.set \n\nstorage.secure.delete\n"

    @Test
    func readsTheGeneralHandlerReply() {
        let names = CommandHints.cmdListNames(in: event(
            subsystem: "DebugFeatures/ConsoleCommands/GeneralHandler", message: reply))
        #expect(names == ["cmdlist", "storage.local.set", "storage.secure.delete"])
    }

    /// Seen from a CatholicTV build: same text, logged as subsystem
    /// `ApplicasterSDK`, category `ConsoleCommands` — and ignored until now.
    @Test
    func readsTheReplyLoggedUnderTheConsoleCommandsCategory() {
        let names = CommandHints.cmdListNames(in: event(
            subsystem: "ApplicasterSDK", category: "ConsoleCommands", message: reply))
        #expect(names?.count == 3)
        #expect(CommandHints.cmdListNames(in: event(subsystem: "ConsoleCommands", message: reply))?.count == 3)
    }

    @Test
    func ignoresOtherEvents() {
        #expect(CommandHints.cmdListNames(in: event(subsystem: "player", message: reply)) == nil)
        #expect(CommandHints.cmdListNames(in: event(
            subsystem: "DebugFeatures/ConsoleCommands/GeneralHandler", message: "Set: k v")) == nil)
    }
}
