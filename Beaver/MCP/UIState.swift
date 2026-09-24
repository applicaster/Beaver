//
//  UIState.swift
//  Beaver
//
//  The window state an agent reads and sets (design §7.1, M12, D54).
//  `AppEnvironment` holds its fields; `ui_state` reads it and `ui_show`
//  changes it.

import Foundation

/// The window's sidebar tabs. Raw values are what `ui_state` and
/// `ui_show` say.
public enum UITab: String, Sendable, CaseIterable {
    case logs, network, storages, sessions

    public var title: String {
        switch self {
        case .logs: "Log feed"
        case .network: "Network"
        case .storages: "Storages"
        case .sessions: "Sessions"
        }
    }
}

public struct UIState: Sendable, Equatable {
    public var tab: UITab = .logs
    /// The session the window shows (`AppEnvironment.viewingSessionId`).
    public var sessionId: Int64?
    public var logFilter: Filter = .none
    public var networkFilter = NetworkFilter()
    public var storageLayer: StorageSnapshot.Namespace = .session
    public var storageSearch = ""
    /// The Log feed's selected event, while exactly one row is selected.
    public var selectedEventId: Int64?
    /// The Network tab's selected request.
    public var selectedNetworkId: Int64?

    public init() {}

    /// `change` applied. Another session starts the way a session switch
    /// in the window does: Network and Storages at their defaults, nothing
    /// selected, the log filter carried over without its Clear watermark
    /// (D42). The fields `change` sets then win.
    public func applying(_ change: UIChange) -> UIState {
        var s = self
        if let id = change.sessionId, id != sessionId {
            s = UIState()
            s.tab = tab
            s.sessionId = id
            s.logFilter = logFilter.carriedOver
        }
        if let v = change.tab { s.tab = v }
        if let v = change.logFilter { s.logFilter = v }
        if let v = change.networkFilter { s.networkFilter = v }
        if let v = change.storageLayer { s.storageLayer = v }
        if let v = change.storageSearch { s.storageSearch = v }
        if let v = change.selectedEventId { s.selectedEventId = v }
        if let v = change.selectedNetworkId { s.selectedNetworkId = v }
        return s
    }
}

/// What `ui_show` changes; `nil` leaves a field as it is.
public struct UIChange: Sendable, Equatable {
    public var tab: UITab?
    public var sessionId: Int64?
    public var logFilter: Filter?
    public var networkFilter: NetworkFilter?
    public var storageLayer: StorageSnapshot.Namespace?
    public var storageSearch: String?
    public var selectedEventId: Int64?
    public var selectedNetworkId: Int64?
    /// Bring Beaver forward (M12) — the only thing that takes focus.
    public var reveal: Bool

    public init(tab: UITab? = nil, sessionId: Int64? = nil, logFilter: Filter? = nil,
                networkFilter: NetworkFilter? = nil, storageLayer: StorageSnapshot.Namespace? = nil,
                storageSearch: String? = nil, selectedEventId: Int64? = nil,
                selectedNetworkId: Int64? = nil, reveal: Bool = false) {
        self.tab = tab; self.sessionId = sessionId; self.logFilter = logFilter
        self.networkFilter = networkFilter; self.storageLayer = storageLayer
        self.storageSearch = storageSearch; self.selectedEventId = selectedEventId
        self.selectedNetworkId = selectedNetworkId; self.reveal = reveal
    }
}
