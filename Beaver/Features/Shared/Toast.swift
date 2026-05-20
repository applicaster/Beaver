//
//  Toast.swift
//  Beaver
//

import SwiftUI

/// One shown toast. Identified so the auto-dismiss task can verify
/// it's still the active toast before clearing — otherwise a quick
/// burst of toasts (copy → copy → copy) could leave the last one
/// dismissed early because an earlier task's timer fired late.
public struct Toast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String
    public let icon: String
    public let tint: Color

    public init(message: String, icon: String, tint: Color) {
        self.id = UUID()
        self.message = message
        self.icon = icon
        self.tint = tint
    }
}

/// App-wide toast surface. Inject via `.environment(ToastCenter())`
/// from `BeaverApp` and read with `@Environment` anywhere a
/// transient confirmation is useful (copy succeeded, key deleted,
/// filter preset saved, …).
///
/// The presenter lives in `MainWindow` as an `.overlay` so a single
/// toast is shown at a time at the top of the window. Calling
/// `show(…)` while a toast is already on screen replaces it — by
/// design; users typing fast want to see the *latest* feedback,
/// not a queued one from three actions ago.
@Observable
@MainActor
public final class ToastCenter {
    public private(set) var current: Toast?

    /// nonisolated(unsafe) so a brand-new `show` can cancel the
    /// previous auto-dismiss task without bouncing through the
    /// actor. Only mutated from `@MainActor` methods.
    private nonisolated(unsafe) var dismissTask: Task<Void, Never>?

    public init() {}

    /// Show a toast. If one's already visible it's replaced.
    /// Auto-dismisses after `duration` seconds.
    public func show(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        tint: Color = .green,
        duration: TimeInterval = 2.0
    ) {
        let toast = Toast(message: message, icon: icon, tint: tint)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if Task.isCancelled { return }
            await MainActor.run {
                // Only clear if we're still the active toast. A
                // later show() may have replaced us with a new id;
                // in that case its own timer is the source of truth.
                if self?.current?.id == toast.id {
                    self?.current = nil
                }
            }
        }
    }

    // MARK: - Convenience presets

    /// Green check — successful action.
    public func success(_ message: String) {
        show(message, icon: "checkmark.circle.fill", tint: .green)
    }

    /// Blue info — passive notification.
    public func info(_ message: String) {
        show(message, icon: "info.circle.fill", tint: .accentColor)
    }

    /// Red exclamation — something failed.
    public func error(_ message: String) {
        show(message, icon: "exclamationmark.triangle.fill", tint: .red, duration: 3.0)
    }
}

/// Floating chip that displays the current toast. Slides in from
/// the top with the same easing as macOS's notification banners.
///
/// Lives as an `.overlay(alignment: .top)` on `MainWindow.body` so
/// it floats above every tab without affecting layout. Hit-tests
/// don't propagate through — the chip is decorative.
public struct ToastPresenter: View {
    @Environment(ToastCenter.self) private var center

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            if let toast = center.current {
                HStack(spacing: 8) {
                    Image(systemName: toast.icon)
                        .foregroundStyle(toast.tint)
                        .font(.system(size: 14, weight: .semibold))
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 12)
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
                // Without an id keyed to the toast's UUID, replacing
                // one toast with another (same view shape, different
                // content) doesn't animate — SwiftUI sees the same
                // identity. The id forces a fresh node so the new
                // toast slides in.
                .id(toast.id)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.22), value: center.current?.id)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
