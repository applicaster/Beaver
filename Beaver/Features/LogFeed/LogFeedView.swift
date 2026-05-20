//
//  LogFeedView.swift
//  Beaver
//

import SwiftUI

/// Renders the table + filter bar + detail split for a session.
/// The `LogFeedViewModel` is owned by `MainWindow` (so its state
/// — filter, exclude, sort, selection — survives tab switches);
/// this view just receives the instance and binds against it. The
/// VM is replaced when `env.viewingSessionId` changes; same
/// session → same VM, every visit.
struct LogFeedView: View {
    @Bindable var vm: LogFeedViewModel

    var body: some View {
        LogFeedContent(vm: vm)
    }
}

// MARK: - Content

private struct LogFeedContent: View {
    @Bindable var vm: LogFeedViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            LogFeedFilterBar(vm: vm)
            Divider()
            HSplitView {
                LogFeedTable(vm: vm)
                    .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                DetailPaneView(event: selectedEvent)
                    .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Toolbar Bookmarks popover posts to this notification with
        // the chosen event id; we forward it to the active view model.
        .onReceive(
            NotificationCenter.default.publisher(for: .beaverJumpToBookmark)
        ) { notification in
            if let eventId = notification.object as? Int64 {
                vm.jumpToBookmark(eventId: eventId)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .beaverJumpToTime)
        ) { notification in
            if let target = notification.object as? Date {
                vm.jumpToTime(target)
            }
        }
        // Mirror the active filter to env so MainWindow's Export
        // toolbar action can scope its query to the rows currently
        // shown in the table (D26). Initialize on appear in case
        // the view mounts with a non-empty filter (saved-preset
        // selection survives session switches).
        .onAppear { env.activeFilter = vm.filter }
        .onDisappear { env.activeFilter = .none }
        .onChange(of: vm.filter) { _, newValue in
            env.activeFilter = newValue
        }
    }

    private var selectedEvent: EventRecord? {
        guard let id = vm.selectedEventId else { return nil }
        return vm.page.first { $0.id == id }
    }
}

// MARK: - Filter bar

private struct LogFeedFilterBar: View {
    @Bindable var vm: LogFeedViewModel

    var body: some View {
        HStack(spacing: 10) {
            // Saved-filter presets. Star icon shows the user's named
            // filter combinations + "Save current filter…". See D24.
            SavedFiltersMenu(vm: vm)

            // Level popup — single button showing the current level;
            // click opens a menu of all five.
            LevelMenuButton(vm: vm)

            FilterPillField(
                systemImage: "line.3.horizontal.decrease.circle",
                placeholder: "Filter events…",
                text: Binding(
                    get: { vm.filter.search ?? "" },
                    set: { vm.filter.search = $0.isEmpty ? nil : $0 }
                ),
                regex: Binding(
                    get: { vm.filter.searchIsRegex },
                    set: { vm.filter.searchIsRegex = $0 }
                )
            )
            FilterPillField(
                systemImage: "minus.circle",
                placeholder: "Exclude events…",
                text: Binding(
                    get: { vm.filter.exclude ?? "" },
                    set: { vm.filter.exclude = $0.isEmpty ? nil : $0 }
                ),
                regex: Binding(
                    get: { vm.filter.excludeIsRegex },
                    set: { vm.filter.excludeIsRegex = $0 }
                )
            )
            FilterPillField(
                systemImage: "magnifyingglass",
                placeholder: "Search & highlight…",
                text: Binding(
                    get: { vm.highlight ?? "" },
                    set: { vm.highlight = $0.isEmpty ? nil : $0 }
                ),
                regex: $vm.highlightIsRegex
            )

            // Match navigator: N/M plus up/down jump buttons. Appears
            // only when there's a non-empty highlight term.
            if let highlight = vm.highlight, !highlight.isEmpty {
                MatchNavigator(vm: vm)
            }

            HStack(spacing: 4) {
                Text("\(vm.totalCount)").bold().monospacedDigit()
                Text("events").foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize()

            // "↓ N new events" pill — shown only when paused with
            // unseen events queued up. Click resumes the live feed.
            if vm.isPaused && vm.unseenCount > 0 {
                Button {
                    vm.resume()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("\(vm.unseenCount) new")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Resume and scroll to latest")
            }

            Button {
                vm.isPaused.toggle()
            } label: {
                Label(
                    vm.isPaused ? "Resume" : "Pause",
                    systemImage: vm.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .help(vm.isPaused
                  ? "Resume the live feed (catch up on new events)"
                  : "Freeze the table so you can read without new events shifting it")

            Toggle("Collapse", isOn: $vm.collapseRepeats)
                .toggleStyle(.switch)
                .fixedSize()
                .help("Fold consecutive identical events into one row")
        }
        .padding(.horizontal, 12)
        // Explicit 48pt so the bar matches StoragesTopBar's height
        // regardless of which control inside is the tallest. Inner
        // pills / chips sit centered in the 48pt frame.
        .frame(height: 48)
    }
}

private struct FilterPillField: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    @Binding var regex: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(regex ? .system(.body, design: .monospaced) : .body)

            // Clear-X button: appears only when the field has text.
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Button {
                regex.toggle()
            } label: {
                Text(".*")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(regex ? Color.white : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(regex ? Color.accentColor : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(regex ? Color.clear : Color.secondary.opacity(0.4),
                                          lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(regex ? "Regex: ON" : "Toggle regex mode")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        )
    }
}

private struct MatchNavigator: View {
    @Bindable var vm: LogFeedViewModel

    var body: some View {
        HStack(spacing: 4) {
            Text(counterText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.matchCount > 0 ? .primary : .secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Button {
                vm.previousMatch()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(vm.matchCount == 0)
            .help("Previous match")

            Button {
                vm.nextMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(vm.matchCount == 0)
            .help("Next match")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        )
        .fixedSize()
    }

    private var counterText: String {
        if vm.matchCount == 0 {
            return "0/0"
        }
        let current = (vm.currentMatchIndex ?? 0) + 1
        return "\(current)/\(vm.matchCount)"
    }
}

// MARK: - Saved filter presets

/// Star menu at the leading edge of the filter bar. Lists the user's
/// saved filter combinations; click one to apply, "Save current
/// filter…" persists the current Filter under a name, hover-revealed
/// trash deletes. See D24 for the rationale; storage CRUD lives on
/// LogStore.
private struct SavedFiltersMenu: View {
    @Bindable var vm: LogFeedViewModel

    @State private var isPopoverShown = false
    @State private var isHovered = false
    @State private var savePromptShown = false
    @State private var newName: String = ""

    var body: some View {
        Button {
            isPopoverShown = true
        } label: {
            Image(systemName: hasMatchingActiveFilter
                  ? "star.fill"
                  : "star")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hasMatchingActiveFilter ? Color.yellow : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.secondary.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(hasMatchingActiveFilter
              ? "Saved filter applied — click to manage"
              : "Saved filter presets")
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 280)
                .padding(.vertical, 6)
        }
        .sheet(isPresented: $savePromptShown) {
            saveSheet
        }
    }

    /// True if any saved preset's stored filter matches what's
    /// currently in `vm.filter`. Drives the filled-star indicator
    /// so the user can tell at a glance "I'm running a preset"
    /// versus "I've ad-hoc'd it".
    private var hasMatchingActiveFilter: Bool {
        vm.savedFilters.contains { $0.filter == vm.filter }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.savedFilters.isEmpty {
                Text("No saved filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(vm.savedFilters) { saved in
                    SavedFilterRow(
                        saved: saved,
                        isActive: saved.filter == vm.filter,
                        onApply: {
                            vm.applySavedFilter(saved)
                            isPopoverShown = false
                        },
                        onDelete: {
                            vm.deleteSavedFilter(id: saved.id)
                        }
                    )
                }
                Divider().padding(.vertical, 4)
            }

            Button {
                newName = ""
                isPopoverShown = false
                // Small delay so the popover dismiss animation
                // finishes before the sheet slides up. Without it
                // the sheet can race the popover's exit transition
                // and land off-screen on slower machines.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    savePromptShown = true
                }
            } label: {
                Label("Save current filter…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.filter.isEmpty)
            .help(vm.filter.isEmpty
                  ? "No filter to save — set a level, search, or exclude term first"
                  : "Persist the current filter under a name")
        }
    }

    @ViewBuilder
    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save current filter").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Errors only, no analytics", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSave() }
            }

            // Show what's being saved so the user can sanity-check
            // before committing the name.
            VStack(alignment: .leading, spacing: 4) {
                Text("Filter preview").font(.caption).foregroundStyle(.secondary)
                Text(filterSummary(vm.filter))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel") { savePromptShown = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commitSave() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vm.saveCurrentFilter(as: trimmed)
        savePromptShown = false
    }

    private func filterSummary(_ f: Filter) -> String {
        var parts: [String] = ["≥ \(f.minLevel.displayName)"]
        if let s = f.search {
            parts.append(f.searchIsRegex ? "match /\(s)/" : "match \"\(s)\"")
        }
        if let s = f.exclude {
            parts.append(f.excludeIsRegex ? "exclude /\(s)/" : "exclude \"\(s)\"")
        }
        return parts.joined(separator: "  •  ")
    }
}

/// One row in the saved-filters popover. Click anywhere applies the
/// preset; the trash icon (revealed on hover) deletes it.
private struct SavedFilterRow: View {
    let saved: SavedFilter
    let isActive: Bool
    let onApply: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onApply) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(saved.name)
                        .font(.system(size: 13))
                    Text(filterCaption(saved.filter))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete this saved filter")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func filterCaption(_ f: Filter) -> String {
        var parts: [String] = ["≥\(f.minLevel.displayName)"]
        if let s = f.search { parts.append("+\"\(s)\"") }
        if let s = f.exclude { parts.append("−\"\(s)\"") }
        return parts.joined(separator: " ")
    }
}

/// Button + custom popover for selecting the minimum log level.
/// Replaces the macOS `Menu` so we can style menu rows freely —
/// AppKit's menu doesn't honor `foregroundStyle` on text or icons,
/// which means level colors get washed out. A SwiftUI popover gives
/// full styling control.
private struct LevelMenuButton: View {
    @Bindable var vm: LogFeedViewModel
    @State private var isPopoverShown = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPopoverShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(vm.filter.minLevel.displayName)
                    .font(.caption.weight(.bold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(vm.filter.minLevel.displayColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovered
                          ? vm.filter.minLevel.displayColor.opacity(0.12)
                          : Color(.controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .strokeBorder(vm.filter.minLevel.displayColor.opacity(0.5),
                                  lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Minimum log level — shows this level and higher")
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            LevelPopover(selected: vm.filter.minLevel) { level in
                vm.filter.minLevel = level
                isPopoverShown = false
            }
        }
    }
}

private struct LevelPopover: View {
    let selected: LogLevel
    let onSelect: (LogLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LogLevel.allCases, id: \.self) { level in
                LevelPopoverRow(
                    level: level,
                    isSelected: level == selected,
                    onTap: { onSelect(level) }
                )
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 140)
    }
}

private struct LevelPopoverRow: View {
    let level: LogLevel
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(level.displayColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 14)
            Text(level.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(level.displayColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isHovered
                ? level.displayColor.opacity(0.12)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
    }
}

private struct LevelChip: View {
    let level: LogLevel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(level.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : level.displayColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? level.displayColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Table

private struct LogFeedTable: View {
    @Bindable var vm: LogFeedViewModel
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ScrollViewReader { proxy in
            Table(vm.collapsedRows, selection: $vm.selectedEventId) {
                TableColumn("Level") { (row: LogFeedViewModel.CollapsedRow) in
                    HStack(spacing: 4) {
                        if vm.isBookmarked(row.event.id) {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        Circle()
                            .fill(row.event.level.displayColor)
                            .frame(width: 8, height: 8)
                        Text(row.event.level.displayName)
                            .font(.caption)
                            .foregroundStyle(row.event.level.displayColor)
                    }
                }
                .width(95)

                TableColumn("Message") { (row: LogFeedViewModel.CollapsedRow) in
                    HStack(spacing: 6) {
                        Text(highlighted(row.event.message))
                            .lineLimit(2)
                            .truncationMode(.tail)
                        if row.count > 1 {
                            // ×N badge for collapsed groups.
                            Text("×\(row.count)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.18))
                                )
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 400, ideal: 600)

                TableColumn("Subsystem") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(highlighted(row.event.subsystem))
                }
                .width(min: 150, ideal: 200)

                TableColumn("Category") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(highlighted(row.event.category))
                }
                .width(min: 120, ideal: 150)

                TableColumn("Time") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(row.event.timeOfDayWithMillis)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(120)
            }
            .contextMenu(forSelectionType: EventRecord.ID.self) { ids in
                rowContextMenu(for: events(forSelection: ids))
            }
            // Auto-scroll to the newest row whenever a new event
            // lands in the page. NOT animated — under fast streaming
            // the animation would move row positions while the user
            // tries to click, causing hit-tests to resolve to the
            // wrong row. Instant scroll keeps clicks reliable.
            //
            // Paused state means `page` doesn't grow, so no scroll
            // fires. Match-jump scrolls to its own target separately
            // via scrollTarget below (which IS animated, because
            // that's a one-shot user action).
            .onChange(of: vm.page.last?.id) { _, newLastId in
                guard let newLastId else { return }
                // Defer one runloop so SwiftUI Table finishes
                // committing the new `page` before we ask its
                // internal NSTableView to scroll. Without this defer,
                // applying a filter that replaces the whole page can
                // panic with "Index out of range" when scrollTo races
                // the data update.
                DispatchQueue.main.async {
                    proxy.scrollTo(newLastId, anchor: .bottom)
                }
            }
            // Resuming from paused should snap to the latest row.
            // Same instant-scroll reasoning.
            .onChange(of: vm.isPaused) { _, paused in
                guard !paused, let lastId = vm.page.last?.id else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            // Jump-to-match: when the view model signals a scroll
            // target (via Up/Down on the match navigator), center the
            // table on that event.
            .onChange(of: vm.scrollTarget?.token) { _, _ in
                guard let target = vm.scrollTarget?.id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        // Visual highlight only — uses the dedicated `highlight` field,
        // not the `filter.search` (which controls which rows show).
        Highlighting.highlight(text, term: vm.highlight, isRegex: vm.highlightIsRegex)
    }

    // MARK: - Context menu

    /// Resolve a selection set into the actual `EventRecord` instances
    /// currently loaded in the page. (Records outside the visible
    /// window aren't available, but right-click only ever targets a
    /// visible row anyway.)
    private func events(forSelection ids: Set<EventRecord.ID>) -> [EventRecord] {
        vm.page.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func rowContextMenu(for events: [EventRecord]) -> some View {
        if events.count == 1, let event = events.first {
            singleRowMenu(for: event)
        } else if !events.isEmpty {
            multiRowMenu(for: events)
        }
    }

    @ViewBuilder
    private func singleRowMenu(for event: EventRecord) -> some View {
        Section {
            Button(vm.isBookmarked(event.id)
                   ? "Remove Bookmark"
                   : "Bookmark") {
                let wasBookmarked = vm.isBookmarked(event.id)
                vm.toggleBookmark(event.id)
                toasts.success(wasBookmarked ? "Bookmark removed" : "Bookmark added")
            }
        }
        Section {
            Button("Copy Message")   { copyToPasteboard(event.message,   label: "Message") }
            Button("Copy Subsystem") { copyToPasteboard(event.subsystem, label: "Subsystem") }
            if !event.category.isEmpty {
                Button("Copy Category") { copyToPasteboard(event.category, label: "Category") }
            }
            Button("Copy as JSON")   { copyToPasteboard(formatAsJSON([event]), label: "Event JSON") }
        }
        Section {
            Button("Filter to this Subsystem") {
                vm.filter.search = event.subsystem
                vm.filter.searchIsRegex = false
                toasts.info("Filtered to subsystem")
            }
            Button("Exclude this Subsystem") {
                vm.filter.exclude = event.subsystem
                vm.filter.excludeIsRegex = false
                toasts.info("Excluding subsystem")
            }
        }
        if !event.category.isEmpty {
            Section {
                Button("Filter to this Category") {
                    vm.filter.search = event.category
                    vm.filter.searchIsRegex = false
                    toasts.info("Filtered to category")
                }
                Button("Exclude this Category") {
                    vm.filter.exclude = event.category
                    vm.filter.excludeIsRegex = false
                    toasts.info("Excluding category")
                }
            }
        }
        // Level-based quick filter. Sets the minimum level so the
        // user can right-click a warning → "Show ≥ Warning" to
        // instantly hide the verbose / debug noise.
        Section {
            if vm.filter.minLevel != event.level {
                Button("Show \(event.level.displayName) and above") {
                    vm.filter.minLevel = event.level
                    toasts.info("Showing \(event.level.displayName) and above")
                }
            }
            if vm.filter.minLevel != .verbose {
                Button("Reset level to Verbose") {
                    vm.filter.minLevel = .verbose
                    toasts.info("Level reset")
                }
            }
        }
    }

    @ViewBuilder
    private func multiRowMenu(for events: [EventRecord]) -> some View {
        Button("Copy \(events.count) Messages") {
            let messages = events.map(\.message).joined(separator: "\n")
            copyToPasteboard(messages, label: "\(events.count) messages")
        }
        Button("Copy \(events.count) Events as JSON") {
            copyToPasteboard(formatAsJSON(events), label: "\(events.count) events as JSON")
        }
    }

    private func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toasts.success("Copied \(label.lowercased())")
    }

    /// Reuse the same JSON shape as the toolbar Export, so a clipboard
    /// dump can be diff'd or imported back into a fresh session.
    private func formatAsJSON(_ events: [EventRecord]) -> String {
        guard let data = try? EventJSON.encode(events),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
