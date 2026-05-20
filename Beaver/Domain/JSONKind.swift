//
//  JSONKind.swift
//  Beaver
//

import Foundation

/// What a node in a JSON tree actually is, beyond its rendered text.
///
/// Both `JSONTreeNode` (log event payloads) and `StorageRecord`
/// (Storages screen) carry one of these. Row views read it to render
/// each value with proper syntax colouring — string vs number vs
/// bool, quoted vs unquoted, etc.
///
/// Keeping this in the Domain layer means the rendering layer
/// (Features/Shared/JSONSyntaxText) is a pure presentation concern.
public enum JSONKind: Hashable, Sendable {
    /// Unquoted string content. The row view adds the visible quotes.
    case string(String)
    /// Numeric literal, already in its preferred string form.
    case number(String)
    case bool(Bool)
    case null
    /// Object container summary — child count for `{ N }` display.
    case object(count: Int)
    /// Array container summary — child count for `[ N ]` display.
    case array(count: Int)

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default:              return false
        }
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }
}
