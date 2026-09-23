//
//  LogFeedView.swift
//  Beaver
//

import AppKit
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
            if vm.filter.chipCount(for: .subsystem) > 0
                || vm.filter.chipCount(for: .category) > 0 {
                Divider()
                ActiveChipsBar(vm: vm)
            }
            Divider()
            HSplitView {
                LogFeedTable(vm: vm)
                    .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                DetailPaneView(event: selectedEvent,
                               data: vm.selectedData,
                               context: vm.selectedContext)
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
        .onReceive(
            NotificationCenter.default.publisher(for: .beaverClearView)
        ) { _ in
            Task { await vm.clearView() }
        }
        // Mirror the active filter to env so MainWindow's Export
        // toolbar action can scope its query to the rows currently
        // shown in the table (D26). Initialize on appear in case
        // the view mounts with a non-empty filter (saved-preset
        // selection survives session switches).
        .onAppear { env.activeFilter = vm.filter }
        // Deliberately NOT cleared on disappear: the Storages tab has
        // an Export too, and "Export filtered" there has to mean the
        // same filter the user set on this screen.
        .onChange(of: vm.filter) { _, newValue in
            env.activeFilter = newValue
        }
    }

    /// Rows in `vm.page` carry no JSON payloads (they'd be gigabytes for a
    /// whole session), so the detail pane reads the separately-fetched
    /// full row instead of looking the selection up in the page.
    private var selectedEvent: EventRecord? {
        vm.selectedEvent
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

            // Click-to-filter values. Each click cycles
            // include → exclude → off, same as the web viewer.
            FacetMenuButton(vm: vm, facet: .subsystem, title: "Subsystem")
            FacetMenuButton(vm: vm, facet: .category,  title: "Category")

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

            // "42 / 150 events" while filtering, plain count otherwise —
            // so the filter's effect is visible without doing the maths.
            HStack(spacing: 4) {
                Text("\(vm.totalCount)").bold().monospacedDigit()
                if vm.totalCount != vm.unfilteredCount {
                    Text("/ \(vm.unfilteredCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("events").foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize()
            .help(vm.totalCount == vm.unfilteredCount
                  ? "Events in this session"
                  : "Matching the current filter, out of every event in the session")

            // Nothing was deleted, so say so and offer the way back.
            // Without this the counter reading "0 / 9034" looks like
            // data loss rather than a hidden backlog.
            if vm.isViewCleared {
                Button {
                    vm.restoreClearedView()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Show cleared")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("Bring back the events Clear hid — they were never deleted")
            }

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

            // Tail-following toggle. Off by default so high-volume
            // streaming doesn't yank the user's scroll position
            // to the bottom every time an event arrives. Flipping
            // ON snaps to the latest event; the moment the user
            // scrolls manually, ScrollWatcher flips it back OFF
            // so they're never trapped.
            Toggle("Auto-scroll", isOn: $vm.autoScrollEnabled)
                .toggleStyle(.switch)
                .fixedSize()
                .help(vm.autoScrollEnabled
                      ? "Following the tail. Scrolling manually turns this off."
                      : "Click to start following new events. Off by default — turn on while you want live tailing.")

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
        for facet in [Filter.Facet.subsystem, .category] where f.chipCount(for: facet) > 0 {
            let included = f.included(facet).sorted()
            let excluded = f.excluded(facet).sorted()
            if !included.isEmpty { parts.append("only \(included.joined(separator: ", "))") }
            if !excluded.isEmpty { parts.append("not \(excluded.joined(separator: ", "))") }
        }
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
        let chips = f.chipCount(for: .subsystem) + f.chipCount(for: .category)
        if chips > 0 { parts.append("\(chips) chip\(chips == 1 ? "" : "s")") }
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

// MARK: - Subsystem / category chips

/// Browse every value a session has produced and set its state. The
/// badge counts how many constraints this facet currently carries.
private struct FacetMenuButton: View {
    @Bindable var vm: LogFeedViewModel
    let facet: Filter.Facet
    let title: String

    /// Ordered by what the menu shows — the store sorts full values,
    /// which with the bundle id dropped would read out of order.
    private var values: [String] {
        vm.values(for: facet).sorted {
            facet.displayName($0).localizedCaseInsensitiveCompare(facet.displayName($1)) == .orderedAscending
        }
    }
    private var activeCount: Int { vm.filter.chipCount(for: facet) }

    var body: some View {
        Menu {
            if values.isEmpty {
                Text("No values yet")
            } else {
                ForEach(values, id: \.self) { value in
                    Button {
                        vm.cycleChip(value, in: facet)
                    } label: {
                        Label(facet.displayName(value),
                              systemImage: icon(for: vm.filter.state(of: value, in: facet)))
                    }
                }
            }
            if activeCount > 0 {
                Divider()
                Button("Clear \(title) filters") {
                    vm.filter.clearChips(in: facet)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Show only, or hide, events by \(title.lowercased())")
    }

    /// Mirrors the web's ✅ / ⛔ / nothing.
    private func icon(for state: Filter.ChipState) -> String {
        switch state {
        case .off:     "circle"
        case .include: "checkmark.circle.fill"
        case .exclude: "minus.circle.fill"
        }
    }
}

/// The active chips, on their own row so the filter bar keeps its
/// height. Clicking one advances it, which is also how it is removed.
private struct ActiveChipsBar: View {
    @Bindable var vm: LogFeedViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chips(for: .subsystem)
                chips(for: .category)

                Button {
                    vm.filter.clearChips(in: .subsystem)
                    vm.filter.clearChips(in: .category)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear every chip")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func chips(for facet: Filter.Facet) -> some View {
        ForEach(vm.filter.included(facet).sorted(), id: \.self) { value in
            FilterChip(value: value, title: facet.displayName(value), state: .include) {
                vm.cycleChip(value, in: facet)
            }
        }
        ForEach(vm.filter.excluded(facet).sorted(), id: \.self) { value in
            FilterChip(value: value, title: facet.displayName(value), state: .exclude) {
                vm.cycleChip(value, in: facet)
            }
        }
    }
}

private struct FilterChip: View {
    let value: String
    /// What the chip reads; `value` stays in the tooltip.
    let title: String
    let state: Filter.ChipState
    let onTap: () -> Void

    private var tint: Color { state == .include ? .green : .red }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: state == .include ? "checkmark" : "minus")
                    .font(.caption2.weight(.bold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(state == .include
              ? "Showing only \"\(value)\" — click to hide it instead"
              : "Hiding \"\(value)\" — click to clear")
    }
}

// MARK: - Table

private struct LogFeedTable: View {
    @Bindable var vm: LogFeedViewModel
    @Environment(ToastCenter.self) private var toasts

    /// Column widths / order / visibility, remembered between launches.
    /// `TableColumnCustomization` is Codable, so it round-trips through
    /// a single defaults string.
    @AppStorage("logFeed.columnLayout") private var storedColumnLayout = ""
    @State private var columnLayout = TableColumnCustomization<LogFeedViewModel.CollapsedRow>()

    var body: some View {
        ScrollViewReader { proxy in
            Table(
                vm.collapsedRows,
                selection: $vm.selectedEventId,
                columnCustomization: $columnLayout
            ) {
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
                .customizationID("level")

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
                .customizationID("message")

                TableColumn("Subsystem") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(highlighted(row.event.shortSubsystem))
                }
                .width(min: 150, ideal: 200)
                .customizationID("subsystem")

                TableColumn("Category") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(highlighted(row.event.category))
                }
                .width(min: 120, ideal: 150)
                .customizationID("category")

                // What this entry costs on the wire. Colour-coded so an
                // expensive log stands out while scrolling.
                TableColumn("Size") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(row.event.sizeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(sizeTint(row.event.sizeClass))
                        .help(sizeHelp(row.event.sizeClass))
                }
                .width(70)
                .customizationID("size")

                TableColumn("Time") { (row: LogFeedViewModel.CollapsedRow) in
                    Text(row.event.timeOfDayWithMillis)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(120)
                .customizationID("time")
            }
            // j / k mirror the arrow keys, and Esc closes the detail
            // pane — the shortcuts the web viewer documents.
            .onKeyPress { press in
                switch press.key {
                case "j": vm.selectNextRow();     return .handled
                case "k": vm.selectPreviousRow(); return .handled
                default:  return .ignored
                }
            }
            .onKeyPress(.escape) {
                guard vm.selectedEventId != nil else { return .ignored }
                vm.selectedEventId = nil
                return .handled
            }
            .onAppear {
                guard let data = storedColumnLayout.data(using: .utf8),
                      let saved = try? JSONDecoder().decode(
                          TableColumnCustomization<LogFeedViewModel.CollapsedRow>.self,
                          from: data
                      )
                else { return }
                columnLayout = saved
            }
            .onChange(of: columnLayout) { _, layout in
                guard let data = try? JSONEncoder().encode(layout),
                      let text = String(data: data, encoding: .utf8)
                else { return }
                storedColumnLayout = text
            }
            .contextMenu(forSelectionType: EventRecord.ID.self) { ids in
                rowContextMenu(for: events(forSelection: ids))
            }
            // Detect user-initiated scrolls on the table's underlying
            // NSScrollView. When the user manually moves the scroll
            // position, we flip `autoScrollEnabled` off so the next
            // new event doesn't yank them back to the bottom.
            .background {
                ScrollWatcher {
                    if vm.autoScrollEnabled { vm.autoScrollEnabled = false }
                }
            }
            // Auto-scroll to the newest row whenever a new event
            // lands in the page — but only when the user has
            // explicitly opted into tail-following via the
            // "Auto-scroll" toggle. Default is OFF, so this is a
            // no-op until the user asks for it.
            //
            // NOT animated — under fast streaming the animation
            // would move row positions while the user tries to
            // click, causing hit-tests to resolve to the wrong row.
            // Instant scroll keeps clicks reliable.
            //
            // Paused state means `page` doesn't grow, so no scroll
            // fires. Match-jump scrolls to its own target separately
            // via scrollTarget below (which IS animated, because
            // that's a one-shot user action).
            .onChange(of: vm.page.last?.id) { _, newLastId in
                guard let newLastId, vm.autoScrollEnabled else { return }
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
            // Toggling Auto-scroll ON snaps the table to the latest
            // row immediately — otherwise the user would have to
            // wait for the next event to see anything happen.
            .onChange(of: vm.autoScrollEnabled) { _, enabled in
                guard enabled, let lastId = vm.page.last?.id else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(lastId, anchor: .bottom)
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

    private func sizeTint(_ sizeClass: EventRecord.SizeClass) -> Color {
        switch sizeClass {
        case .normal:    .secondary
        case .average:   .yellow
        case .oversized: .red
        }
    }

    private func sizeHelp(_ sizeClass: EventRecord.SizeClass) -> String {
        switch sizeClass {
        case .normal:    "Ordinary size"
        case .average:   "Over 1 KB — on the heavy side"
        case .oversized: "Over 8 KB — worth asking why"
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
            Button("Copy as JSON")   { copyAsJSON(ids: [event.id], label: "Event JSON") }
        }
        // These set a chip rather than overwriting the free-text
        // fields, so "filter to this subsystem" no longer wipes
        // whatever the user had typed there.
        Section {
            Button("Filter to this Subsystem") {
                vm.setChip(.include, for: event.subsystem, in: .subsystem)
                toasts.info("Showing only \(event.shortSubsystem)")
            }
            Button("Exclude this Subsystem") {
                vm.setChip(.exclude, for: event.subsystem, in: .subsystem)
                toasts.info("Hiding \(event.shortSubsystem)")
            }
        }
        if !event.category.isEmpty {
            Section {
                Button("Filter to this Category") {
                    vm.setChip(.include, for: event.category, in: .category)
                    toasts.info("Showing only \(event.category)")
                }
                Button("Exclude this Category") {
                    vm.setChip(.exclude, for: event.category, in: .category)
                    toasts.info("Hiding \(event.category)")
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
            copyAsJSON(
                ids: Set(events.map(\.id)),
                label: "\(events.count) events as JSON"
            )
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

    /// Rows in `vm.page` are payload-free, so refetch the selected ids
    /// with their JSON before encoding.
    private func copyAsJSON(ids: Set<EventRecord.ID>, label: String) {
        Task {
            let full = await vm.fullEvents(ids: ids)
            copyToPasteboard(formatAsJSON(full), label: label)
        }
    }
}

// MARK: - Scroll watcher

/// Invisible bridge that finds the enclosing `NSScrollView` (the
/// one SwiftUI's `Table` builds on top of) and reports
/// user-initiated scroll events back via the `onUserScroll`
/// closure.
///
/// Used by `LogFeedTable` to flip the Auto-scroll toggle off when
/// the user manually scrolls — programmatic scrolls
/// (`proxy.scrollTo`) don't fire `didLiveScrollNotification`, so
/// there's no feedback loop.
///
/// Placed as a `.background` of the Table; the empty NSView walks
/// up its superview chain to find the table's scroll view.
private struct ScrollWatcher: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWatcherView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? ScrollWatcherView {
            view.onUserScroll = onUserScroll
        }
    }
}

private final class ScrollWatcherView: NSView {
    var onUserScroll: (() -> Void)?
    private weak var observed: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // Removed from hierarchy — tear down the observation.
            unsubscribe()
            return
        }
        // Defer one runloop so the Table has time to install its
        // internal NSTableView + NSScrollView. Without this delay
        // findScrollView() walks an incomplete view tree.
        DispatchQueue.main.async { [weak self] in
            self?.subscribe()
        }
    }

    deinit {
        unsubscribe()
    }

    private func subscribe() {
        guard let scrollView = findScrollView() else { return }
        if observed === scrollView { return }
        unsubscribe()
        observed = scrollView
        // `didLiveScrollNotification` fires for user-initiated
        // scrolls (trackpad, scroll wheel, scrollbar drag).
        // Programmatic scrollers like `NSTableView.scrollRowToVisible`
        // don't fire it — exactly what we want.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }

    private func unsubscribe() {
        if let observed {
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.didLiveScrollNotification,
                object: observed
            )
        }
        observed = nil
    }

    @objc private func handleScroll() {
        onUserScroll?()
    }

    /// Walk the parent chain to find the scroll view SwiftUI's
    /// Table sits inside. Tables on macOS use NSTableView wrapped
    /// in NSScrollView, so the scroll view is an ancestor of any
    /// `.background` view attached to the Table.
    private func findScrollView() -> NSScrollView? {
        var current: NSView? = superview
        while let view = current {
            if let scroll = view as? NSScrollView { return scroll }
            // Walk siblings too — Table's NSScrollView is sometimes
            // a sibling of the .background overlay rather than a
            // strict ancestor.
            if let siblings = view.superview?.subviews {
                for sibling in siblings where sibling !== view {
                    if let scroll = sibling as? NSScrollView { return scroll }
                    if let nested = sibling.descendantScrollView() {
                        return nested
                    }
                }
            }
            current = view.superview
        }
        return nil
    }
}

private extension NSView {
    /// Depth-first search for an NSScrollView in the subtree.
    func descendantScrollView() -> NSScrollView? {
        for child in subviews {
            if let scroll = child as? NSScrollView { return scroll }
            if let nested = child.descendantScrollView() { return nested }
        }
        return nil
    }
}
