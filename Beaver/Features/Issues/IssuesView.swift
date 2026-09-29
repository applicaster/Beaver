//
//  IssuesView.swift
//  Beaver
//

import AppKit
import SwiftUI

/// The Issues tab (D95): the session's warnings and errors grouped by
/// signature. A row opens the Log feed filtered to exactly its events,
/// with the first one selected.
struct IssuesView: View {
    @Bindable var vm: IssuesViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var showingHelp = false

    /// What the tab does, said plainly (the user asked "how is this different
    /// from filtering errors?"): shown in ⓘ and, short, under the bar.
    static let help = """
        Issues lists the session's problems once each, not every occurrence.

        • What counts: lines the app itself logged at level error (and warning, unless "Errors only"). Beaver doesn't guess from the text — an app that logs a failure as info won't show here. Failed network requests are in the Network tab.
        • One row per problem: lines of the same subsystem whose text differs only in numbers, ids, UUIDs, times or URL query values are one issue — "Token refresh failed (attempt 1)" and "(attempt 3)" count together. The same rule as Compare.
        • Why not just filter errors: a filter shows every line, so 400 copies of one error hide the one new problem. Here that's one row "×400", and the rare one is its own row with when it started.
        • Each row: how many times, first and last time, and a timeline across the session. Click it to see exactly those lines in the Log feed, starting at the first.
        • Ignore hides known noise for this app, in this and future sessions (Show ignored brings it back).
        • Agents get the same list with issues_list.
        """

    var body: some View {
        VStack(spacing: 0) {
            bar
            Text("Each row is one problem the app logged, however many times — the same error with different numbers or ids counts once.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if !vm.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.rows.isEmpty {
                ContentUnavailableView(
                    vm.errorsOnly ? "No errors" : "No issues",
                    systemImage: "checkmark.seal",
                    description: Text(vm.ignoredCount > 0
                                      ? "Nothing but what you ignored (\(vm.ignoredCount))."
                                      : "This session logged no \(vm.errorsOnly ? "errors" : "warnings or errors").")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.rows) { g in
                    IssueRow(group: g, isFresh: vm.fresh.contains(g.signature))
                        .contentShape(Rectangle())
                        .onTapGesture { open(g) }
                        .contextMenu { menu(g) }
                        .listRowBackground(vm.fresh.contains(g.signature) ? Color.accentColor.opacity(0.15) : nil)
                }
                .animation(.default, value: vm.rows.map(\.signature))
                .animation(.easeOut(duration: 0.6), value: vm.fresh)
                .textSelection(.disabled)
                if vm.report.capped {
                    Text("Over \(Issues.cap) signatures: the rarest aren't listed.")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $vm.errorsOnly) {
                Text("Warnings and errors").tag(false)
                Text("Errors only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Sort", selection: $vm.sort) {
                ForEach(Issues.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            if vm.ignoredCount > 0 || vm.showIgnored {
                Toggle("Show ignored (\(vm.ignoredCount))", isOn: $vm.showIgnored)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Spacer()
            Text("\(vm.report.errors) errors · \(vm.report.warnings) warnings")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { showingHelp.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("What Issues does")
                .accessibilityLabel("What Issues does")
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    Text(Self.help)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 380, alignment: .leading)
                        .padding(14)
                        .textSelection(.enabled)
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    @ViewBuilder
    private func menu(_ g: Issues.Group) -> some View {
        Button("Show in Log feed") { open(g) }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(g.copyText, forType: .string)
            toasts.success("Copied the issue")
        }
        Divider()
        Button(g.ignored ? "Unignore" : "Ignore for this app") {
            Task {
                do {
                    try await vm.setIgnored(!g.ignored, g)
                    toasts.success(g.ignored ? "Showing it again" : "Ignored in every session of this app")
                } catch {
                    toasts.error(error.localizedDescription)
                }
            }
        }
    }

    /// The Log feed with exactly this group's events, the first selected.
    private func open(_ g: Issues.Group) {
        env.activeFilter = g.filter(minLevel: vm.minLevel)
        env.selectedEventId = g.firstId
        env.selectedTab = .logs
    }
}

private struct IssueRow: View {
    let group: Issues.Group
    let isFresh: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(group.level.displayColor).frame(width: 8, height: 8)
                .help(group.level.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.pattern)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(group.example)
                HStack(spacing: 6) {
                    Text(EventRecord.shortSubsystem(group.subsystem)).help(group.subsystem)
                    Text("·")
                    Text("\(group.firstAt.formatted(date: .omitted, time: .standard)) – \(group.lastAt.formatted(date: .omitted, time: .standard))")
                        .monospacedDigit()
                    if group.ignored { Text("· ignored").italic() }
                    if isFresh { Text("· new").foregroundStyle(Color.accentColor).bold() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Sparkline(counts: group.histogram, color: group.level.displayColor)
                .frame(width: 90, height: 18)
                .help("When it happened, first to last event of the session")
            Text("×\(group.count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(group.ignored ? 0.55 : 1)
    }
}

/// Small bars, one per histogram bucket.
private struct Sparkline: View {
    let counts: [Int]
    let color: Color

    var body: some View {
        let top = max(counts.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(counts.indices, id: \.self) { i in
                Rectangle()
                    .fill(counts[i] > 0 ? color : Color.secondary.opacity(0.2))
                    .frame(height: counts[i] > 0 ? max(2, 18 * CGFloat(counts[i]) / CGFloat(top)) : 1)
            }
        }
        .accessibilityLabel("Histogram")
    }
}
