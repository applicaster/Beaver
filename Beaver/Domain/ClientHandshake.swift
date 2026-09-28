//
//  ClientHandshake.swift
//  Beaver
//
//  D76: the handshake the SDK sends right after the socket opens
//  (PROTOCOL.md §4.4). `deviceId` is stable per installation, so it
//  identifies a device across reconnects.

import Foundation

public struct ClientHandshake: Sendable, Equatable {
    public var deviceId: String?
    public var deviceName: String?
    public var model: String?
    /// `"iOS 18.6"`, `"Android 15"`.
    public var platform: String?
    public var appPackage: String?
    public var version: String?

    public init(deviceId: String? = nil, deviceName: String? = nil, model: String? = nil,
                platform: String? = nil, appPackage: String? = nil, version: String? = nil) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.model = model
        self.platform = platform; self.appPackage = appPackage; self.version = version
    }

    /// `"iOS 18.6"` → `("iOS", "18.6")`; `"tvOS"` → `("tvOS", nil)`.
    public var platformParts: (name: String?, version: String?) {
        guard let platform else { return (nil, nil) }
        let parts = platform.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}
