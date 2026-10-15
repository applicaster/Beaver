//
//  TailFollow.swift
//  Beaver
//

/// Whether the Log feed follows new rows, per D3: being at the bottom
/// *is* following. Scrolling away stops it and starts counting what
/// arrives. Scrolling back to the bottom resumes it.
public struct TailFollow: Equatable, Sendable {
    public private(set) var isFollowing = true
    /// Events that arrived while not following — the "N new ↓" pill.
    public private(set) var unseen = 0

    public init() {}

    public mutating func scrolled(atBottom: Bool) {
        atBottom ? resume() : stop()
    }

    /// Whether a user scroll counts as "at the bottom". `gap` is how far
    /// the visible area ends above the content's end. Following, any move
    /// off the very bottom stops it: with the slack, a slow scroll up
    /// stayed "at the bottom" and the next row snapped it back. Not
    /// following, scrolling down to within `slack` resumes.
    public static func atBottom(gap: Double, slack: Double, following: Bool, movedUp: Bool) -> Bool {
        following ? gap <= 1 : gap <= slack && !movedUp
    }

    public mutating func appended(_ count: Int) {
        if !isFollowing { unseen += count }
    }

    /// A jump or a pause took the view off the tail.
    public mutating func stop() {
        isFollowing = false
    }

    public mutating func resume() {
        isFollowing = true
        unseen = 0
    }
}
