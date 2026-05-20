//
//  Session.swift
//  Beaver
//

import Foundation

/// A single client connection's worth of events.
///
/// Per D2 (one client at a time) each accepted connection starts a new
/// session row. Imported JSON files also create sessions, distinguished
/// by `source`.
public struct Session: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, Codable {
        case live
        case imported
    }

    public let id: Int64
    public let startedAt: Date
    public var endedAt: Date?
    public let source: Source
    public var clientLabel: String?     // from handshake response, if any

    /// Device / app fingerprint captured the first time the SDK's
    /// applicaster.v2 storage namespace arrives for this session.
    /// All optional — older rows and imported sessions just leave
    /// them blank. See Schema migration v3_session_device_info.
    public var appName: String?
    public var appVersion: String?
    public var deviceModel: String?
    public var platform: String?
    public var osVersion: String?

    public init(
        id: Int64,
        startedAt: Date,
        endedAt: Date? = nil,
        source: Source,
        clientLabel: String? = nil,
        appName: String? = nil,
        appVersion: String? = nil,
        deviceModel: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.clientLabel = clientLabel
        self.appName = appName
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.platform = platform
        self.osVersion = osVersion
    }

    public var isActive: Bool { endedAt == nil && source == .live }
}
