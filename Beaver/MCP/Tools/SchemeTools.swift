//
//  SchemeTools.swift
//  Beaver
//
//  scheme_build: the Scheme Generator tab for agents — build a deep link
//  into a Zapp app, fill the form on screen, copy it, save its QR code.

import Foundation

enum SchemeTools {
    static let all: [MCPTool] = [build]

    static let build: MCPTool = MCPTool(
        name: "scheme_build",
        title: "Build a deep link",
        description: "Use to build a deep link (URL scheme) into a Zapp app, like Beaver's Scheme Generator: open a screen or feed entry (myapp://open?type=movie&id=42), present a feed, web page or layout (myapp://present?…), X-Ray actions like connecting remote assistance to this Beaver (myapp://xray?remoteAssistance=ws://…), reset the device id, or any plugin host; web index.html?… links too. Without scheme it uses the app's own, from the session's storage (applicaster.v2.urlScheme). Returns the URL. show: true puts it in the Scheme Generator form on screen (in the background); copy: true puts it on the clipboard; qrFile saves its QR code as PNG.",
        kind: .change,
        inputSchema: ToolSchema.object(properties),
        run: run
    )

    /// Each template and what it does (the form shows the same text),
    /// then how it's picked when omitted.
    private static let templateHelp: String = {
        let each = SchemeLink.Template.allCases.map { "\($0.rawValue): \($0.summary)" }
        return each.joined(separator: " ")
            + " Default screen-type. Omitted: follows the keys you pass (linkUrl → web-page, layoutId → layout, xray keys → xray, host → custom)."
    }()

    /// Typed on its own: as one expression with the tool the type checker
    /// times out (Xcode 26.2 on CI).
    private static let properties: [String: JSON] = [
            "mode": ToolSchema.string("mobile (myapp://…, default) or web (index.html?…: open's params on Vizio, layout on every web platform).",
                                      oneOf: SchemeLink.Mode.allCases.map(\.rawValue)),
            "template": ToolSchema.string(templateHelp, oneOf: SchemeLink.Template.allCases.map(\.rawValue)),
            "scheme": ToolSchema.string("Mobile: the app's URL scheme without ://. Omitted: the app's own, read from the session's storage; myapp when it isn't there."),
            "sessionId": ToolSchema.integer("Session whose storage gives the scheme. Omitted: the live session (with several devices, the default device's, else the viewed one if live, else the most recently active), else the viewed one, else the most recent."),
            "baseUrl": ToolSchema.string("Web: the web app's index.html URL."),
            "screenType": ToolSchema.string("screen-type: the content type, mapped to its screen, e.g. movie."),
            "id": ToolSchema.string("screen-type: id. feed-content: the entry id. present: entry_id."),
            "feedUrl": ToolSchema.string("feed-content: feed_locator. present: the feed URL, sent base64 as data_source."),
            "position": ToolSchema.integer("feed-content: the entry's position, counted from 1, used when there is no id."),
            "screenId": ToolSchema.string("direct-screen, present and web-page: screen_id, e.g. MOVIE_SCREEN."),
            "resumeTime": ToolSchema.string("present with id: where playback starts, in seconds."),
            "pushScreen": ToolSchema.boolean("present and web-page: push the screen instead of replacing the current one (isInternalLink)."),
            "linkUrl": ToolSchema.string("web-page: the page's URL (link_url)."),
            "contentType": ToolSchema.string("web-page: the entry type (content_type); the app's default is link."),
            "showNavBar": ToolSchema.boolean("web-page: show the navigation bar (show_nav_bar)."),
            "layoutId": ToolSchema.string("layout: the rivers configuration (layout) id to switch to (rivers_configuration_id)."),
            "xrayAction": ToolSchema.string("xray: logger (open the logger view, default), connect (remote assistance to remoteAssistance), pin (pinCode), share-log, export-logs, export-storages, enable-websocket.",
                                            oneOf: SchemeLink.XrayAction.allCases.map(\.rawValue)),
            "remoteAssistance": ToolSchema.string("xray connect: a ws:// URL, a host or a PIN. Omitted: this Beaver's own ws:// address, so the device connects here. Works in debug and TestFlight builds; release builds need pinCode."),
            "pinCode": ToolSchema.integer("xray pin: the remote assistance PIN."),
            "fileLogLevel": ToolSchema.string("xray: the app's file log level.", oneOf: SchemeLink.logLevels),
            "shortcutEnabled": ToolSchema.boolean("xray: the X-Ray shortcut. Kept only with showXrayFloatingButton."),
            "showXrayFloatingButton": ToolSchema.boolean("xray: the X-Ray floating button; also saves fileLogLevel and shortcutEnabled."),
            "mcpServerEnabled": ToolSchema.boolean("xray: the app's own MCP server."),
            "host": ToolSchema.string("custom: the host, e.g. a plugin's, or plugin with params {pluginIdentifier: …}."),
            "params": .object(["description": .string("More query parameters, {key: value} or \"key=value&key2=value2\". open passes unknown ones to the screen as entry fields.")]),
            "state": ToolSchema.string("Open templates: the player's initial state, fullscreen (the app's default), inline or none.", oneOf: ["fullscreen", "inline", "none"]),
            "title": ToolSchema.string("Open templates: a title, passed to the screen as an entry field."),
            "show": ToolSchema.boolean("Edit the Scheme Generator form on screen and switch to its tab: the keys you pass change the form, the rest stays. Nothing takes focus. Default false: build a fresh link, the window stays as it is."),
            "reset": ToolSchema.boolean("With show: start from an empty form instead of the one on screen."),
            "reveal": ToolSchema.boolean("Like show, and bring Beaver forward. Only when the user asks to see it."),
            "copy": ToolSchema.boolean("Put the URL on the user's clipboard, like the Copy button. Only when the user asks for it: it replaces what they copied."),
            "qrFile": ToolSchema.string("Save the link's QR code as PNG here; absolute or starting with ~."),
            "overwrite": ToolSchema.boolean("Replace qrFile if it exists. Default false."),
    ]

    @Sendable static func run(_ args: ToolArguments, _ ctx: ToolContext) async throws -> ToolResult {
        let reveal = try args.bool("reveal") ?? false
        let show = try (args.bool("show") ?? false) || reveal
        let reset = try args.bool("reset") ?? false
        let copy = try args.bool("copy") ?? false
        let host = await ctx.ui.snapshot()
        var link = show && !reset ? host.ui.scheme : SchemeLink()
        var notes: [String] = []

        if let raw = try args.string("mode") { link.mode = try mode(raw) }
        if let raw = try args.string("template") {
            link.template = try template(raw)
        } else if let inferred = inferredTemplate(args) {
            link.template = inferred
        }
        guard SchemeLink.Template.available(in: link.mode).contains(link.template) else {
            throw ToolError("\(link.template.rawValue) works in mobile mode only; web links take screen-type, feed-content, direct-screen or layout. Example: scheme_build(mode: \"mobile\", template: \"\(link.template.rawValue)\").")
        }

        var schemeFrom: Int64?
        if let raw = try args.string("scheme") {
            let scheme = SchemeLink.clean(raw)
            guard !scheme.isEmpty else {
                throw ToolError("scheme is empty. Example: scheme_build(scheme: \"myapp\", screenType: \"movie\").")
            }
            link.scheme = scheme
        } else if link.mode == .mobile {
            // The app's own scheme. A given sessionId must exist; without
            // one, no sessions at all just means no scheme to read.
            let session = args["sessionId"] != nil ? try await ctx.resolveSession(args)
                : try? await ctx.resolveSession(args)
            if let session {
                let schemes = try await SchemeLink.appSchemes(store: ctx.store, sessionId: session.id)
                if let schemes, let first = schemes.first {
                    link.scheme = first
                    schemeFrom = session.id
                    var note = "scheme \(first) from session \(session.label)'s storage"
                    if schemes.count > 1 { note += " (also \(schemes.dropFirst().joined(separator: ", ")))" }
                    notes.append(note)
                } else if link.scheme == SchemeLink().scheme {
                    let why = schemes == nil ? "has no storage yet (storage_snapshot() asks a connected app)"
                        : "storage has no applicaster.v2.urlScheme"
                    notes.append("myapp is a placeholder: session \(session.label) \(why), pass scheme")
                }
            } else if link.scheme == SchemeLink().scheme {
                notes.append("myapp is a placeholder: no session to read the app's scheme from, pass scheme")
            }
        }

        if let v = try args.string("baseUrl") { link.baseURL = v.trimmingCharacters(in: .whitespaces) }
        if let v = try args.string("screenType") { link.screenType = v }
        if let v = try args.string("id") { link.id = v }
        if let v = try args.string("feedUrl") ?? args.string("feedLocator") { link.feedURL = v }
        if let v = try args.string("screenId") { link.screenId = v }
        if let v = try args.string("title") { link.title = v }
        if let raw = try args.string("position") { link.position = try number(raw, "position", example: "position: 1") }
        if let raw = try args.string("resumeTime") { link.resumeTime = try number(raw, "resumeTime", example: "resumeTime: 120") }
        if let v = try args.bool("pushScreen") ?? args.bool("isInternalLink") { link.pushScreen = v }
        if let raw = try args.string("state") { link.state = try state(raw) }
        if let v = try args.string("linkUrl") { link.linkURL = v.trimmingCharacters(in: .whitespaces) }
        if let v = try args.string("contentType") { link.contentType = v }
        if let v = try args.bool("showNavBar") { link.showNavBar = v }
        if let v = try args.string("layoutId") ?? args.string("riversConfigurationId") { link.layoutId = v.trimmingCharacters(in: .whitespaces) }
        if let v = try args.string("host") { link.host = SchemeLink.clean(v) }
        if let v = try params(args) { link.extras = v }

        // X-Ray.
        if let raw = try args.string("xrayAction") { link.xrayAction = try xrayAction(raw) }
        if let raw = try args.string("pinCode") {
            let pin = try number(raw, "pinCode", example: "pinCode: 1234")
            guard Int(pin) ?? 0 > 0 else { throw ToolError("pinCode must be above 0. Example: scheme_build(template: \"xray\", pinCode: 1234).") }
            link.xrayAction = .pin
            link.xrayValue = pin
        }
        if let v = try args.string("remoteAssistance") {
            link.xrayAction = .connect
            link.xrayValue = v.trimmingCharacters(in: .whitespaces)
        }
        if let raw = try args.string("fileLogLevel") {
            let level = raw.lowercased()
            guard SchemeLink.logLevels.contains(level) else {
                throw ToolError("Unknown fileLogLevel \"\(raw)\". Use \(SchemeLink.logLevels.joined(separator: ", ")). Example: scheme_build(template: \"xray\", fileLogLevel: \"debug\", showXrayFloatingButton: true).")
            }
            link.fileLogLevel = level
        }
        if let v = try args.bool("shortcutEnabled") { link.shortcutEnabled = v }
        if let v = try args.bool("showXrayFloatingButton") ?? args.bool("showXrayFloatingButtonEnabled") { link.floatingButton = v }
        if let v = try args.bool("mcpServerEnabled") { link.mcpServer = v }

        // What the app needs, from reading it (D74).
        switch link.effectiveTemplate {
        case .screenType, .feedContent, .directScreen:
            if link.mode == .mobile, link.screenType.isEmpty, link.feedURL.isEmpty, link.screenId.isEmpty {
                notes.append("open needs type, screen_id or feed_locator: the app ignores it as is")
            }
            if link.effectiveTemplate == .feedContent, !link.id.isEmpty, !link.position.isEmpty {
                notes.append("position ignored: id wins")
            }
        case .present:
            if !link.id.isEmpty, link.feedURL.isEmpty { notes.append("entry id needs feedUrl: the app finds the entry in that feed") }
            if link.feedURL.isEmpty, link.screenId.isEmpty { notes.append("present needs feedUrl or screenId") }
        case .webPage:
            if link.linkURL.isEmpty {
                throw ToolError("web-page needs linkUrl. Example: scheme_build(template: \"web-page\", linkUrl: \"https://example.com/help\").")
            }
        case .layout:
            if link.layoutId.isEmpty {
                throw ToolError("layout needs layoutId, the rivers configuration id. Example: scheme_build(template: \"layout\", layoutId: \"1896fce8-2197-4867-adf5-c7e74c5b8108\").")
            }
        case .xray:
            if link.xrayAction == .connect, link.xrayValue.isEmpty {
                guard let beaver = host.deviceURL else {
                    throw ToolError("Beaver has no network address to connect to. Pass remoteAssistance. Example: scheme_build(template: \"xray\", remoteAssistance: \"ws://192.168.1.5:9080\").")
                }
                link.xrayValue = beaver
                notes.append("connects to this Beaver, \(beaver)")
            }
            if link.xrayAction == .pin, link.xrayValue.isEmpty {
                throw ToolError("xray pin needs pinCode. Example: scheme_build(template: \"xray\", pinCode: 1234).")
            }
            if link.xrayAction == .connect { notes.append("remoteAssistance works in debug and TestFlight builds; release builds need pinCode") }
            if (link.fileLogLevel != nil || link.shortcutEnabled != nil), link.floatingButton == nil {
                notes.append("the app keeps fileLogLevel and shortcutEnabled only with showXrayFloatingButton")
            }
        case .resetUUID:
            notes.append("the app asks before it makes a new device id and reloads")
        case .externalAccount:
            break
        case .custom:
            if link.host.isEmpty {
                throw ToolError("custom needs host. Example: scheme_build(template: \"custom\", host: \"plugin\", params: {pluginIdentifier: \"quick-brick-opta-stats\", action: \"show\"}).")
            }
        }

        let url = link.url
        var qrPath: String?
        if let path = try args.string("qrFile") {
            let file = try ToolInput.fileURL(path)
            if FileManager.default.fileExists(atPath: file.path), try args.bool("overwrite") != true {
                throw ToolError("\(file.path) already exists. Pass overwrite: true to replace it. Example: scheme_build(qrFile: \"\(path)\", overwrite: true).")
            }
            guard let png = SchemeLink.qrPNG(url) else {
                throw ToolError("Couldn't make a QR code for this link; it may be too long. Try a shorter feedUrl.")
            }
            do { try png.write(to: file, options: .atomic) } catch {
                throw ToolError("Couldn't write \(file.path): \(error.localizedDescription). Example: scheme_build(qrFile: \"~/Downloads/link.png\").")
            }
            qrPath = file.path
        }

        if show { await ctx.ui.show(UIChange(tab: .schemes, scheme: link, reveal: reveal)) }
        if copy { await ctx.ui.copyToClipboard(url) }

        var structured = json(link)
        if case .object(var o) = structured {
            o["qrFile"] = JSON(qrPath)
            o["shown"] = .bool(show)
            o["copied"] = .bool(copy)
            o["schemeFromSessionId"] = JSON(schemeFrom)
            structured = .object(o)
        }
        // Built step by step: CI's compiler times out on it as one expression.
        var summary: String
        let next: [String]
        if reveal {
            summary = "Brought Beaver forward on the Scheme Generator: "
            next = ["ui_state() to check what the user sees"]
        } else if show {
            summary = "Filled the Scheme Generator in the background, nothing took focus: "
            next = ["scheme_build(reveal: true) when the user asks to see it"]
        } else {
            summary = "Link: "
            next = ["scheme_build(show: true, …) to put it in the Scheme Generator for the user",
                    "scheme_build(qrFile: \"~/Downloads/link.png\", …) for a QR code to scan"]
        }
        summary += url
        if !notes.isEmpty { summary += " (\(notes.joined(separator: "; ")))" }
        if copy { summary += ". Copied to the clipboard" }
        if let qrPath { summary += ". QR code saved to \(qrPath)" }
        let body = fields(link).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return ToolResult(summary: summary, body: body, structured: structured, next: next, sessionId: schemeFrom)
    }

    // MARK: - Inputs

    private static func key(_ raw: String) -> String {
        raw.lowercased().filter { !" -_".contains($0) }
    }

    static func mode(_ raw: String) throws -> SchemeLink.Mode {
        switch key(raw) {
        case "mobile", "app", "ios", "android", "tv": return .mobile
        case "web", "browser": return .web
        default: throw ToolError("Unknown mode \"\(raw)\". Use mobile or web. Example: scheme_build(mode: \"web\", baseUrl: \"https://app.example.com/index.html\").")
        }
    }

    static func template(_ raw: String) throws -> SchemeLink.Template {
        switch key(raw) {
        case "screentype", "type", "open": return .screenType
        case "feedcontent", "feed", "feedlocator": return .feedContent
        case "directscreen", "screen", "screenid": return .directScreen
        case "present": return .present
        case "webpage", "web", "link", "linkurl", "page": return .webPage
        case "layout", "riversconfiguration", "riversconfigurationid": return .layout
        case "xray", "logger": return .xray
        case "resetuuid", "generatenewuuid", "uuid", "resetdeviceid": return .resetUUID
        case "externalaccount", "externallinkaccount": return .externalAccount
        case "custom", "customhost", "host", "plugin": return .custom
        default:
            throw ToolError("Unknown template \"\(raw)\". Use \(SchemeLink.Template.allCases.map(\.rawValue).joined(separator: ", ")). Example: scheme_build(template: \"direct-screen\", screenId: \"MOVIE_SCREEN\").")
        }
    }

    /// The template the keys point at, when they point at one.
    static func inferredTemplate(_ args: ToolArguments) -> SchemeLink.Template? {
        if args["linkUrl"] != nil { return .webPage }
        if args["layoutId"] != nil || args["riversConfigurationId"] != nil { return .layout }
        let xrayKeys = ["xrayAction", "remoteAssistance", "pinCode", "fileLogLevel", "shortcutEnabled",
                        "showXrayFloatingButton", "showXrayFloatingButtonEnabled", "mcpServerEnabled"]
        if xrayKeys.contains(where: { args[$0] != nil }) { return .xray }
        if args["host"] != nil { return .custom }
        return nil
    }

    static func xrayAction(_ raw: String) throws -> SchemeLink.XrayAction {
        let k = key(raw)
        if let a = SchemeLink.XrayAction.allCases.first(where: { key($0.rawValue) == k }) { return a }
        switch k {
        case "remoteassistance", "connectbeaver": return .connect
        case "pincode": return .pin
        default:
            throw ToolError("Unknown xrayAction \"\(raw)\". Use \(SchemeLink.XrayAction.allCases.map(\.rawValue).joined(separator: ", ")). Example: scheme_build(template: \"xray\", xrayAction: \"connect\").")
        }
    }

    static func state(_ raw: String) throws -> SchemeLink.ScreenState? {
        let k = key(raw)
        if k.isEmpty || k == "none" { return nil }
        guard let s = SchemeLink.ScreenState(rawValue: k) else {
            throw ToolError("Unknown state \"\(raw)\". Use fullscreen, inline or none. Example: scheme_build(screenType: \"movie\", state: \"fullscreen\").")
        }
        return s
    }

    /// A whole number from 0, or empty to clear it.
    static func number(_ raw: String, _ name: String, example: String) throws -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard n.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ToolError("\(name) must be a whole number. Example: scheme_build(\(example)).")
        }
        return n
    }

    /// `params` as `key=value` lines: an object or a query string.
    static func params(_ args: ToolArguments) throws -> String? {
        guard let json = args["params"] else { return nil }
        if let s = json.string { return s }
        guard let object = json.object else {
            throw ToolError("params must be an object or \"key=value&…\". Example: scheme_build(template: \"custom\", host: \"plugin\", params: {pluginIdentifier: \"my-plugin\"}).")
        }
        return try object.keys.sorted().map { key in
            let v = try ToolArguments(object).string(key) ?? ""
            return "\(key)=\(v)"
        }.joined(separator: "\n")
    }

    // MARK: - Output

    /// The fields that go into the link, in order.
    static func fields(_ link: SchemeLink) -> [(String, String)] {
        let template = link.effectiveTemplate
        var f: [(String, String)] = [("mode", link.mode.rawValue), ("template", template.rawValue), ("does", template.summary)]
        f.append(link.mode == .mobile ? ("scheme", link.scheme) : ("baseUrl", link.baseURL))
        func bool(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "" }
        let used: [(String, String)] = switch template {
        case .screenType: [("screenType", link.screenType), ("id", link.id)]
        case .feedContent: [("feedUrl", link.feedURL), ("id", link.id), ("position", link.position)]
        case .directScreen: [("screenId", link.screenId)]
        case .present: [("feedUrl", link.feedURL), ("screenId", link.screenId), ("id", link.id),
                        ("resumeTime", link.id.isEmpty ? "" : link.resumeTime), ("pushScreen", link.pushScreen ? "true" : "")]
        case .webPage: [("linkUrl", link.linkURL), ("contentType", link.contentType), ("showNavBar", link.showNavBar ? "true" : ""),
                        ("screenId", link.screenId), ("pushScreen", link.pushScreen ? "true" : "")]
        case .layout: [("layoutId", link.layoutId)]
        case .xray: [("xrayAction", link.xrayAction.rawValue),
                     ("remoteAssistance", link.xrayAction == .connect ? link.xrayValue : ""),
                     ("pinCode", link.xrayAction == .pin ? link.xrayValue : ""),
                     ("fileLogLevel", link.fileLogLevel ?? ""), ("shortcutEnabled", bool(link.shortcutEnabled)),
                     ("showXrayFloatingButton", bool(link.floatingButton)), ("mcpServerEnabled", bool(link.mcpServer))]
        case .resetUUID, .externalAccount: []
        case .custom: [("host", link.host)]
        }
        f += used.filter { !$0.1.isEmpty }
        if template.host == "open" {
            if let s = link.state { f.append(("state", s.rawValue)) }
            if !link.title.isEmpty { f.append(("title", link.title)) }
        }
        let extras = link.extraParams.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        if !extras.isEmpty { f.append(("params", extras)) }
        f.append(("url", link.url))
        return f
    }

    static func json(_ link: SchemeLink) -> JSON {
        .object(Dictionary(fields(link).map { ($0.0, JSON.string($0.1)) }, uniquingKeysWith: { a, _ in a }))
    }
}
