//
//  CommandHint.swift
//  Beaver
//

import Foundation

/// A row in the command-help popover. Combines whatever the SDK
/// returned from `cmdlist` (just a name) with whatever Beaver
/// knows about syntax (from `CommandRegistry`).
public struct CommandHint: Identifiable, Hashable, Sendable {
    public let name: String
    public let syntax: String?       // nil → SDK reported a command we don't have mapping for
    public let description: String?  // ditto

    public var id: String { name }

    /// Group label for display — derived from the command's prefix.
    /// Used to chunk the popover into logical sections.
    public var group: String {
        if name.hasPrefix("storage.") { return "Storage" }
        if name.hasPrefix("debug.")   { return "Debug" }
        if name.hasPrefix("layout.")  { return "Layout" }
        return "General"
    }
}

public enum CommandHints {

    /// Merge the SDK's cmdlist names with the registry to produce
    /// display rows. Names returned by the SDK that don't appear in
    /// the registry fall through as hints with nil syntax — the UI
    /// shows them at the bottom in a separate section.
    public static func merge(sdkNames: [String]) -> [CommandHint] {
        sdkNames.map { name in
            let spec = CommandRegistry.entries[name]
            return CommandHint(
                name: name,
                syntax: spec?.syntax,
                description: spec?.description
            )
        }
    }
}
