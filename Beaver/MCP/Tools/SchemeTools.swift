//
//  SchemeTools.swift
//  Beaver
//
//  scheme_build: the Scheme Generator tab for agents — build a deep link
//  into a Zapp app, fill the form on screen, save its QR code.

import Foundation

enum SchemeTools {
    static let all = [build]

    static let build = MCPTool(
        name: "scheme_build",
        title: "Build a deep link",
        description: "Use to build a deep link (URL scheme) into a Zapp app, like Beaver's Scheme Generator: mobile myapp://open?type=movie&id=42, myapp://present?data_source=…, or a web index.html?… link. Returns the URL. show: true puts it in the Scheme Generator form on screen (in the background); copy: true puts it on the clipboard; qrFile saves its QR code as PNG.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "mode": ToolSchema.string("mobile (myapp://…, default) or web (index.html?…).", oneOf: SchemeLink.Mode.allCases.map(\.rawValue)),
            "template": ToolSchema.string("screen-type (type + id, default), feed-content (feedUrl + id or position), direct-screen (screenId) or present (mobile only: feedUrl + screenId + id).",
                                          oneOf: SchemeLink.Template.allCases.map(\.rawValue)),
            "scheme": ToolSchema.string("Mobile: the app's URL scheme without ://. Default myapp."),
            "baseUrl": ToolSchema.string("Web: the web app's index.html URL."),
            "screenType": ToolSchema.string("screen-type: the screen type, e.g. movie."),
            "id": ToolSchema.string("screen-type: id. feed-content: the entry id. present: entry_id (base64 when not URL-safe)."),
            "feedUrl": ToolSchema.string("feed-content: feed_locator. present: the feed URL, sent base64 as data_source."),
            "position": ToolSchema.integer("feed-content: the entry's position, used when there is no id."),
            "screenId": ToolSchema.string("direct-screen and present: screen_id, e.g. MOVIE_SCREEN."),
            "state": ToolSchema.string("Optional: fullscreen, inline or none.", oneOf: ["fullscreen", "inline", "none"]),
            "title": ToolSchema.string("Optional screen title."),
            "show": ToolSchema.boolean("Edit the Scheme Generator form on screen and switch to its tab: the keys you pass change the form, the rest stays. Nothing takes focus. Default false: build a fresh link, the window stays as it is."),
            "reset": ToolSchema.boolean("With show: start from an empty form instead of the one on screen."),
            "reveal": ToolSchema.boolean("Like show, and bring Beaver forward. Only when the user asks to see it."),
            "copy": ToolSchema.boolean("Put the URL on the user's clipboard, like the Copy button. Only when the user asks for it: it replaces what they copied."),
            "qrFile": ToolSchema.string("Save the link's QR code as PNG here; absolute or starting with ~."),
            "overwrite": ToolSchema.boolean("Replace qrFile if it exists. Default false."),
        ])
    ) { args, ctx in
        let reveal = try args.bool("reveal") ?? false
        let show = try (args.bool("show") ?? false) || reveal
        let reset = try args.bool("reset") ?? false
        let copy = try args.bool("copy") ?? false
        var link = show && !reset ? await ctx.ui.snapshot().ui.scheme : SchemeLink()
        var notes: [String] = []

        if let raw = try args.string("mode") { link.mode = try mode(raw) }
        if let raw = try args.string("template") { link.template = try template(raw) }
        if link.mode == .web && link.template == .present {
            throw ToolError("present works in mobile mode only. Example: scheme_build(mode: \"mobile\", template: \"present\", feedUrl: \"https://feeds.example.com/movies.json\", screenId: \"MOVIE_SCREEN\").")
        }
        if let raw = try args.string("scheme") {
            let scheme = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            guard !scheme.isEmpty else {
                throw ToolError("scheme is empty. Example: scheme_build(scheme: \"myapp\", screenType: \"movie\").")
            }
            link.scheme = scheme
        }
        if let v = try args.string("baseUrl") { link.baseURL = v.trimmingCharacters(in: .whitespaces) }
        if let v = try args.string("screenType") { link.screenType = v }
        if let v = try args.string("id") { link.id = v }
        if let v = try args.string("feedUrl") ?? args.string("feedLocator") { link.feedURL = v }
        if let v = try args.string("screenId") { link.screenId = v }
        if let v = try args.string("title") { link.title = v }
        if let raw = try args.string("position") {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard p.isEmpty || (p.allSatisfy(\.isNumber) && p.allSatisfy(\.isASCII)) else {
                throw ToolError("position must be a whole number from 0. Example: scheme_build(template: \"feed-content\", feedUrl: \"https://feeds.example.com/movies.json\", position: 0).")
            }
            link.position = p
        }
        if let raw = try args.string("state") { link.state = try state(raw) }

        if link.effectiveTemplate == .feedContent, !link.id.isEmpty, !link.position.isEmpty {
            notes.append("position ignored: id wins")
        }
        if link.effectiveTemplate == .present, link.feedURL.isEmpty {
            notes.append("present without feedUrl sends an empty data_source")
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
            structured = .object(o)
        }
        let lead = reveal ? "Brought Beaver forward on the Scheme Generator: "
            : show ? "Filled the Scheme Generator in the background, nothing took focus: " : "Link: "
        return ToolResult(
            summary: lead + url + (notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")")
                + (copy ? ". Copied to the clipboard" : "")
                + (qrPath.map { ". QR code saved to \($0)" } ?? ""),
            body: fields(link).map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
            structured: structured,
            next: show
                ? (reveal ? ["ui_state() to check what the user sees"] : ["scheme_build(reveal: true) when the user asks to see it"])
                : ["scheme_build(show: true, …) to put it in the Scheme Generator for the user",
                   "scheme_build(qrFile: \"~/Downloads/link.png\", …) for a QR code to scan"]
        )
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
        case "screentype", "type": return .screenType
        case "feedcontent", "feed", "feedlocator": return .feedContent
        case "directscreen", "screen", "screenid": return .directScreen
        case "present": return .present
        default: throw ToolError("Unknown template \"\(raw)\". Use screen-type, feed-content, direct-screen or present. Example: scheme_build(template: \"direct-screen\", screenId: \"MOVIE_SCREEN\").")
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

    // MARK: - Output

    /// The fields that go into the link, in order.
    static func fields(_ link: SchemeLink) -> [(String, String)] {
        var f: [(String, String)] = [("mode", link.mode.rawValue), ("template", link.effectiveTemplate.rawValue)]
        f.append(link.mode == .mobile ? ("scheme", link.scheme) : ("baseUrl", link.baseURL))
        let used: [(String, String)] = switch link.effectiveTemplate {
        case .screenType: [("screenType", link.screenType), ("id", link.id)]
        case .feedContent: [("feedUrl", link.feedURL), ("id", link.id), ("position", link.position)]
        case .directScreen: [("screenId", link.screenId)]
        case .present: [("feedUrl", link.feedURL), ("screenId", link.screenId), ("id", link.id)]
        }
        f += used.filter { !$0.1.isEmpty }
        if link.effectiveTemplate != .present {
            if let s = link.state { f.append(("state", s.rawValue)) }
            if !link.title.isEmpty { f.append(("title", link.title)) }
        }
        f.append(("url", link.url))
        return f
    }

    static func json(_ link: SchemeLink) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: fields(link).map { ($0.0, JSON.string($0.1)) }))
    }
}
