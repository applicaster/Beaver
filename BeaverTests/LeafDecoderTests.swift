import Testing
import Foundation
@testable import BeaverCore

/// Covers the decode chain ported from the web viewer's `leafDecoder.ts`.
/// The interesting cases are the false positives — strings that merely
/// *look* encoded — and wrapped tokens, which is where the two
/// implementations are easiest to drift apart.
@Suite("LeafDecoder")
struct LeafDecoderTests {

    // MARK: Fixtures

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A syntactically valid JWT. The signature isn't verified anywhere —
    /// the viewer only decodes — so a placeholder is fine.
    private static func makeJWT(payload: String, signature: String = "c2ln") -> String {
        let header = base64URL(#"{"alg":"HS256","typ":"JWT"}"#)
        return "\(header).\(base64URL(payload)).\(signature)"
    }

    private static var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

    // MARK: Nothing to decode

    @Test("A plain value decodes to nil")
    func plainValueIsNotDecoded() {
        #expect(LeafDecoder.decode("92") == nil)
        #expect(LeafDecoder.decode("") == nil)
        #expect(LeafDecoder.decode("com.applicaster.player") == nil)
    }

    @Test("A short ID that looks Base64-ish is left alone")
    func shortBase64LikeStringIsNotDecoded() {
        // 16 chars, no padding — below the length floor, so it stays raw.
        #expect(LeafDecoder.decode("a1b2c3d4e5f6g7h8") == nil)
    }

    @Test("Base64 that decodes to binary is left alone")
    func binaryBase64IsRejected() {
        let binary = Data((0..<24).map { UInt8($0) })
        let encoded = binary.base64EncodedString()
        #expect(LeafDecoder.decode(encoded) == nil)
    }

    @Test("A length that can't be Base64 is rejected")
    func impossibleBase64LengthIsRejected() {
        // 25 chars ≡ 1 (mod 4) — no amount of padding makes this valid.
        #expect(LeafDecoder.decode(String(repeating: "A", count: 25)) == nil)
    }

    // MARK: Single-layer

    @Test("JSON stored as text becomes a tree")
    func jsonStringIsDecoded() throws {
        let decoded = try #require(LeafDecoder.decode(#"{"a":1,"b":"two"}"#))

        #expect(decoded.kinds == [.json])
        #expect(decoded.badgeKind == .json)
        #expect(decoded.isJWT == false)
        #expect(decoded.tree?.children?.count == 2)
        #expect(decoded.note == "Structured data (JSON) saved as text — shown as a readable tree")
    }

    @Test("Base64 of plain text decodes to text, not a tree")
    func base64TextIsDecoded() throws {
        let original = "Support engineers read this without re-typing it."
        let decoded = try #require(
            LeafDecoder.decode(Data(original.utf8).base64EncodedString())
        )

        #expect(decoded.kinds == [.base64])
        #expect(decoded.text == original)
        #expect(decoded.tree == nil)
        #expect(decoded.note == "Encoded as Base64 — decoded to plain text")
    }

    @Test("A data: URI payload is decoded")
    func dataURIIsDecoded() throws {
        let payload = Data("hello from a data URI".utf8).base64EncodedString()
        let decoded = try #require(
            LeafDecoder.decode("data:text/plain;base64,\(payload)")
        )

        #expect(decoded.kinds == [.base64])
        #expect(decoded.text == "hello from a data URI")
    }

    @Test("A JWT decodes into header / payload / signature")
    func jwtIsDecoded() throws {
        let jwt = Self.makeJWT(
            payload: #"{"sub":"user-42","iss":"applicaster","exp":\#(Self.nowSeconds + 3600)}"#
        )
        let decoded = try #require(LeafDecoder.decode(jwt))

        #expect(decoded.kinds == [.jwt])
        #expect(decoded.isJWT)
        #expect(decoded.chip == .valid)

        let keys = decoded.tree?.children?.map(\.key).sorted()
        #expect(keys == ["header", "payload", "signature"])
        #expect(decoded.note == "A login token (JWT) — decoded to show what's inside")
    }

    @Test("An unsigned token (empty signature) is still a JWT")
    func unsignedJWTIsDecoded() throws {
        let jwt = Self.makeJWT(payload: #"{"sub":"anon"}"#, signature: "")
        let decoded = try #require(LeafDecoder.decode(jwt))

        #expect(decoded.kinds == [.jwt])
        // No `exp` means no verdict to show.
        #expect(decoded.chip == nil)
    }

    // MARK: Token validity

    @Test("Expiry drives the status chip")
    func jwtStatusReflectsExpiry() throws {
        let now = Self.nowSeconds

        let valid = try #require(
            LeafDecoder.decode(Self.makeJWT(payload: #"{"exp":\#(now + 3600)}"#))
        )
        #expect(valid.chip == .valid)

        let expired = try #require(
            LeafDecoder.decode(Self.makeJWT(payload: #"{"exp":\#(now - 3600)}"#))
        )
        #expect(expired.chip == .expired)

        // `nbf` in the future wins over a still-good `exp`.
        let pending = try #require(
            LeafDecoder.decode(
                Self.makeJWT(payload: #"{"nbf":\#(now + 3600),"exp":\#(now + 7200)}"#)
            )
        )
        #expect(pending.chip == .pending)
    }

    @Test("Chip text matches the web viewer's row badge")
    func chipTextFormatting() {
        #expect(JWTStatus.valid.chipText == "JWT-VALID")
        #expect(JWTStatus.expired.chipText == "JWT-EXPIRED")
        #expect(JWTStatus.pending.chipText == "JWT-PENDING")
        #expect(JWTStatus.pending.label == "not yet valid")
    }

    @Test("Claims are summarised in plain words")
    func jwtClaimsAreSummarised() throws {
        let now = Self.nowSeconds
        let jwt = Self.makeJWT(payload: """
        {"exp":\(now + 3600),"iat":\(now - 60),"iss":"applicaster",\
        "sub":"user-42","aud":["ios","web"]}
        """)
        let decoded = try #require(LeafDecoder.decode(jwt))

        let labels = decoded.jwtClaims.map(\.label)
        #expect(labels == ["Expires", "Issued", "Issuer", "Subject", "Audience"])

        let byLabel = Dictionary(
            uniqueKeysWithValues: decoded.jwtClaims.map { ($0.label, $0.value) }
        )
        #expect(byLabel["Issuer"] == "applicaster")
        #expect(byLabel["Subject"] == "user-42")
        // An array audience is joined, not printed as a Swift array.
        #expect(byLabel["Audience"] == "ios, web")
        // Expiry carries both the date and how far away it is.
        #expect(byLabel["Expires"]?.contains("(") == true)
    }

    // MARK: Wrapped values

    @Test("Base64 wrapping a JWT unwraps both layers")
    func base64WrappedJWT() throws {
        let jwt = Self.makeJWT(payload: #"{"exp":\#(Self.nowSeconds - 10)}"#)
        let wrapped = Data(jwt.utf8).base64EncodedString()
        let decoded = try #require(LeafDecoder.decode(wrapped))

        #expect(decoded.kinds == [.base64, .jwt])
        // The badge shows the *outer* wrapper — what was actually stored.
        #expect(decoded.badgeKind == .base64)
        #expect(decoded.chip == .expired)
        #expect(decoded.note == "Encoded as Base64 — decoded to a login token (JWT)")
    }

    @Test("Base64 wrapping JSON unwraps to a tree")
    func base64WrappedJSON() throws {
        let json = #"{"token":"abc","layoutId":"home"}"#
        let decoded = try #require(
            LeafDecoder.decode(Data(json.utf8).base64EncodedString())
        )

        #expect(decoded.kinds == [.base64, .json])
        #expect(decoded.tree?.children?.count == 2)
        #expect(decoded.note == "Encoded as Base64 — decoded to structured data (JSON)")
    }

    @Test("A JWT stored as a JSON string literal unwraps")
    func jsonStringWrappedJWT() throws {
        let jwt = Self.makeJWT(payload: #"{"exp":\#(Self.nowSeconds + 3600)}"#)
        let decoded = try #require(LeafDecoder.decode("\"\(jwt)\""))

        #expect(decoded.kinds == [.json, .jwt])
        #expect(decoded.chip == .valid)
        #expect(decoded.note == "Saved as JSON text — contains a login token (JWT)")
    }

    // MARK: Nested tokens

    @Test("A token buried inside a value surfaces its status")
    func nestedTokenStatusIsFound() throws {
        let expired = Self.makeJWT(payload: #"{"exp":\#(Self.nowSeconds - 10)}"#)
        let record = StorageRecord.make(
            key: "config",
            value: ["token": expired, "layoutId": "home"] as [String: Any],
            path: "config"
        )

        #expect(LeafDecoder.nestedJWTStatus(in: record) == .expired)
    }

    @Test("The worst status wins when tokens disagree")
    func worstNestedStatusWins() throws {
        let now = Self.nowSeconds
        let record = StorageRecord.make(
            key: "config",
            value: [
                "good": Self.makeJWT(payload: #"{"exp":\#(now + 3600)}"#),
                "stale": Self.makeJWT(payload: #"{"exp":\#(now - 3600)}"#),
            ] as [String: Any],
            path: "config"
        )

        #expect(LeafDecoder.nestedJWTStatus(in: record) == .expired)
    }

    @Test("A value with no token inside reports no status")
    func noNestedTokenReportsNil() {
        let record = StorageRecord.make(
            key: "config",
            value: ["layoutId": "home", "retries": 3] as [String: Any],
            path: "config"
        )

        #expect(LeafDecoder.nestedJWTStatus(in: record) == nil)
    }

    @Test("A value past the size cap is left raw, however decodable")
    func hugeValueIsNotDecoded() {
        let filler = String(repeating: "x", count: LeafDecoder.maxDecodableLength)
        #expect(LeafDecoder.decode(#"{"a":"\#(filler)"}"#) == nil)
    }

    @Test("Surrounding whitespace doesn't hide a value")
    func whitespaceAroundValueStillDecodes() {
        #expect(LeafDecoder.decode("  {\"a\": 1}\n")?.kinds == [.json])
    }
}
