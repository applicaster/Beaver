//
//  SessionImport.swift
//  Beaver
//
//  Opens a session file — Beaver's or zapp-support's JSON, or a HAR from
//  anywhere — as a new imported session (D7, SESSION_FILE_FORMAT.md). The
//  Import button and `sessions_import` both come through here.

import Foundation

public enum SessionImport {

    public struct Result: Sendable {
        public let session: Session
        public let events: Int
        public let storageLayers: Int
        public let requests: Int
    }

    /// `nil` when `data` isn't a session file Beaver can open.
    public static func run(_ data: Data, label: String?, store: LogStore) async throws -> Result? {
        var imported = (try? EventJSON.decodeExport(data)) ?? .init()
        // Not a Beaver export: maybe a HAR (Beaver's, Chrome's, Charles'…).
        if imported.events.isEmpty && imported.storage.isEmpty && imported.network.isEmpty {
            imported.network = HARExport.decode(data)
        }
        // A storage-only or network-only file is still worth opening.
        guard !imported.events.isEmpty || !imported.storage.isEmpty || !imported.network.isEmpty else {
            return nil
        }
        // A new "imported" session per D7 — never the live one.
        let session = try await store.createSession(source: .imported, clientLabel: label)
        try await store.appendBulk(imported.events, to: session.id)
        for (namespace, json) in imported.storage {
            try await store.recordStorageSnapshot(sessionId: session.id, namespace: namespace, dataJSON: json)
        }
        for capture in imported.network {
            try await store.recordNetworkEntry(capture, sessionId: session.id)
        }
        return Result(session: session, events: imported.events.count,
                      storageLayers: imported.storage.count, requests: imported.network.count)
    }
}
