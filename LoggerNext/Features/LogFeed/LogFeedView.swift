//
//  LogFeedView.swift
//  LoggerNext
//

import SwiftUI

/// Owns the `LogFeedViewModel` for a given session and renders the
/// table + filter bar + detail split. Apply `.id(sessionId)` on the
/// parent to force a clean rebuild when the active session changes.
struct LogFeedView: View {
    let sessionId: Int64

    @Environment(AppEnvironment.self) private var env
    @State private var vm: LogFeedViewModel?

    var body: some View {
        Group {
            if let vm {
                LogFeedContent(vm: vm)
            } else {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sessionId) {
            vm = LogFeedViewModel(store: env.store, sessionId: sessionId)
        }
    }
}

// MARK: - Content

private struct LogFeedContent: View {
    @Bindable var vm: LogFeedViewModel

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

            // "↓ N new events" pill — shown when paused with unseen events.
            // Click re-engages Follow, scrolls to bottom, and clears the count.
            if !vm.followTail && vm.unseenCount > 0 {
                Button {
                    vm.resumeFollow()
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
                .help("Scroll to latest and resume following")
            }

            Toggle("Follow", isOn: $vm.followTail)
                .toggleStyle(.switch)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    var body: some View {
        ScrollViewReader { proxy in
            Table(vm.page, selection: $vm.selectedEventId) {
                TableColumn("Level") { (event: EventRecord) in
                    HStack {
                        Circle()
                            .fill(event.level.displayColor)
                            .frame(width: 8, height: 8)
                        Text(event.level.displayName)
                            .font(.caption)
                            .foregroundStyle(event.level.displayColor)
                    }
                }
                .width(80)

                TableColumn("Message") { (event: EventRecord) in
                    Text(highlighted(event.message))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .width(min: 400, ideal: 600)

                TableColumn("Subsystem") { (event: EventRecord) in
                    Text(highlighted(event.subsystem))
                }
                .width(min: 150, ideal: 200)

                TableColumn("Category") { (event: EventRecord) in
                    Text(highlighted(event.category))
                }
                .width(min: 120, ideal: 150)

                TableColumn("Time") { (event: EventRecord) in
                    Text(event.timeOfDayWithMillis)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(120)
            }
            .contextMenu(forSelectionType: EventRecord.ID.self) { ids in
                rowContextMenu(for: events(forSelection: ids))
            }
            // Auto-scroll to the newest row when Follow is on. We watch
            // the last visible event id; whenever it changes, scroll
            // to it. SwiftUI's Table tags each row with its
            // Identifiable id, which ScrollViewReader can target.
            .onChange(of: vm.page.last?.id) { _, newLastId in
                guard vm.followTail, let newLastId else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newLastId, anchor: .bottom)
                }
            }
            // Re-engaging Follow should immediately jump to the bottom.
            .onChange(of: vm.followTail) { _, isFollowing in
                guard isFollowing, let lastId = vm.page.last?.id else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
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
            Button("Copy Message")   { copyToPasteboard(event.message) }
            Button("Copy Subsystem") { copyToPasteboard(event.subsystem) }
            if !event.category.isEmpty {
                Button("Copy Category") { copyToPasteboard(event.category) }
            }
            Button("Copy as JSON")   { copyToPasteboard(formatAsJSON([event])) }
        }
        Section {
            Button("Filter to this Subsystem") {
                vm.filter.search = event.subsystem
                vm.filter.searchIsRegex = false
            }
            Button("Exclude this Subsystem") {
                vm.filter.exclude = event.subsystem
                vm.filter.excludeIsRegex = false
            }
        }
        if !event.category.isEmpty {
            Section {
                Button("Filter to this Category") {
                    vm.filter.search = event.category
                    vm.filter.searchIsRegex = false
                }
                Button("Exclude this Category") {
                    vm.filter.exclude = event.category
                    vm.filter.excludeIsRegex = false
                }
            }
        }
    }

    @ViewBuilder
    private func multiRowMenu(for events: [EventRecord]) -> some View {
        Button("Copy \(events.count) Messages") {
            let messages = events.map(\.message).joined(separator: "\n")
            copyToPasteboard(messages)
        }
        Button("Copy \(events.count) Events as JSON") {
            copyToPasteboard(formatAsJSON(events))
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
