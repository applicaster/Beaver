//
//  ClientHandshake.swift
//  Beaver
//
//  D77: the handshake the SDK sends right after the socket opens
//  (PROTOCOL.md §4.4). `deviceId` is stable per installation, so it
//  identifies a device across reconnects.
//  D89: zapp-support's `register` frame (its TV bridge, PROTOCOL.md §4.6)
//  decodes to the same shape with `logsOnly` set.

import Foundation

public struct ClientHandshake: Sendable, Equatable {
    public var deviceId: String?
    public var deviceName: String?
    public var model: String?
    /// `"iOS 18.6"`, `"Android 15"`.
    public var platform: String?
    public var appPackage: String?
    public var version: String?
    /// One per app process, the same on every reconnect of it (D97). Nil
    /// for an SDK that doesn't send one.
    public var launchId: String?
    /// Only `register` carries it; the SDK's handshake leaves the name to applicaster.v2.
    public var appName: String?
    /// A `register` client (D89): it sends logs and nothing else — no
    /// commands, storage or MCP answers.
    public var logsOnly = false

    public init(deviceId: String? = nil, deviceName: String? = nil, model: String? = nil,
                platform: String? = nil, appPackage: String? = nil, version: String? = nil,
                launchId: String? = nil, appName: String? = nil, logsOnly: Bool = false) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.model = model
        self.platform = platform; self.appPackage = appPackage; self.version = version
        self.launchId = launchId; self.appName = appName; self.logsOnly = logsOnly
    }

    /// `"iOS 18.6"` → `("iOS", "18.6")`; `"tvOS"` → `("tvOS", nil)`.
    public var platformParts: (name: String?, version: String?) {
        guard let platform else { return (nil, nil) }
        let parts = platform.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}
