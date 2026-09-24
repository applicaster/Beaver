//
//  AgentNotifier.swift
//  Beaver
//
//  macOS notifications for the agent's attention notes (design M28, D68):
//  permission, delivery, coalescing, and what a click opens. The rules and
//  texts are in AgentNotifications (BeaverCore).

import AppKit
import Observation
import UserNotifications

extension Notification.Name {
    /// Posted with `object: JournalLink` when the person clicks Show, a
    /// notification or a journal link. MainWindow opens it.
    static let beaverShowAgentLink = Notification.Name("BeaverShowAgentLink")
}

@MainActor
@Observable
final class AgentNotifier {
    static let shared = AgentNotifier()

    /// What macOS allows: `.allowed`, `.denied` or `.notDetermined`.
    private(set) var authorization: AgentNotifications.State = .notDetermined

    /// "Notifications from the agent" off in the Agent panel.
    var muted: Bool {
        get { storedMuted }
        set {
            storedMuted = newValue
            UserDefaults.standard.set(newValue, forKey: Self.mutedKey)
        }
    }
    private var storedMuted: Bool

    /// Bumped to open the Agent panel (the menu item, a toast's Journal
    /// button, a summary notification).
    private(set) var panelRequests = 0

    var state: AgentNotifications.State {
        authorization == .allowed && muted ? .muted : authorization
    }

    @ObservationIgnored private var throttle = NotificationThrottle()
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    private let delegate = NotificationDelegate()
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    private static let mutedKey = "agentNotificationsMuted"

    private init() {
        storedMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        UNUserNotificationCenter.current().delegate = delegate
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AgentNotifier.shared.refresh() }
        }
        Task { await refresh() }
    }

    /// Re-read the permission: the person may have changed it in System Settings.
    func refresh() async {
        authorization = switch await Self.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .notDetermined
        }
    }

    /// Only the status crosses back to the main actor, not the settings object.
    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// An attention note: post it, hold it for the summary, or say why not.
    func notify(_ note: AgentNote) -> NotifyOutcome {
        let frontmost = NSApp.isActive
        guard !frontmost else { return AgentNotifications.outcome(state: state, frontmost: true, held: false) }
        switch state {
        case .allowed:
            let now = Date()
            if throttle.admit(at: now) {
                post(note.text, links: note.links)
                return AgentNotifications.outcome(state: .allowed, frontmost: false, held: false)
            }
            scheduleSummary()
            return AgentNotifications.outcome(state: .allowed, frontmost: false, held: true)
        case .notDetermined:
            // Asked in context, on the first attention note — not at launch.
            Task {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                await refresh()
                if granted, !muted { post(note.text, links: note.links) }
            }
            return AgentNotifications.outcome(state: .notDetermined, frontmost: false, held: false)
        case .denied, .muted:
            return AgentNotifications.outcome(state: state, frontmost: false, held: false)
        }
    }

    /// The strip's button.
    func perform(_ action: AgentNotifications.Strip.Action) {
        switch action {
        case .askPermission:
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refresh()
            }
        case .openSettings:
            NSWorkspace.shared.open(AgentNotifications.settingsURL)
        }
    }

    /// Toast Show, a notification click or a journal link: the person asked,
    /// so Beaver comes forward on what the note points at. (PR 3 routes this
    /// through ui_show.)
    func show(_ links: [JournalLink]) {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        if let first = links.first {
            NotificationCenter.default.post(name: .beaverShowAgentLink, object: first)
        } else {
            openPanel()
        }
    }

    func openPanel() { panelRequests += 1 }

    private func post(_ text: String, links: [JournalLink]) {
        let content = UNMutableNotificationContent()
        content.title = AgentNotifications.title
        content.body = text
        content.sound = .default
        content.userInfo = ["links": JournalLink.encode(links) ?? "[]"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// At the end of the 30 s window, one notification for the held notes.
    private func scheduleSummary() {
        guard summaryTask == nil, let ends = throttle.windowEnds else { return }
        summaryTask = Task {
            try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            summaryTask = nil
            let count = throttle.drain(at: Date())
            guard count > 0, state == .allowed, !NSApp.isActive else { return }
            post(AgentNotifications.summary(count: count), links: [])
        }
    }
}

/// Separate from AgentNotifier: the delegate must be an NSObject, and
/// @Observable classes are kept plain.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let links = JournalLink.decode(response.notification.request.content.userInfo["links"] as? String)
        await MainActor.run { AgentNotifier.shared.show(links) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
