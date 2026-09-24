//
//  AgentNotifications.swift
//  Beaver
//
//  macOS notifications for the agent's attention notes (design M28, D68):
//  the rules and texts. The app's AgentNotifier posts them.

import Foundation

public enum AgentNotifications {

    public enum State: String, Sendable, CaseIterable {
        case allowed, denied, notDetermined, muted
    }

    /// Beaver's page in System Settings. Apple renames panes between
    /// releases, so `howToEnable` sits next to it and is always shown.
    public static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.applicaster.LoggerNext")!
    public static let howToEnable = "System Settings → Notifications → Beaver → Allow Notifications (style: Banners)"

    /// At most one notification per window; notes in between are summarised.
    public static let window: TimeInterval = 30

    public static let title = "Beaver — agent"

    public struct Strip: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case askPermission, openSettings }
        public let title: String
        public let detail: String
        public let button: String
        public let action: Action
    }

    /// The strip at the top of the Agent panel, or nil when notifications work (or the user muted them).
    public static func strip(for state: State) -> Strip? {
        switch state {
        case .allowed, .muted:
            nil
        case .notDetermined:
            Strip(title: "Notifications are off — Beaver hasn't asked yet. The agent can't call you while Beaver is in the background.",
                  detail: "Turn on: " + howToEnable, button: "Allow Notifications", action: .askPermission)
        case .denied:
            Strip(title: "Notifications are off — the agent can't call you while Beaver is in the background.",
                  detail: "Turn on: " + howToEnable, button: "Open System Settings", action: .openSettings)
        }
    }

    public static func menuTitle(for state: State) -> String {
        switch state {
        case .allowed: "Agent Notifications: On"
        case .muted: "Agent Notifications: Muted in Beaver"
        case .denied, .notDetermined: "Agent Notifications: Off — Turn On…"
        }
    }

    /// What `journal_note(level: attention)` tells the agent (design §7.2).
    /// `held`: the throttle kept this note for the next summary.
    public static func outcome(state: State, frontmost: Bool, held: Bool) -> NotifyOutcome {
        if frontmost {
            return NotifyOutcome(notified: true, reason: "Beaver is in front: the note shows as a toast in its window.")
        }
        switch state {
        case .allowed:
            return NotifyOutcome(notified: true, reason: held
                ? "Grouped with other notes into one notification (at most one per 30 s)." : nil)
        case .muted:
            return NotifyOutcome(notified: false, reason: "The user muted agent notifications in Beaver's Agent panel.")
        case .denied:
            return NotifyOutcome(notified: false, reason: "Notifications are off for Beaver.", howToEnable: howToEnable)
        case .notDetermined:
            return NotifyOutcome(notified: false,
                                 reason: "Beaver just asked the user to allow notifications; if they allow, this note is delivered. It is in the Agent panel either way.",
                                 howToEnable: howToEnable)
        }
    }

    public static func summary(count: Int) -> String {
        count == 1 ? "1 new finding from the agent" : "\(count) new findings from the agent"
    }
}

public struct NotifyOutcome: Sendable, Equatable {
    public var notified: Bool
    public var reason: String?
    public var howToEnable: String?

    public init(notified: Bool, reason: String? = nil, howToEnable: String? = nil) {
        self.notified = notified; self.reason = reason; self.howToEnable = howToEnable
    }
}

/// What an attention note asks the app to show.
public struct AgentNote: Sendable, Equatable {
    public let text: String
    public let links: [JournalLink]

    public init(text: String, links: [JournalLink]) { self.text = text; self.links = links }
}

/// Design M28: one notification per window; notes in between are held and
/// summarised when the window ends.
public struct NotificationThrottle: Sendable {
    public private(set) var lastSent: Date?
    public private(set) var held = 0

    public init() {}

    /// `true`: post this note now. `false`: it is held for the summary.
    public mutating func admit(at now: Date) -> Bool {
        if let lastSent, now.timeIntervalSince(lastSent) < AgentNotifications.window {
            held += 1
            return false
        }
        lastSent = now
        return true
    }

    /// When the window ends: how many held notes to summarise. A summary
    /// counts as a sent notification and opens the next window.
    public mutating func drain(at now: Date) -> Int {
        let count = held
        held = 0
        if count > 0 { lastSent = now }
        return count
    }

    /// The window ended but nothing was posted (permission changed, Beaver
    /// came to front): drop what's held without opening a new window.
    public mutating func discardHeld() {
        held = 0
    }

    /// When the current window closes, or nil when nothing is held.
    public var windowEnds: Date? {
        held > 0 ? lastSent?.addingTimeInterval(AgentNotifications.window) : nil
    }
}
