//
//  CommandRegistry.swift
//  Beaver
//
// ─────────────────────────────────────────────────────────────────────
// TODO (REMOVE WHEN SDK PROTOCOL IS UPGRADED):
//
// This file hard-codes the syntax + description for each command the
// Applicaster iOS SDK exposes via `cmdlist`. It's a temporary scaffold
// because today's SDK only returns command *names* (one per line in
// the `message` field of a log event from subsystem
// `DebugFeatures/ConsoleCommands/GeneralHandler`).
//
// The proper fix is to extend `cmdlist`'s response to include
// {name, syntax, description} per command. See PROTOCOL.md §3.2
// "Open question #3 — Command discovery". Once the SDK responds with
// structured help, delete this file and have CommandHint.merge use
// the SDK's data directly.
// ─────────────────────────────────────────────────────────────────────
//
// Cross-platform note: this mapping is iOS-specific. If a tvOS or
// Android client connects, commands with matching names will likely
// have similar syntax (storage.*, debug.flag.*) but it's not
// guaranteed. Unknown commands fall through and display as bare
// names — see CommandHint.merge.

import Foundation

/// What a known command looks like — syntax template + one-line description.
public struct CommandSpec: Sendable, Hashable {
    public let syntax: String
    public let description: String
}

public enum CommandRegistry {

    /// Map of command name → spec. Lookup is by exact name match.
    /// Keep entries sorted alphabetically to mirror cmdlist output order
    /// for easier diffing as the SDK evolves.
    public static let entries: [String: CommandSpec] = [
        // GeneralHandler — navigation / utility
        "cmdlist": CommandSpec(
            syntax: "cmdlist",
            description: "Print the list of all registered commands"
        ),
        "layout.set": CommandSpec(
            syntax: "layout.set <layoutId>",
            description: "Switch to a different Rivers layout"
        ),
        "open": CommandSpec(
            syntax: "open <url>",
            description: "Open a URL in the app"
        ),
        "storefront.open": CommandSpec(
            syntax: "storefront.open",
            description: "Open the storefront URL scheme"
        ),
        "xray.open": CommandSpec(
            syntax: "xray.open",
            description: "Open the Xray debug screen"
        ),

        // StoragesDebbugerCommandHandler — full snapshot
        "storage.list": CommandSpec(
            syntax: "storage.list",
            description: "Dump full data of all 3 storages (session / local / secure)"
        ),

        // StorageCommandsHandler — per-namespace CRUD
        "storage.local.delete": CommandSpec(
            syntax: "storage.local.delete <key> [namespace]",
            description: "Delete a value from local storage"
        ),
        "storage.local.get": CommandSpec(
            syntax: "storage.local.get <key> [namespace]",
            description: "Read a value from local storage"
        ),
        "storage.local.list": CommandSpec(
            syntax: "storage.local.list [namespace]",
            description: "List all keys in local storage"
        ),
        "storage.local.set": CommandSpec(
            syntax: "storage.local.set <key> <value> [namespace]",
            description: "Write a value to local storage"
        ),
        "storage.secure.delete": CommandSpec(
            syntax: "storage.secure.delete <key> [namespace]",
            description: "Delete a value from keychain"
        ),
        "storage.secure.get": CommandSpec(
            syntax: "storage.secure.get <key> [namespace]",
            description: "Read a value from keychain"
        ),
        "storage.secure.list": CommandSpec(
            syntax: "storage.secure.list [namespace]",
            description: "List all keys in keychain"
        ),
        "storage.secure.set": CommandSpec(
            syntax: "storage.secure.set <key> <value> [namespace]",
            description: "Write a value to keychain"
        ),
        "storage.session.delete": CommandSpec(
            syntax: "storage.session.delete <key> [namespace]",
            description: "Delete a value from session storage"
        ),
        "storage.session.get": CommandSpec(
            syntax: "storage.session.get <key> [namespace]",
            description: "Read a value from session storage"
        ),
        "storage.session.list": CommandSpec(
            syntax: "storage.session.list [namespace]",
            description: "List all keys in session storage"
        ),
        "storage.session.set": CommandSpec(
            syntax: "storage.session.set <key> <value> [namespace]",
            description: "Write a value to session storage"
        ),

        // DebugFeatures — feature-flag toggles
        "debug.flag.list": CommandSpec(
            syntax: "debug.flag.list",
            description: "List all registered feature flags"
        ),
        "debug.flag.off": CommandSpec(
            syntax: "debug.flag.off <flagId>",
            description: "Disable a feature flag"
        ),
        "debug.flag.on": CommandSpec(
            syntax: "debug.flag.on <flagId>",
            description: "Enable a feature flag"
        ),
    ]
}
