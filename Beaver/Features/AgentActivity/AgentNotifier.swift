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

    /// Set when `requestAuthorization` itself threw (seen on an
    /// unsigned/ad-hoc build launched from DerivedData) — so the strip and
    /// `notify()` can say so instead of silently doing nothing. Cleared by
    /// any request that completes without throwing.
    private(set) var lastRequestError: String?

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

    /// Muted always wins: a muted person is never shown the system prompt,
    /// whatever `authorization` says.
    var state: AgentNotifications.State {
        muted ? .muted : authorization
    }

    @ObservationIgnored private var throttle = NotificationThrottle()
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    /// One in-flight permission request at a time; the latest note that
    /// arrived while it's pending is the one delivered on grant (M28: never
    /// more than one banner catching up after Allow).
    @ObservationIgnored private var pendingAuth: Task<Void, Never>?
    @ObservationIgnored private var pendingNote: AgentNote?
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

    /// The one place that calls `requestAuthorization`: never swallows the
    /// result (a `try?` here previously hid both a thrown error and a
    /// silent `false` on an unsigned/ad-hoc build launched from
    /// DerivedData). Refreshes `authorization` either way.
    @discardableResult
    private func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            lastRequestError = nil
            await refresh()
            return granted
        } catch {
            lastRequestError = error.localizedDescription
            await refresh()
            return false
        }
    }

    /// An attention note: post it, hold it for the summary, or say why not.
    func notify(_ note: AgentNote) -> NotifyOutcome {
        let frontmost = NSApp.isActive
        guard !frontmost else { return AgentNotifications.outcome(state: state, frontmost: true, held: false) }
        switch state {
        case .allowed:
            return deliver(note)
        case .notDetermined:
            // A request already failed: don't retry silently on every
            // attention note — say so, with howToEnable, until the person
            // acts (the strip's button, or System Settings directly).
            guard lastRequestError == nil else {
                return AgentNotifications.outcome(state: .notDetermined, frontmost: false, held: false, requestFailed: true)
            }
            // Asked in context, on the first attention note — not at launch.
            // Only one request in flight: a note that arrives while it's
            // pending replaces the last one, still delivered through the
            // same throttle as .allowed once (if) permission is granted.
            pendingNote = note
            if pendingAuth == nil {
                pendingAuth = Task {
                    await requestAuthorization()
                    pendingAuth = nil
                    let toDeliver = pendingNote
                    pendingNote = nil
                    if state == .allowed, let toDeliver { _ = deliver(toDeliver) }
                }
            }
            return AgentNotifications.outcome(state: .notDetermined, frontmost: false, held: false)
        case .denied, .muted:
            return AgentNotifications.outcome(state: state, frontmost: false, held: false)
        }
    }

    /// The one path that actually posts (or holds for the summary): admits
    /// through the 30 s throttle, same as every other allowed note.
    private func deliver(_ note: AgentNote) -> NotifyOutcome {
        if throttle.admit(at: Date()) {
            post(note.text, links: note.links)
            return AgentNotifications.outcome(state: .allowed, frontmost: false, held: false)
        }
        scheduleSummary()
        return AgentNotifications.outcome(state: .allowed, frontmost: false, held: true)
    }

    /// The strip's button: always ends in something visible, even when
    /// macOS itself refuses to show a prompt (an unsigned/ad-hoc build).
    func perform(_ action: AgentNotifications.Strip.Action) {
        switch action {
        case .askPermission:
            Task {
                await requestAuthorization()
                if state != .allowed {
                    NSWorkspace.shared.open(AgentNotifications.settingsURL)
                }
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
    /// Drain (which advances the window) only happens when the summary is
    /// actually going to post; otherwise the held notes are discarded
    /// without moving `lastSent`, so a note right after still has to wait
    /// out the original window.
    private func scheduleSummary() {
        guard summaryTask == nil, let ends = throttle.windowEnds else { return }
        summaryTask = Task {
            try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            summaryTask = nil
            guard state == .allowed, !NSApp.isActive else {
                throttle.discardHeld()
                return
            }
            let count = throttle.drain(at: Date())
            guard count > 0 else { return }
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
