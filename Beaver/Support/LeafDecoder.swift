import Foundation

// MARK: - Result types

/// One link in a value's decode chain. A storage value can be wrapped
/// more than once — e.g. a JWT stored as JSON text, then Base64'd —
/// so the chain is recorded outermost-first: `[.base64, .json, .jwt]`.
public enum DecodeKind: String, Hashable, Sendable {
    case base64
    case json
    case jwt

    /// Short lowercase tag shown as the badge next to the value.
    public var badgeText: String { rawValue }

    /// Tooltip for the badge.
    public var badgeHelp: String {
        switch self {
        case .base64: "Base64 — decoded"
        case .json:   "Stored as a JSON string"
        case .jwt:    "JWT — decoded header & payload"
        }
    }
}

/// Validity of a decoded JWT, derived from its `exp` / `nbf` claims.
public enum JWTStatus: String, Hashable, Sendable {
    case valid
    case expired
    case pending

    /// Human phrasing for tooltips: "This token is <label>".
    public var label: String {
        switch self {
        case .valid:   "valid"
        case .expired: "expired"
        case .pending: "not yet valid"
        }
    }

    /// Row chip text, e.g. `JWT-EXPIRED`.
    public var chipText: String { "JWT-\(rawValue.uppercased())" }

    /// Worst-wins ordering, used when a value contains several tokens
    /// that disagree — an expired one is the most important to surface.
    fileprivate var rank: Int {
        switch self {
        case .expired: 3
        case .pending: 2
        case .valid:   1
        }
    }
}

/// One line of the plain-language JWT summary ("Expires", "Issuer", …).
public struct JWTClaim: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Everything the UI needs to render a decoded leaf: what it turned out
/// to be, the decoded content, and why it could be decoded.
public struct LeafDecode: Hashable, Sendable {
    /// Decode chain, outermost first. Never empty.
    public let kinds: [DecodeKind]

    /// Decoded structure, when the final content is an object / array.
    /// Label-neutral: the caller supplies the root label at render time,
    /// so only `tree.children` is rendered.
    public let tree: StorageRecord?

    /// Decoded plain text, when the final content isn't structured.
    public let text: String?

    /// Validity chip — only for values that are themselves a JWT.
    public let chip: JWTStatus?

    /// Friendly Expires / Issued / Issuer / Subject / Audience summary.
    public let jwtClaims: [JWTClaim]

    /// Plain-language explanation of the decode chain, shown next to the
    /// Formatted / Raw switch.
    public let note: String

    /// The badge shown on the row — the *outermost* wrapper, which is
    /// what the user actually stored.
    public var badgeKind: DecodeKind? { kinds.first }

    public var isJWT: Bool { kinds.contains(.jwt) }
}

// MARK: - Decoder

/// Recursive decoder for encoded string values, ported from the web
/// viewer's `src/utils/leafDecoder.ts` so both apps classify a value the
/// same way.
///
/// Detects (bounded to 2 hops) Base64, JWT and JSON-encoded strings,
/// resolving wrapped tokens like base64 → JWT, base64 → JSON, or
/// JSON-string → JWT.
///
/// The RAW stored string always stays the source of truth for copy and
/// edit; this only produces the *Formatted* view alongside it.
public enum LeafDecoder {

    /// Maximum wrapper layers unwrapped. Two covers every real case seen
    /// in the field (base64 → JSON → JWT) without letting a pathological
    /// value spin.
    private static let maxDepth = 2

    /// Depth cap for the "contains a token somewhere inside" scan.
    private static let maxNestedScanDepth = 4

    // MARK: Public API

    /// Classify a stored string. Returns `nil` when it is just a plain
    /// value with nothing to decode.
    public static func decode(_ raw: String) -> LeafDecode? {
        // `utf16.count` is O(1) on the bridged strings JSONSerialization
        // hands out; this rejects a 24 MB leaf before touching its bytes.
        let length = raw.utf16.count
        guard length <= maxDecodableLength else { return nil }
        // Keyed by the raw string, not a trimmed copy: a hit costs no
        // allocation, and the key shares storage with the record.
        if let cached = cache.object(forKey: raw as NSString) {
            return cached.value
        }
        let result = makeDecode(raw.trimmed)
        // Measured: a decoded tree weighs ~3× its source string.
        cache.setObject(Box(result), forKey: raw as NSString,
                        cost: result == nil ? length * 2 : length * 6)
        return result
    }

    /// Longest value (UTF-16 units) worth decoding. Past this there is no
    /// tree anyone would read, and one attempt costs ~0.4 s on a 24 MB
    /// string (a Metro bundle stored in a real network log).
    static let maxDecodableLength = 4 * 1_024 * 1_024

    /// Worst status among any JWTs found inside an already-parsed value.
    ///
    /// Lets a row flag `JWT-EXPIRED` for a Base64 blob that merely
    /// *contains* a stale token, so it is visible without expanding.
    public static func nestedJWTStatus(
        in record: StorageRecord,
        depth: Int = 0
    ) -> JWTStatus? {
        guard depth <= maxNestedScanDepth else { return nil }

        // Through the cache: this runs from row `body`s, hover included,
        // and decoding every leaf afresh cost ~35 ms per pass over a real
        // session layer.
        if case .string(let s) = record.kind {
            guard let decoded = decode(s) else { return nil }
            if decoded.isJWT { return decoded.chip }
            guard let tree = decoded.tree else { return nil }
            return nestedJWTStatus(in: tree, depth: depth + 1)
        }

        guard let children = record.children else { return nil }
        var worst: JWTStatus?
        for child in children {
            worst = worse(worst, nestedJWTStatus(in: child, depth: depth + 1))
        }
        return worst
    }

    // MARK: Cache

    /// Decoding runs inside SwiftUI `body`, which re-evaluates on every
    /// hover / selection change, so a long Base64 blob would otherwise be
    /// re-decoded dozens of times a second. `NSCache` is bounded and
    /// thread-safe, so no eviction or locking code of our own.
    ///
    /// Only the top-level result is cached; the ≤2 recursive hops inside
    /// are cheap by comparison.
    ///
    /// Bounded by bytes as well as count: a count alone let 2 000 large
    /// values pin ~3.5 GB (1.8 MB per 632 KB JSON string, measured).
    /// `nonisolated(unsafe)` is accurate rather than a waiver: `NSCache` is
    /// documented as thread-safe, and `Box` is immutable.
    private nonisolated(unsafe) static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 2_000
        c.totalCostLimit = 256 * 1_024 * 1_024
        return c
    }()

    /// NSCache needs class values, and we cache misses too (`nil`), so the
    /// box holds an optional.
    private final class Box: Sendable {
        let value: LeafDecode?
        init(_ value: LeafDecode?) { self.value = value }
    }

    private static func makeDecode(_ trimmed: String) -> LeafDecode? {
        guard let detected = detect(trimmed, depth: 0) else { return nil }
        let isJWT = detected.kinds.contains(.jwt)
        return LeafDecode(
            kinds: detected.kinds,
            tree: detected.tree.map(buildRecord(from:)),
            text: detected.text,
            chip: isJWT ? jwtStatus(of: detected.tree) : nil,
            jwtClaims: isJWT ? jwtClaims(of: detected.tree) : [],
            note: formatNote(detected.kinds)
        )
    }

    // MARK: Detection

    /// Intermediate result — `tree` is still a raw `JSONSerialization`
    /// value here so the recursive hops don't pay for building records
    /// they may discard.
    private struct Detected {
        let kinds: [DecodeKind]
        let tree: Any?
        let text: String?
    }

    private static func detect(_ t: String, depth: Int) -> Detected? {
        guard !t.isEmpty else { return nil }

        // A JWT is the most specific shape, so it wins outright.
        if let jwt = parseJWT(t) {
            return Detected(kinds: [.jwt], tree: jwt, text: nil)
        }

        // Structured data stored as text — by far the common case.
        if let first = t.first, first == "{" || first == "[",
           let tree = parseJSONContainer(t) {
            return Detected(kinds: [.json], tree: tree, text: nil)
        }

        // A JSON *string* literal wrapping something else, e.g. "\"eyJ…\"".
        if depth < maxDepth, t.first == "\"",
           let inner = parseJSONStringLiteral(t),
           let nested = detect(inner.trimmed, depth: depth + 1) {
            return Detected(
                kinds: [.json] + nested.kinds,
                tree: nested.tree,
                text: nested.text
            )
        }

        if let decoded = tryBase64Decode(t) {
            if depth < maxDepth,
               let nested = detect(decoded.trimmed, depth: depth + 1) {
                return Detected(
                    kinds: [.base64] + nested.kinds,
                    tree: nested.tree,
                    text: nested.text
                )
            }
            return Detected(kinds: [.base64], tree: nil, text: decoded)
        }

        return nil
    }

    // MARK: JSON

    private static func parseJSONContainer(_ t: String) -> Any? {
        guard let data = t.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return (parsed is [String: Any] || parsed is [Any]) ? parsed : nil
    }

    private static func parseJSONStringLiteral(_ t: String) -> String? {
        guard let data = t.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )
        else { return nil }
        return parsed as? String
    }

    // MARK: JWT

    /// Split and decode a `header.payload.signature` token. Returns the
    /// same shape the web viewer renders, so the tree reads identically.
    private static func parseJWT(_ t: String) -> [String: Any]? {
        // Equivalent to /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$/
        // — the signature segment may be empty (unsigned tokens).
        let parts = t.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts.allSatisfy({ $0.allSatisfy(\.isBase64URLCharacter) })
        else { return nil }

        guard let headerText = base64URLToString(String(parts[0])),
              let payloadText = base64URLToString(String(parts[1])),
              let header = parseJSONContainer(headerText),
              let payload = parseJSONContainer(payloadText)
        else { return nil }

        return [
            "header": header,
            "payload": payload,
            "signature": String(parts[2]),
        ]
    }

    private static func payload(of tree: Any?) -> [String: Any]? {
        (tree as? [String: Any])?["payload"] as? [String: Any]
    }

    private static func jwtStatus(of tree: Any?) -> JWTStatus? {
        guard let p = payload(of: tree) else { return nil }
        let now = Date().timeIntervalSince1970
        let exp = (p["exp"] as? NSNumber)?.doubleValue
        let nbf = (p["nbf"] as? NSNumber)?.doubleValue

        if let nbf, now < nbf { return .pending }
        if let exp { return now >= exp ? .expired : .valid }
        return nil
    }

    private static func jwtClaims(of tree: Any?) -> [JWTClaim] {
        guard let p = payload(of: tree) else { return [] }
        let now = Date()
        let relativeFormatter = makeRelativeFormatter()
        var out: [JWTClaim] = []

        if let exp = (p["exp"] as? NSNumber)?.doubleValue {
            let date = Date(timeIntervalSince1970: exp)
            out.append(JWTClaim(
                label: "Expires",
                value: "\(absoluteFormatter.string(from: date)) (\(relativeFormatter.localizedString(for: date, relativeTo: now)))"
            ))
        }
        if let iat = (p["iat"] as? NSNumber)?.doubleValue {
            out.append(JWTClaim(
                label: "Issued",
                value: absoluteFormatter.string(from: Date(timeIntervalSince1970: iat))
            ))
        }
        if let iss = p["iss"] {
            out.append(JWTClaim(label: "Issuer", value: describe(iss)))
        }
        if let sub = p["sub"] {
            out.append(JWTClaim(label: "Subject", value: describe(sub)))
        }
        if let aud = p["aud"] {
            let value = (aud as? [Any]).map { $0.map(describe).joined(separator: ", ") }
                ?? describe(aud)
            out.append(JWTClaim(label: "Audience", value: value))
        }
        return out
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let s as String:   return s
        case let n as NSNumber: return n.stringValue
        default:                return String(describing: value)
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Built per call rather than cached: `RelativeDateTimeFormatter` isn't
    /// `Sendable`, and claims are computed once per distinct value (the
    /// result is cached), so the allocation is noise.
    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }

    // MARK: Base64

    /// Decode a Base64 segment that is known to be Base64 (JWT parts) —
    /// no printability heuristic, the caller validates via JSON parsing.
    private static func base64URLToString(_ s: String) -> String? {
        guard let data = base64Data(s, urlSafe: true) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a *candidate* Base64 string, rejecting anything that turns
    /// out to be binary. Strings that merely look Base64-ish are common
    /// (hashes, IDs), so a decode that produces control characters is
    /// treated as a false positive and the raw value is kept.
    private static func base64DecodeText(_ s: String, urlSafe: Bool) -> String? {
        guard let data = base64Data(s, urlSafe: urlSafe),
              // Strict UTF-8: Swift's initializer already rejects
              // invalid sequences, matching TextDecoder({fatal:true}).
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }

        var printable = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if isGraphic(scalar.value) { printable += 1 }
        }
        guard total > 0, Double(printable) / Double(total) >= 0.9 else { return nil }
        return text
    }

    private static func base64Data(_ s: String, urlSafe: Bool) -> Data? {
        var x = urlSafe
            ? s.replacingOccurrences(of: "-", with: "+")
               .replacingOccurrences(of: "_", with: "/")
            : s
        let remainder = x.count % 4
        // A length ≡ 1 (mod 4) can never be valid Base64.
        if remainder == 1 { return nil }
        if remainder != 0 { x += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: x)
    }

    /// Characters that survive a Base64 round-trip as readable text.
    /// Control characters and the invisible NBSP family mean we decoded
    /// binary, not text.
    private static func isGraphic(_ c: UInt32) -> Bool {
        if c == 9 || c == 10 || c == 13 { return true }   // tab / LF / CR
        if c < 0x20 { return false }                       // C0 controls
        if c == 0x7f { return false }                      // DEL
        if c >= 0x80 && c <= 0x9f { return false }         // C1 controls
        if c == 0xa0 || c == 0x2007 || c == 0x202f { return false }  // NBSP family
        return true
    }

    private static func tryBase64Decode(_ t: String) -> String? {
        if let payload = dataURIBase64Payload(t) {
            return base64DecodeText(payload, urlSafe: false)
        }
        let isStandard = t.allSatisfy(\.isBase64StandardCharacter)
        let isURLSafe  = t.allSatisfy(\.isBase64URLCharacter)
        guard isStandard || isURLSafe else { return nil }
        // Require padding or enough length — short alphanumeric strings
        // are far more often IDs than Base64.
        guard t.contains("=") || t.count >= 24 else { return nil }
        let urlSafe = t.contains(where: { $0 == "-" || $0 == "_" })
        return base64DecodeText(t, urlSafe: urlSafe)
    }

    /// `data:<media-type>;base64,<payload>` → the payload.
    private static func dataURIBase64Payload(_ t: String) -> String? {
        guard t.hasPrefix("data:"),
              let range = t.range(of: ";base64,")
        else { return nil }
        // The media type must not contain ';' or ',' — matches
        // /^data:[^;,]*;base64,(.+)$/.
        let mediaType = t[t.index(t.startIndex, offsetBy: 5)..<range.lowerBound]
        guard !mediaType.contains(";"), !mediaType.contains(",") else { return nil }
        let payload = String(t[range.upperBound...])
        return payload.isEmpty ? nil : payload
    }

    // MARK: Notes

    /// Plain-language caption telling a support engineer *why* the value
    /// could be decoded, so they don't have to recognise the format.
    private static func formatNote(_ kinds: [DecodeKind]) -> String {
        guard let first = kinds.first, let last = kinds.last else { return "" }

        let finalDescription: String
        switch last {
        case .jwt:    finalDescription = "a login token (JWT)"
        case .json:   finalDescription = "structured data (JSON)"
        case .base64: finalDescription = "plain text"
        }

        if kinds.count == 1 {
            switch first {
            case .json:
                return "Structured data (JSON) saved as text — shown as a readable tree"
            case .jwt:
                return "A login token (JWT) — decoded to show what's inside"
            case .base64:
                return "Encoded as Base64 — decoded to plain text"
            }
        }
        switch first {
        case .base64: return "Encoded as Base64 — decoded to \(finalDescription)"
        case .json:   return "Saved as JSON text — contains \(finalDescription)"
        case .jwt:    return "Decoded to \(finalDescription)"
        }
    }

    // MARK: Helpers

    private static func buildRecord(from value: Any) -> StorageRecord {
        // Label-neutral root: the caller renders `children` under its own
        // key, matching the web tree's `rootLabel` property.
        StorageRecord.make(key: "", value: value, path: "")
    }

    private static func worse(_ a: JWTStatus?, _ b: JWTStatus?) -> JWTStatus? {
        guard let a else { return b }
        guard let b else { return a }
        return b.rank > a.rank ? b : a
    }
}

// MARK: - Character classes

private extension Character {
    /// `A-Za-z0-9+/=`
    var isBase64StandardCharacter: Bool {
        isASCII && (isLetter || isNumber || self == "+" || self == "/" || self == "=")
    }

    /// `A-Za-z0-9_-`
    var isBase64URLCharacter: Bool {
        isASCII && (isLetter || isNumber || self == "_" || self == "-")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
