import Foundation

public struct Filter: Equatable, Hashable, Sendable {

    /// Which of the two click-to-filter columns a constraint applies to.
    public enum Facet: Hashable, Sendable {
        case subsystem
        case category
    }

    /// Where a value sits in the include → exclude → off cycle.
    public enum ChipState: Hashable, Sendable {
        case off
        /// Show only rows carrying this value.
        case include
        /// Hide rows carrying this value.
        case exclude
    }

    public var minLevel: LogLevel

    public var search: String?

    public var searchIsRegex: Bool

    public var exclude: String?

    public var excludeIsRegex: Bool

    /// Show only these subsystems. Empty means "no restriction", not
    /// "show nothing".
    public var subsystems: Set<String>

    public var excludedSubsystems: Set<String>

    public var categories: Set<String>

    public var excludedCategories: Set<String>

    public init(
        minLevel: LogLevel = .verbose,
        search: String? = nil,
        searchIsRegex: Bool = false,
        exclude: String? = nil,
        excludeIsRegex: Bool = false,
        subsystems: Set<String> = [],
        excludedSubsystems: Set<String> = [],
        categories: Set<String> = [],
        excludedCategories: Set<String> = []
    ) {
        self.minLevel = minLevel
        self.search = search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.searchIsRegex = searchIsRegex
        self.exclude = exclude?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.excludeIsRegex = excludeIsRegex
        self.subsystems = subsystems
        self.excludedSubsystems = excludedSubsystems
        self.categories = categories
        self.excludedCategories = excludedCategories
    }

    public static let none = Filter()

    public var isEmpty: Bool {
        minLevel == .verbose
            && search == nil
            && exclude == nil
            && subsystems.isEmpty
            && excludedSubsystems.isEmpty
            && categories.isEmpty
            && excludedCategories.isEmpty
    }

    /// Number of active chips, for the facet menu's badge.
    public func chipCount(for facet: Facet) -> Int {
        included(facet).count + excluded(facet).count
    }

    public func state(of value: String, in facet: Facet) -> ChipState {
        if included(facet).contains(value) { return .include }
        if excluded(facet).contains(value) { return .exclude }
        return .off
    }

    /// One click advances include → exclude → off, matching the web
    /// viewer's chips.
    public mutating func cycle(_ value: String, in facet: Facet) {
        switch state(of: value, in: facet) {
        case .off:     set(.include, for: value, in: facet)
        case .include: set(.exclude, for: value, in: facet)
        case .exclude: set(.off, for: value, in: facet)
        }
    }

    public mutating func set(_ state: ChipState, for value: String, in facet: Facet) {
        // A value is only ever in one of the two sets.
        switch facet {
        case .subsystem:
            subsystems.remove(value)
            excludedSubsystems.remove(value)
            if state == .include { subsystems.insert(value) }
            if state == .exclude { excludedSubsystems.insert(value) }
        case .category:
            categories.remove(value)
            excludedCategories.remove(value)
            if state == .include { categories.insert(value) }
            if state == .exclude { excludedCategories.insert(value) }
        }
    }

    public mutating func clearChips(in facet: Facet) {
        set(facet: facet, included: [], excluded: [])
    }

    public func included(_ facet: Facet) -> Set<String> {
        switch facet {
        case .subsystem: subsystems
        case .category:  categories
        }
    }

    public func excluded(_ facet: Facet) -> Set<String> {
        switch facet {
        case .subsystem: excludedSubsystems
        case .category:  excludedCategories
        }
    }

    private mutating func set(
        facet: Facet,
        included: Set<String>,
        excluded: Set<String>
    ) {
        switch facet {
        case .subsystem:
            subsystems = included
            excludedSubsystems = excluded
        case .category:
            categories = included
            excludedCategories = excluded
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
