//
//  UITools.swift
//  Beaver
//
//  ui_state and ui_show (design §5.8, §7.1, M12): what Beaver's window
//  shows, read and set by an agent in the background. Only
//  `reveal: true` brings Beaver forward.

import Foundation

enum UITools {
    static let all = [state, show]

    /// What `select` names.
    enum Pick: Equatable {
        case event(Int64), network(Int64), first, last
    }

    // MARK: - ui_state

    static let state = MCPTool(
        name: "ui_state",
        title: "What Beaver shows",
        description: "Use to see what the user is looking at in Beaver: the tab, the session, the log and network filters, the storage layer and search, the selected event or request, and whether Beaver is in front.",
        kind: .read,
        inputSchema: ToolSchema.object([:])
    ) { _, ctx in
        stateResult(await ctx.ui.snapshot())
    }

    // MARK: - ui_show

    static let show = MCPTool(
        name: "ui_show",
        title: "Show in Beaver",
        description: "Use to point the user at something in Beaver's window: a tab, a session, a log or network filter, a storage layer, a selected event or request. It works in the background — nothing takes focus. reveal: true brings Beaver forward; use it only when the user asks to see it.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "tab": ToolSchema.string("logs, network, storages or sessions. Omitted: follows what you set (filter → logs, networkFilter → network, storage → storages).",
                                     oneOf: UITab.allCases.map(\.rawValue)),
            "sessionId": ToolSchema.integer("Session to show. Omitted: the one on screen, else the live one, else the most recent."),
            "filter": ToolSchema.filter,
            "networkFilter": ToolSchema.object([
                "method": ToolSchema.string("One method, e.g. POST."),
                "status": ToolSchema.string("One of errors, 2xx, 3xx, 4xx, 5xx, failed, noStatus, or a code like 401."),
                "host": ToolSchema.string("One host; * globs and fragments work when they match one host."),
                "search": ToolSchema.string("Text in the URL, headers or bodies."),
                "searchIsRegex": ToolSchema.boolean("Treat search as a regular expression."),
            ]),
            "storage": ToolSchema.object([
                "layer": ToolSchema.string("session, local or secure (keychain).", oneOf: ["session", "local", "secure", "keychain"]),
                "search": ToolSchema.string("Discover search over keys and values."),
            ]),
            "select": ["description": "{eventId: 48211}, {networkId: 391}, or \"first\" / \"last\": the first or last row the filter shows."],
            "reveal": ToolSchema.boolean("Bring Beaver forward and focus it. Default false; only when the user asks to see it."),
        ])
    ) { args, ctx in
        try await run(args, ctx, inContext: false)
    }

    /// A person's click on a journal link, and PR 2's toast "Show" and
    /// notification click: `ui_show`'s path, not journaled. What a filter
    /// hides is shown in context rather than refused.
    static func open(_ link: AgentLink, reveal: Bool, _ ctx: ToolContext) async throws -> ToolResult {
        if let name = link.savedFilter {
            guard let saved = try await ctx.store.savedFilters().first(where: { $0.name == name }) else {
                throw ToolError("The saved filter “\(name)” no longer exists.")
            }
            var filter = saved.filter
            filter.hiddenThroughEventId = await ctx.ui.snapshot().ui.logFilter.hiddenThroughEventId
            await ctx.ui.show(UIChange(tab: .logs, logFilter: filter, reveal: reveal))
            return stateResult(await ctx.ui.snapshot())
        }
        var args: [String: JSON] = ["reveal": .bool(reveal)]
        if let id = link.eventId {
            args["select"] = ["eventId": JSON(id)]
        } else if let id = link.networkId {
            args["select"] = ["networkId": JSON(id)]
        } else if let id = link.sessionId {
            args["sessionId"] = JSON(id)
            args["tab"] = "logs"
        }
        return try await run(ToolArguments(args), ctx, inContext: true)
    }

    /// `inContext`: a person clicked. A row hidden by a filter clears that
    /// filter, like the Log feed's Show in Context; for an agent it fails
    /// with the call that would show it.
    static func run(_ args: ToolArguments, _ ctx: ToolContext, inContext: Bool) async throws -> ToolResult {
        let host = await ctx.ui.snapshot()
        let reveal = try args.bool("reveal") ?? false
        let askedTab = try args.string("tab").map(tab)
        let filterGiven = args["filter"] != nil || ToolContext.filterKeys.contains { args[$0] != nil }
        let selection = try pick(args["select"],
                                 tab: askedTab ?? (args["networkFilter"] != nil ? .network : host.ui.tab))
        var change = UIChange(reveal: reveal)
        var notes: [String] = []

        // The session: the selected row's, else the one asked for, else the
        // one on screen, else live / most recent. Looked up only when the
        // call needs one, so ui_show(reveal: true) works with no sessions.
        var sessionId = host.ui.sessionId
        if args["sessionId"] != nil || filterGiven || args["networkFilter"] != nil || selection != nil {
            var asked: Int64?
            if args["sessionId"] != nil { asked = try await ctx.resolveSession(args).id }
            var owner: Int64?
            if case .event(let id) = selection {
                guard let event = try await ctx.store.events(ids: [id]).first else {
                    throw ToolError("No event #\(id). Example: logs_query() lists event ids.")
                }
                owner = event.sessionId
            }
            if case .network(let id) = selection {
                guard let session = try await ctx.store.networkEntrySessionId(id: id) else {
                    throw ToolError("No request #\(id). Example: network_query() lists request ids.")
                }
                owner = session
            }
            if let owner, let asked, owner != asked {
                throw ToolError("That row is in session #\(owner), not #\(asked). Example: ui_show(select: \(example(selection))) opens its session.")
            }
            if let wanted = owner ?? asked {
                sessionId = wanted
            } else if sessionId == nil {
                sessionId = try await ctx.resolveSession(ToolArguments()).id
            }
            // Pin the session in the change itself, not just this snapshot's
            // `sessionId` local: if the person switches session while the
            // store queries below are in flight, `ctx.ui.show(change)` must
            // still land on the session this call resolved, not whatever is
            // on screen by then.
            change.sessionId = sessionId
        }
        let switching = sessionId != host.ui.sessionId

        change.tab = askedTab ?? inferredTab(selection, filterGiven: filterGiven, args)
        let tab = change.tab ?? host.ui.tab

        if filterGiven, let sid = sessionId {
            let resolved = try await ctx.resolveFilter(args, sessionId: sid)
            var filter = resolved.filter
            // `filter: {}` shows every event, the ones the user cleared
            // from view too; any other filter keeps their Clear (⌘K).
            let showsAll = args["filter"]?.object?.isEmpty == true
                && !ToolContext.filterKeys.contains { args[$0] != nil }
            if !showsAll && !switching {
                filter.hiddenThroughEventId = host.ui.logFilter.hiddenThroughEventId
            }
            change.logFilter = filter
            notes += resolved.notes
        }
        if let json = args["networkFilter"], let sid = sessionId {
            let resolved = try await networkFilter(json, sessionId: sid, store: ctx.store)
            change.networkFilter = resolved.filter
            notes += resolved.notes
        }
        if let json = args["storage"] {
            guard let object = json.object else {
                throw ToolError("storage must be an object. Example: ui_show(storage: {layer: \"secure\", search: \"token\"}).")
            }
            let a = ToolArguments(object)
            change.storageLayer = try a.string("layer").map(layer)
            change.storageSearch = try a.string("search")
        }

        // The selection, resolved and checked against what the window will show.
        if let selection, let sid = sessionId {
            let target = host.ui.applying(change)
            switch selection {
            case .event(let id):
                let shown = try await eventShown(id, session: sid, filter: target.logFilter, ctx.store)
                if !shown {
                    guard inContext else { throw hiddenEvent(id, target.logFilter) }
                    change.logFilter = inContextFilter(for: id, target.logFilter)
                }
                change.selectedEventId = id
            case .network(let id):
                if let entry = try await ctx.store.networkEntry(id: id), !target.networkFilter.matches(entry) {
                    guard inContext else {
                        throw ToolError("Request #\(id) is hidden by the network filter (\(describe(target.networkFilter))). Example: ui_show(networkFilter: {}, select: {networkId: \(id)}) clears it.")
                    }
                    change.networkFilter = NetworkFilter()
                }
                change.selectedNetworkId = id
            case .first, .last:
                let last = selection == .last
                switch tab {
                case .logs:
                    let page = try await ctx.store.eventPage(sessionId: sid, filter: target.logFilter,
                                                             limit: 1, newestFirst: last)
                    if let event = page.events.first {
                        change.selectedEventId = event.id
                    } else {
                        notes.append("nothing matches the log filter, so nothing is selected")
                    }
                case .network:
                    let shown = try await ctx.store.networkEntries(sessionId: sid).filter(target.networkFilter.matches)
                    if let entry = last ? shown.last : shown.first {
                        change.selectedNetworkId = entry.id
                    } else {
                        notes.append("nothing matches the network filter, so nothing is selected")
                    }
                case .storages, .sessions:
                    throw ToolError("select \"first\" / \"last\" works on the logs and network tabs. Example: ui_show(tab: \"network\", networkFilter: {status: \"errors\"}, select: \"first\").")
                }
            }
        }

        await ctx.ui.show(change)
        let after = await ctx.ui.snapshot()
        var result = stateResult(after)
        result.summary = (reveal ? "Brought Beaver forward: " : "Changed in the background, nothing took focus: ")
            + view(after.ui) + "."
            + (notes.isEmpty ? "" : " Resolved: " + notes.joined(separator: "; ") + ".")
        result.links = change.selectedEventId.map { [AgentLink(eventId: $0)] }
            ?? change.selectedNetworkId.map { [AgentLink(networkId: $0)] }
            ?? after.ui.sessionId.map { [AgentLink(sessionId: $0)] } ?? []
        result.next = !after.windowOpen ? ["ask the user to click Beaver in the Dock: its window is closed"]
            : reveal ? ["ui_state() to check what the user sees"]
            : ["ui_show(reveal: true) when the user asks to see it"]
        return result
    }

    // MARK: - Inputs

    static func tab(_ raw: String) throws -> UITab {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "logs", "log", "logfeed", "log feed", "log_feed", "feed", "events": return .logs
        case "network", "requests", "request", "net", "http": return .network
        case "storages", "storage": return .storages
        case "sessions", "session": return .sessions
        default:
            throw ToolError("Unknown tab \"\(raw)\". Use logs, network, storages or sessions. Example: ui_show(tab: \"network\").")
        }
    }

    static func layer(_ raw: String) throws -> StorageSnapshot.Namespace {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "session": return .session
        case "local": return .local
        case "secure", "keychain": return .keychain
        default:
            throw ToolError("Unknown layer \"\(raw)\": the Storages tab shows one of session, local or secure. Example: ui_show(storage: {layer: \"secure\"}).")
        }
    }

    /// `{eventId}`, `{networkId}`, `"first"`, `"last"`; a bare id (or
    /// `{id}`) means a row of `tab`.
    static func pick(_ json: JSON?, tab: UITab) throws -> Pick? {
        guard let json else { return nil }
        func row(_ id: Int64) -> Pick { tab == .network ? .network(id) : .event(id) }
        if let s = json.string?.trimmingCharacters(in: .whitespaces).lowercased() {
            if s == "first" { return .first }
            if s == "last" { return .last }
            if let id = Int64(s) { return row(id) }
        }
        if let id = json.int64 { return row(id) }
        if let object = json.object {
            let a = ToolArguments(object)
            if let id = try a.int64("eventId") { return .event(id) }
            if let id = try a.int64("networkId") ?? a.int64("requestId") { return .network(id) }
            if let id = try a.int64("id") { return row(id) }
        }
        throw ToolError("select must be {eventId: …}, {networkId: …}, \"first\" or \"last\". Example: ui_show(filter: {minLevel: \"error\"}, select: \"first\").")
    }

    static func inferredTab(_ selection: Pick?, filterGiven: Bool, _ args: ToolArguments) -> UITab? {
        switch selection {
        case .event: return .logs
        case .network: return .network
        case .first, .last, nil:
            if filterGiven { return .logs }
            if args["networkFilter"] != nil { return .network }
            if args["storage"] != nil { return .storages }
            return nil
        }
    }

    static func example(_ selection: Pick?) -> String {
        switch selection {
        case .event(let id): "{eventId: \(id)}"
        case .network(let id): "{networkId: \(id)}"
        default: "\"first\""
        }
    }

    /// `{method, status, host, search, searchIsRegex}` onto the Network
    /// tab's filter. The tab picks one method, one status and one host, so
    /// a list must hold one value.
    static func networkFilter(_ json: JSON, sessionId: Int64, store: LogStore) async throws -> (filter: NetworkFilter, notes: [String]) {
        guard let object = json.object else {
            throw ToolError("networkFilter must be an object. Example: ui_show(networkFilter: {status: \"errors\"}).")
        }
        let a = ToolArguments(object)
        func one(_ key: String) throws -> String? {
            guard let values = try a.strings(key), !values.isEmpty else { return nil }
            guard values.count == 1 else {
                throw ToolError("The Network tab shows one \(key) at a time; got \(values.joined(separator: ", ")). Example: ui_show(networkFilter: {\(key): \"\(values[0])\"}). network_query takes several.")
            }
            return values[0]
        }
        var f = NetworkFilter()
        var notes: [String] = []
        f.method = try one("method")?.uppercased()
        if let raw = try one("status") { f.status = try NetworkTools.statusPick(raw) }
        if let pattern = try one("host") {
            let hosts = Array(Set(try await store.networkEntries(sessionId: sessionId).map(\.host))).sorted()
            let r = ToolInput.resolveNames([pattern], among: hosts)
            if let miss = r.misses.first {
                throw ToolError("No host matches \"\(miss.pattern)\" in session #\(sessionId). Closest: \(miss.closest.joined(separator: ", ")). Example: network_query() lists them.")
            }
            guard r.resolved.count == 1 else {
                throw ToolError("host \"\(pattern)\" matches \(r.resolved.joined(separator: ", ")); the Network tab shows one host. Example: ui_show(networkFilter: {host: \"\(r.resolved[0])\"}).")
            }
            f.host = r.resolved[0]
            if r.resolved[0] != pattern { notes.append("host \(pattern) → \(r.resolved[0])") }
        }
        f.search = try a.string("search")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        f.searchIsRegex = try a.bool("searchIsRegex") ?? false
        if f.searchIsRegex, !f.search.isEmpty, !Filter.isValidRegex(f.search) {
            throw ToolError("search \"\(f.search)\" is not a valid regular expression. Drop searchIsRegex to search for the text as is.")
        }
        return (f, notes)
    }

    // MARK: - Visibility

    static func eventShown(_ id: Int64, session: Int64, filter: Filter, _ store: LogStore) async throws -> Bool {
        try await store.eventPage(sessionId: session, filter: filter, afterId: id - 1, beforeId: id + 1,
                                  limit: 1, newestFirst: false).events.first?.id == id
    }

    static func hiddenEvent(_ id: Int64, _ filter: Filter) -> ToolError {
        let why = filter.hiddenThroughEventId.flatMap { id <= $0 ? "the user's Clear (the Log feed is cleared up to #\($0))" : nil }
            ?? "the log filter (\(ToolText.describe(filter)))"
        return ToolError("Event #\(id) is hidden by \(why). Example: ui_show(filter: {}, select: {eventId: \(id)}) shows every event.")
    }

    /// Like the Log feed's Show in Context: no filter, and the user's Clear
    /// only while it doesn't hide the event itself.
    static func inContextFilter(for id: Int64, _ filter: Filter) -> Filter {
        var f = Filter.none
        if let cleared = filter.hiddenThroughEventId, id > cleared { f.hiddenThroughEventId = cleared }
        return f
    }

    // MARK: - Output

    static func stateResult(_ host: HostSnapshot) -> ToolResult {
        let ui = host.ui
        let window = !host.windowOpen ? "Beaver's window is closed."
            : host.frontmost ? "Beaver is in front." : "Beaver is in the background."
        let cleared = ui.logFilter.hiddenThroughEventId.map { " (cleared up to #\($0))" } ?? ""
        var next: [String] = []
        if let id = ui.selectedEventId { next.append("logs_get(ids: [\(id)])") }
        if let id = ui.selectedNetworkId { next.append("network_get(id: \(id))") }
        next.append("ui_show(networkFilter: {status: \"errors\"}, select: \"first\")")
        return ToolResult(
            summary: "Beaver shows \(view(ui)). \(window)",
            body: [
                "Tab: \(ui.tab.rawValue)",
                "Session: " + (ui.sessionId.map { "#\($0)" } ?? "none"),
                "Log filter: \(ToolText.describe(ui.logFilter))\(cleared)",
                "Network filter: \(describe(ui.networkFilter))",
                "Storage: \(ui.storageLayer.wireKey)" + (ui.storageSearch.isEmpty ? "" : ", search \"\(ui.storageSearch)\""),
                "Selected event: " + (ui.selectedEventId.map { "#\($0)" } ?? "none"),
                "Selected request: " + (ui.selectedNetworkId.map { "#\($0)" } ?? "none"),
                "Window: " + (!host.windowOpen ? "closed" : host.frontmost ? "in front" : "in the background"),
            ].joined(separator: "\n"),
            structured: [
                "tab": .string(ui.tab.rawValue),
                "sessionId": JSON(ui.sessionId),
                "filter": filterJSON(ui.logFilter),
                "clearedThroughEventId": JSON(ui.logFilter.hiddenThroughEventId),
                "networkFilter": networkFilterJSON(ui.networkFilter),
                "storage": ["layer": .string(ui.storageLayer.wireKey), "search": .string(ui.storageSearch)],
                "selectedEventId": JSON(ui.selectedEventId),
                "selectedNetworkId": JSON(ui.selectedNetworkId),
                "windowOpen": .bool(host.windowOpen),
                "frontmost": .bool(host.frontmost),
            ],
            next: next,
            sessionId: ui.sessionId
        )
    }

    /// `Network, session #13 — status errors; request #391 selected`.
    static func view(_ ui: UIState) -> String {
        var text = ui.tab.title + (ui.sessionId.map { ", session #\($0)" } ?? "")
        let shown: String? = switch ui.tab {
        case .logs:
            ToolText.describe(ui.logFilter) == "no filter" ? nil : ToolText.describe(ui.logFilter)
        case .network:
            ui.networkFilter.isEmpty ? nil : describe(ui.networkFilter)
        case .storages:
            ui.storageLayer.displayName + (ui.storageSearch.isEmpty ? "" : ", search \"\(ui.storageSearch)\"")
        case .sessions:
            nil
        }
        if let shown { text += " — " + shown }
        let selected: String? = switch ui.tab {
        case .logs: ui.selectedEventId.map { "event #\($0) selected" }
        case .network: ui.selectedNetworkId.map { "request #\($0) selected" }
        case .storages, .sessions: nil
        }
        if let selected { text += "; " + selected }
        return text
    }

    static func statusName(_ pick: NetworkFilter.StatusPick) -> String {
        switch pick {
        case .errors: "errors"
        case .code(let code): String(code)
        case .noStatus: "noStatus"
        case .statusClass(let c): c == .failed ? "failed" : c == .other ? "other" : c.displayName
        }
    }

    static func describe(_ f: NetworkFilter) -> String {
        var parts: [String] = []
        if let m = f.method { parts.append("method \(m)") }
        if let s = f.status { parts.append("status \(statusName(s))") }
        if let h = f.host { parts.append("host \(h)") }
        if !f.search.isEmpty { parts.append((f.searchIsRegex ? "regex" : "search") + " \"\(f.search)\"") }
        if !f.excludedMethods.isEmpty { parts.append("not methods " + f.excludedMethods.sorted().joined(separator: ", ")) }
        if !f.excludedStatusClasses.isEmpty {
            parts.append("not " + f.excludedStatusClasses.map { statusName(.statusClass($0)) }.sorted().joined(separator: ", "))
        }
        if !f.excludedHosts.isEmpty { parts.append("not hosts " + f.excludedHosts.sorted().joined(separator: ", ")) }
        return parts.isEmpty ? "no filter" : parts.joined(separator: "; ")
    }

    /// The keys `filter` takes, only the ones set.
    static func filterJSON(_ f: Filter) -> JSON {
        var o: [String: JSON] = [:]
        if f.minLevel != .verbose { o["minLevel"] = .string(f.minLevel.rawValue) }
        if let s = f.search { o["search"] = .string(s) }
        if f.searchIsRegex { o["searchIsRegex"] = true }
        if let e = f.exclude { o["exclude"] = .string(e) }
        if f.excludeIsRegex { o["excludeIsRegex"] = true }
        if f.searchPayloads { o["searchPayloads"] = true }
        for (key, names) in [("subsystems", f.subsystems), ("excludeSubsystems", f.excludedSubsystems),
                             ("categories", f.categories), ("excludeCategories", f.excludedCategories)]
        where !names.isEmpty {
            o[key] = .array(names.sorted().map(JSON.string))
        }
        return .object(o)
    }

    /// The keys `networkFilter` takes, plus the exclusions the user set.
    static func networkFilterJSON(_ f: NetworkFilter) -> JSON {
        var o: [String: JSON] = [:]
        if let m = f.method { o["method"] = .string(m) }
        if let s = f.status { o["status"] = .string(statusName(s)) }
        if let h = f.host { o["host"] = .string(h) }
        if !f.search.isEmpty { o["search"] = .string(f.search) }
        if f.searchIsRegex { o["searchIsRegex"] = true }
        if !f.excludedMethods.isEmpty { o["excludedMethods"] = .array(f.excludedMethods.sorted().map(JSON.string)) }
        if !f.excludedStatusClasses.isEmpty {
            o["excludedStatuses"] = .array(f.excludedStatusClasses.map { statusName(.statusClass($0)) }.sorted().map(JSON.string))
        }
        if !f.excludedHosts.isEmpty { o["excludedHosts"] = .array(f.excludedHosts.sorted().map(JSON.string)) }
        return .object(o)
    }
}
