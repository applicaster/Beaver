//
//  SchemeLink.swift
//  Beaver
//
//  The Scheme Generator's form: a deep link into a Zapp app. Covers what
//  the apps handle (D74): QuickBrick's `open` and `present` (DeepLinking/
//  URLSchemeHandler), the native hosts in Zapp-Frameworks'
//  UrlSchemeHandler (`xray`, `generateNewUUID`, `externalLinkAccount`),
//  and any plugin host. `open` links are built as zapp-support's Scheme
//  Generator builds them (xraySchemeGenerator.ts), so both give the same
//  URL for the same fields.

import CoreImage
import Foundation

public struct SchemeLink: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable {
        /// `myapp://open?…`
        case mobile
        /// `https://…/index.html?…`: `open`'s params on Vizio, a layout
        /// switch on every web platform.
        case web
    }

    public enum Template: String, Sendable, CaseIterable {
        case screenType = "screen-type"
        case feedContent = "feed-content"
        case directScreen = "direct-screen"
        /// `present?data_source=<base64>&screen_id&entry_id&resumeTime`.
        case present
        /// `present?link_url=…`: a web page in the app.
        case webPage = "web-page"
        /// `present?rivers_configuration_id=…`: another layout.
        case layout
        /// Native, iOS: X-Ray's logger, remote assistance, log export.
        case xray
        /// Native: `generateNewUUID`, asks, then a new device id and reload.
        case resetUUID = "reset-uuid"
        /// Native, iOS: `externalLinkAccount`.
        case externalAccount = "external-account"
        /// Any other host, e.g. a plugin's, or native `plugin?pluginIdentifier=…`.
        case custom

        public var title: String {
            switch self {
            case .screenType: "Screen Type"
            case .feedContent: "Feed Content"
            case .directScreen: "Direct Screen"
            case .present: "Present"
            case .webPage: "Web Page"
            case .layout: "Layout"
            case .xray: "X-Ray"
            case .resetUUID: "Reset Device ID"
            case .externalAccount: "External Account"
            case .custom: "Custom Host"
            }
        }

        /// What a link of this kind does in the app, for the form and agents.
        public var summary: String {
            switch self {
            case .screenType: "Opens the screen the app's layout maps to a content type, e.g. the movie screen; with an ID, for that item."
            case .feedContent: "Loads a feed and opens one of its entries — by ID or position, else the first — on that entry's screen."
            case .directScreen: "Opens a screen of the app's layout by its screen ID."
            case .present: "Shows a feed on a screen, or one entry of it, optionally resuming playback at a time."
            case .webPage: "Opens a web page inside the app, optionally on a given screen and with the navigation bar."
            case .layout: "Reloads the app with another layout (rivers configuration) and goes to its home screen."
            case .xray: "X-Ray, iOS: opens the logger, connects remote assistance (e.g. to this Beaver), shares or exports logs, or changes logger settings."
            case .resetUUID: "Asks the user, then gives the device a new ID and reloads the app."
            case .externalAccount: "Opens the app's external account link (iOS, where in-app payments are allowed)."
            case .custom: "Any other host: a plugin's own, or the native plugin?pluginIdentifier=… — add its parameters below."
            }
        }

        /// The URL's host; `custom` uses `SchemeLink.host`.
        public var host: String {
            switch self {
            case .screenType, .feedContent, .directScreen: "open"
            case .present, .webPage, .layout: "present"
            case .xray: "xray"
            case .resetUUID: "generateNewUUID"
            case .externalAccount: "externalLinkAccount"
            case .custom: ""
            }
        }

        public static func available(in mode: Mode) -> [Template] {
            mode == .mobile ? allCases : [.screenType, .feedContent, .directScreen, .layout]
        }
    }

    public enum ScreenState: String, Sendable, CaseIterable {
        case fullscreen, inline
    }

    /// What an X-Ray link does. Settings go along with any of them.
    public enum XrayAction: String, Sendable, CaseIterable {
        /// Opens the logger view.
        case logger
        /// `remoteAssistance=<ws://… or PIN>`: debug and TestFlight builds only.
        case connect
        /// `pin_code=<PIN>`: remote assistance with a PIN.
        case pin
        case shareLog = "share-log"
        case exportLogs = "export-logs"
        case exportStorages = "export-storages"
        case enableWebSocket = "enable-websocket"

        public var title: String {
            switch self {
            case .logger: "Open logger"
            case .connect: "Connect (remote assistance)"
            case .pin: "Remote assistance PIN"
            case .shareLog: "Email the log"
            case .exportLogs: "Export logs"
            case .exportStorages: "Export storages"
            case .enableWebSocket: "Enable WebSocket"
            }
        }
    }

    public static let logLevels = ["off", "error", "warning", "info", "debug", "verbose"]

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
    /// Feed Content, when there is no `id`: `position`, counted from 1.
    public var position = ""
    /// Direct Screen, Present and Web Page: `screen_id`.
    public var screenId = ""
    /// Present, with an entry: `resumeTime` in seconds.
    public var resumeTime = ""
    /// Present and Web Page: `isInternalLink=true` pushes the screen
    /// instead of replacing the current one.
    public var pushScreen = false
    /// Web Page: `link_url`, `content_type` (the app's default is link),
    /// `show_nav_bar`.
    public var linkURL = ""
    public var contentType = ""
    public var showNavBar = false
    /// Layout: `rivers_configuration_id`.
    public var layoutId = ""
    /// X-Ray.
    public var xrayAction: XrayAction = .logger
    /// X-Ray connect: a `ws://` URL, a host, or a PIN. PIN: the PIN.
    public var xrayValue = ""
    /// X-Ray settings; nil leaves the app's as they are. The first two
    /// are kept only when `floatingButton` is sent too.
    public var fileLogLevel: String?
    public var shortcutEnabled: Bool?
    public var floatingButton: Bool?
    public var mcpServer: Bool?
    /// Custom Host: the host.
    public var host = ""

    /// Open only (the app ignores them elsewhere).
    public var state: ScreenState?
    public var title = ""
    /// More `key=value` pairs, one per line or `&`-separated. `open`
    /// passes unknown ones on to the screen as entry fields.
    public var extras = ""

    public init() {}

    /// A template the mode has no room for falls back to Screen Type.
    public var effectiveTemplate: Template {
        Template.available(in: mode).contains(template) ? template : .screenType
    }

    public var extraParams: [(String, String)] {
        extras.split(whereSeparator: { $0 == "\n" || $0 == "&" }).compactMap { item in
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    public var url: String {
        var params: [(String, String)] = []
        func add(_ key: String, _ value: String) { if !value.isEmpty { params.append((key, value)) } }
        func flag(_ key: String, _ value: Bool?) { if let value { params.append((key, value ? "true" : "false")) } }
        var path = ""

        let template = effectiveTemplate
        switch template {
        case .screenType:
            add("type", screenType)
            add("id", id)
        case .feedContent:
            add("feed_locator", feedURL)
            if id.isEmpty { add("position", position) } else { add("id", id) }
        case .directScreen:
            add("screen_id", screenId)
        case .present:
            // QuickBrick base64-decodes data_source only; entry_id is
            // matched as sent (zapp-support base64s an unsafe one, which
            // then never matches).
            if !feedURL.isEmpty { params.append(("data_source", Data(feedURL.utf8).base64EncodedString())) }
            add("screen_id", screenId)
            add("entry_id", id)
            if !id.isEmpty { add("resumeTime", resumeTime) }
        case .webPage:
            add("link_url", linkURL)
            add("content_type", contentType)
            if showNavBar { params.append(("show_nav_bar", "true")) }
            add("screen_id", screenId)
        case .layout:
            add("rivers_configuration_id", layoutId)
        case .xray:
            switch xrayAction {
            case .logger: break
            case .connect: add("remoteAssistance", xrayValue)
            case .pin: add("pin_code", xrayValue)
            case .shareLog: params.append(("shareLog", "true"))
            case .exportLogs: path = "/exportLogs"
            case .exportStorages: path = "/exportStorages"
            case .enableWebSocket: path = "/enableWebSocket"
            }
            add("fileLogLevel", fileLogLevel ?? "")
            flag("shortcutEnabled", shortcutEnabled)
            flag("showXrayFloatingButtonEnabled", floatingButton)
            flag("mcpServerEnabled", mcpServer)
        case .resetUUID, .externalAccount, .custom:
            break
        }
        if pushScreen, [.present, .webPage].contains(template) { params.append(("isInternalLink", "true")) }
        if template.host == "open" {
            add("state", state?.rawValue ?? "")
            add("title", title)
        }
        params += extraParams

        let qs = Self.query(params)
        let base = mode == .web ? baseURL
            : "\(scheme)://\(template == .custom ? Self.clean(host) : template.host)\(path)"
        return qs.isEmpty ? base : "\(base)?\(qs)"
    }

    // MARK: - The app's own scheme, from its storage

    /// `myapp://` → `myapp`.
    public static func clean(_ scheme: String) -> String {
        scheme.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":/ "))
    }

    /// The URL schemes the app registered, from the SDK's
    /// `applicaster.v2.urlScheme` in the session's latest stored storage
    /// (session layer, then local). Empty when the SDK doesn't send it,
    /// nil when the session has no storage yet.
    public static func appSchemes(store: LogStore, sessionId: Int64) async throws -> [String]? {
        var sawStorage = false
        for layer in [StorageSnapshot.Namespace.session, .local] {
            guard let snap = try await store.latestStorageSnapshot(sessionId: sessionId, namespace: layer) else { continue }
            sawStorage = true
            let schemes = urlSchemes(inSnapshot: snap.dataJSON)
            if !schemes.isEmpty { return schemes }
        }
        return sawStorage ? [] : nil
    }

    /// iOS sends `urlScheme` as a string holding a JSON array
    /// (`"[\"aio\"]"`); a real array or a plain string work too.
    static func urlSchemes(inSnapshot json: String) -> [String] {
        func decoded(_ value: Any?) -> Any? {
            guard let s = value as? String, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
                  o is [Any] || o is [String: Any] else { return value }
            return o
        }
        guard let root = decoded(json) as? [String: Any],
              let v2 = decoded(root["applicaster.v2"]) as? [String: Any] else { return [] }
        let raw = decoded(v2["urlScheme"])
        let list = (raw as? [Any])?.compactMap { $0 as? String } ?? (raw as? String).map { [$0] } ?? []
        return list.map(clean).filter { !$0.isEmpty }
    }

    // MARK: - Encoding, as the browser's URLSearchParams does it

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
