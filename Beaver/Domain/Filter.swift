import Foundation

public struct Filter: Equatable, Hashable, Sendable {

    /// Which of the two click-to-filter columns a constraint applies to.
    public enum Facet: Hashable, Sendable {
        case subsystem
        case category

        /// How a value reads in menus and chips; the value itself is
        /// what the filter stores and matches.
        public func displayName(_ value: String) -> String {
            self == .subsystem ? EventRecord.shortSubsystem(value) : value
        }
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

    /// Also match search / exclude terms against the event's `data`
    /// payload. Opt-in: payloads are ~97% of a session's bytes, so this
    /// turns a millisecond scan into a noticeable one (D40).
    public var searchPayloads: Bool

    /// Show only these subsystems. Empty means "no restriction", not
    /// "show nothing".
    public var subsystems: Set<String>

    public var excludedSubsystems: Set<String>

    public var categories: Set<String>

    public var excludedCategories: Set<String>

    /// Hide every event up to and including this id — what "Clear"
    /// does. Nothing is deleted: the events stay in the store, keep
    /// their bookmarks, and come back when this is cleared.
    ///
    /// Deliberately *not* saved with a named filter: an event id only
    /// means something inside one session.
    public var hiddenThroughEventId: Int64?

    public init(
        minLevel: LogLevel = .verbose,
        search: String? = nil,
        searchIsRegex: Bool = false,
        exclude: String? = nil,
        excludeIsRegex: Bool = false,
        searchPayloads: Bool = false,
        subsystems: Set<String> = [],
        excludedSubsystems: Set<String> = [],
        categories: Set<String> = [],
        excludedCategories: Set<String> = [],
        hiddenThroughEventId: Int64? = nil
    ) {
        self.minLevel = minLevel
        self.search = search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.searchIsRegex = searchIsRegex
        self.exclude = exclude?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.excludeIsRegex = excludeIsRegex
        self.searchPayloads = searchPayloads
        self.subsystems = subsystems
        self.excludedSubsystems = excludedSubsystems
        self.categories = categories
        self.excludedCategories = excludedCategories
        self.hiddenThroughEventId = hiddenThroughEventId
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
            && hiddenThroughEventId == nil
    }

    /// Whether `pattern` compiles the way the store will run it. The
    /// store ignores a pattern that doesn't, so a half-typed regex
    /// doesn't blank the feed; the UI marks the field instead.
    public static func isValidRegex(_ pattern: String) -> Bool {
        LogStore.compiledRegex(caseInsensitive(pattern)) != nil
    }

    /// Regex terms ignore case, matching `LIKE` and the highlighter.
    /// An inline `(?-i)` in the pattern still turns it back on.
    static func caseInsensitive(_ pattern: String) -> String {
        "(?i)" + pattern
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

/// One chip-menu entry: a subsystem or category and how many events match.
public struct FacetCount: Hashable, Sendable {
    public let value: String
    public let count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
