//
//  SchemeLink.swift
//  Beaver
//
//  The Scheme Generator's form: a deep link into a Zapp app, built the
//  way zapp-support's Scheme Generator builds it
//  (src/components/xraySchemeGenerator.ts), so both tools give the same
//  URL for the same fields.

import CoreImage
import Foundation

public struct SchemeLink: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable {
        /// `myapp://open?…`
        case mobile
        /// `https://…/index.html?…`
        case web
    }

    public enum Template: String, Sendable, CaseIterable {
        case screenType = "screen-type"
        case feedContent = "feed-content"
        case directScreen = "direct-screen"
        /// Mobile only: `myapp://present?data_source=…`.
        case present

        public var title: String {
            switch self {
            case .screenType: "Screen Type"
            case .feedContent: "Feed Content"
            case .directScreen: "Direct Screen"
            case .present: "Present"
            }
        }

        public static func available(in mode: Mode) -> [Template] {
            mode == .mobile ? allCases : allCases.filter { $0 != .present }
        }
    }

    public enum ScreenState: String, Sendable, CaseIterable {
        case fullscreen, inline
    }

    public var mode: Mode = .mobile
    public var template: Template = .screenType
    /// The app's URL scheme, without `://`.
    public var scheme = "myapp"
    /// Web mode: the web app's index.html.
    public var baseURL = "https://app.example.com/index.html"

    // One set of fields for every template: the template picks which go
    // into the URL, and switching keeps what was typed.
    /// Screen Type: `type`.
    public var screenType = ""
    /// Screen Type and Feed Content: `id`. Present: `entry_id`.
    public var id = ""
    /// Feed Content: `feed_locator`. Present: base64 `data_source`.
    public var feedURL = ""
    /// Feed Content, when there is no `id`: `position`.
    public var position = ""
    /// Direct Screen and Present: `screen_id`.
    public var screenId = ""

    public var state: ScreenState?
    public var title = ""

    public init() {}

    /// Web has no Present; the form falls back to Screen Type.
    public var effectiveTemplate: Template {
        mode == .web && template == .present ? .screenType : template
    }

    public var url: String {
        var params: [(String, String)] = []
        func add(_ key: String, _ value: String) { if !value.isEmpty { params.append((key, value)) } }

        switch effectiveTemplate {
        case .present:
            params.append(("data_source", Data(feedURL.utf8).base64EncodedString()))
            add("screen_id", screenId)
            add("entry_id", id.allSatisfy(Self.isURLSafe) ? id : Data(id.utf8).base64EncodedString())
            return "\(scheme)://present?\(Self.query(params))"
        case .screenType:
            add("type", screenType)
            add("id", id)
        case .feedContent:
            add("feed_locator", feedURL)
            if id.isEmpty { add("position", position) } else { add("id", id) }
        case .directScreen:
            add("screen_id", screenId)
        }
        add("state", state?.rawValue ?? "")
        add("title", title)

        let qs = Self.query(params)
        let base = mode == .mobile ? "\(scheme)://open" : baseURL
        return qs.isEmpty ? base : "\(base)?\(qs)"
    }

    // MARK: - Encoding, as the browser's URLSearchParams does it

    private static func isURLSafe(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "-_.~".contains(c))
    }

    static func query(_ params: [(String, String)]) -> String {
        params.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&")
    }

    /// application/x-www-form-urlencoded: space is `+`; everything but
    /// letters, digits and `*-._` is percent-encoded.
    static func formEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x20: out += "+"
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F:
                out.unicodeScalars.append(UnicodeScalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - QR code

    /// A crisp QR code for `text`, `scale` pixels per module, with the
    /// 4-module white margin scanners need.
    public static func qrImage(_ text: String, scale: CGFloat = 10) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let margin = code.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
        return code.composited(over: CIImage(color: .white).cropped(to: margin))
            .transformed(by: CGAffineTransform(translationX: -margin.minX, y: -margin.minY))
    }

    /// The QR code as PNG data.
    public static func qrPNG(_ text: String) -> Data? {
        guard let image = qrImage(text) else { return nil }
        return CIContext().pngRepresentation(of: image, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
