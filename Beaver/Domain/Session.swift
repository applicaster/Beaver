//
//  Session.swift
//  Beaver
//

import Foundation

/// A single client connection's worth of events.
///
/// Each accepted connection starts a new session row; several can be
/// live at once (D73). Imported JSON files also create sessions,
/// distinguished by `source`.
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

    /// From the SDK's client handshake (D77): stable per installation,
    /// so it tells a device apart across reconnects. Nil for SDKs without
    /// a client handshake and for imported sessions.
    public var deviceUID: String?
    /// The app's bundle id / package name, from the same handshake.
    public var appPackage: String?

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
        osVersion: String? = nil,
        deviceUID: String? = nil,
        appPackage: String? = nil
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
        self.deviceUID = deviceUID
        self.appPackage = appPackage
    }

    public var isActive: Bool { endedAt == nil && source == .live }

    /// `River 2.7 · iPhone15,2 · iOS 18.6`, each piece skipped if missing.
    public var contextLine: String {
        var parts: [String] = []
        if let n = appName { parts.append(n + (appVersion.map { " \($0)" } ?? "")) }
        if let d = deviceModel { parts.append(d) }
        if let os = osVersion { parts.append((platform ?? "OS") + " " + os) }
        return parts.joined(separator: " · ")
    }

    /// What Copy device fingerprint puts on the clipboard for a ticket;
    /// the same lines as zapp-support's Copy fingerprint (D79).
    public func fingerprint(capturedAt: Date) -> String {
        [contextLine.isEmpty ? "Unknown device" : contextLine,
         deviceUID.map { "Device id: \($0)" },
         appPackage.map { "Bundle id: \($0)" },
         "Beaver session: #\(id)",
         "Captured: \(capturedAt.ISO8601Format())"]
            .compactMap { $0 }.joined(separator: "\n")
    }
}
