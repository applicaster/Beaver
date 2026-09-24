import AppKit
import SwiftUI

/// Invisible bridge that finds the `NSScrollView` a SwiftUI `Table` is
/// built on and reports each user scroll (trackpad, wheel, scroller
/// drag) with whether it ended at the bottom.
///
/// Drives follow-the-tail in the Log feed (D3) and the Network tab.
/// Programmatic scrolls (`proxy.scrollTo`) don't post
/// `didLiveScrollNotification`, so following never turns itself off.
///
/// Place it as a `.background` of the Table.
struct ScrollWatcher: NSViewRepresentable {
    /// How close to the end, in points, still counts as the bottom.
    /// `nil` means three rows of the table (D3).
    var bottomSlack: CGFloat? = nil
    let onUserScroll: (_ atBottom: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWatcherView()
        view.bottomSlack = bottomSlack
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ScrollWatcherView else { return }
        view.bottomSlack = bottomSlack
        view.onUserScroll = onUserScroll
    }
}

private final class ScrollWatcherView: NSView {
    var bottomSlack: CGFloat?
    var onUserScroll: ((Bool) -> Void)?
    private weak var observed: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { unsubscribe(); return }
        // The Table installs its NSScrollView a runloop later; without
        // the delay findScrollView() walks an incomplete view tree.
        DispatchQueue.main.async { [weak self] in self?.subscribe() }
    }

    deinit { unsubscribe() }

    private func subscribe() {
        guard let scrollView = findScrollView(), observed !== scrollView else { return }
        unsubscribe()
        observed = scrollView
        NotificationCenter.default.addObserver(self, selector: #selector(handleScroll),
                                               name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    private func unsubscribe() {
        if let observed {
            NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification,
                                                      object: observed)
        }
        observed = nil
    }

    @objc private func handleScroll() {
        guard let scrollView = observed, let document = scrollView.documentView else { return }
        let slack = bottomSlack ?? 3 * ((document as? NSTableView)
            .map { $0.rowHeight + $0.intercellSpacing.height } ?? 24)
        onUserScroll?(scrollView.contentView.bounds.maxY >= document.frame.height - slack)
    }

    /// The Table's scroll view: an ancestor, or — since it's sometimes a
    /// sibling of the `.background` view — a sibling's descendant.
    private func findScrollView() -> NSScrollView? {
        var current: NSView? = superview
        while let view = current {
            if let scroll = view as? NSScrollView { return scroll }
            for sibling in view.superview?.subviews ?? [] where sibling !== view {
                if let scroll = sibling as? NSScrollView ?? sibling.firstDescendantScrollView() { return scroll }
            }
            current = view.superview
        }
        return nil
    }
}

private extension NSView {
    func firstDescendantScrollView() -> NSScrollView? {
        for child in subviews {
            if let scroll = child as? NSScrollView ?? child.firstDescendantScrollView() { return scroll }
        }
        return nil
    }
}
