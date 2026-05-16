//
//  StorageSnapshot.swift
//  LoggerNext
//

import Foundation

/// A snapshot of one of the client's storage namespaces, sent in response
/// to the `storage.list` command. See `PROTOCOL.md §4.2`.
public struct StorageSnapshot: Identifiable, Hashable, Sendable {
    public enum Namespace: String, Sendable, CaseIterable, Codable {
        case session
        case local
        case keychain      // "secure" on the wire; renamed for the UI

        /// Wire-side key for this namespace.
        public var wireKey: String {
            switch self {
            case .session:  "session"
            case .local:    "local"
            case .keychain: "secure"
            }
        }

        public var displayName: String {
            switch self {
            case .session:  "Session"
            case .local:    "Local"
            case .keychain: "Keychain"
            }
        }
    }

    public let id: Int64
    public let sessionId: Int64
    public let takenAt: Date
    public let namespace: Namespace

    /// Raw JSON of the namespace's contents. Walked by `StoragesViewModel`
    /// into a tree for display, kept as opaque text in storage so we
    /// don't need a schema for arbitrary nested values.
    public let dataJSON: String

    public init(
        id: Int64,
        sessionId: Int64,
        takenAt: Date,
        namespace: Namespace,
        dataJSON: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.takenAt = takenAt
        self.namespace = namespace
        self.dataJSON = dataJSON
    }
}
