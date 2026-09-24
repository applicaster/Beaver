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
