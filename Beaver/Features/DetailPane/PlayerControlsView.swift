//
//  PlayerControlsView.swift
//  Beaver
//
//  D99: pinned under the Log feed's detail pane while the viewed live app
//  has the X-Ray `player` toolbox and a player is active. A fixed set of
//  controls for that one toolbox — not a runner for any tool (D91 was
//  rejected).

import SwiftUI

struct PlayerControlsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var poller: PlayerPoller?
    /// Where the thumb is while the user drags it; the seek goes on release.
    @State private var dragTo: Double?

    private var liveSessionId: Int64? {
        env.viewingSessionId.flatMap { env.isLive($0) ? $0 : nil }
    }

    var body: some View {
        Group {
            if let poller, poller.available, poller.sessionId == liveSessionId,
               let state = poller.state, state.active {
                VStack(spacing: 0) {
                    Divider()
                    panel(poller, state).padding(12)
                }
            }
        }
        .task(id: liveSessionId) {
            guard let liveSessionId else { poller = nil; return }
            let p = PlayerPoller(device: env, sessionId: liveSessionId)
            poller = p
            await p.run()
        }
    }

    // MARK: - Panel

    private func panel(_ poller: PlayerPoller, _ s: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("PLAYER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                // ⌥⌘: plain Space and arrows belong to the feed; ⌃Space is macOS's input switch.
                button(s.playing ? "pause.fill" : "play.fill", s.playing ? "Pause (⌥⌘P)" : "Play (⌥⌘P)",
                       s.playing ? .pause : .play, poller)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                button("gobackward.10", "Back 10 s (⌥⌘←)", .offset(-10), poller)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!s.canSeek)
                button("goforward.10", "Forward 10 s (⌥⌘→)", .offset(10), poller)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!s.canSeek)
                if s.streamType == .liveDvr {
                    Button("Live") { send(.goLive, poller) }
                        .controlSize(.small)
                        .disabled(!s.canSeek)
                        .help("Jump to the live edge")
                }
            }
            bar(poller, s)
            HStack {
                Text(time(poller, s)).monospacedDigit()
                Spacer()
                Text(badges(s)).foregroundStyle(s.ad ? .orange : .secondary)
            }
            .font(.caption)
            if let title = s.title ?? s.entryId {
                Text(s.entryId.map { "\(title) · \($0)" } ?? title)
                    .font(.caption).lineLimit(2).textSelection(.enabled)
            }
            if let error = s.lastError {
                Text("Last error: \(error)").font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            }
            if let reason = poller.reason {
                Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private func button(_ symbol: String, _ help: String, _ command: PlayerCommand,
                        _ poller: PlayerPoller) -> some View {
        Button { send(command, poller) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func send(_ command: PlayerCommand, _ poller: PlayerPoller) {
        Task { await poller.send(command) }
    }

    // MARK: - Bar

    private func bar(_ poller: PlayerPoller, _ s: PlayerState) -> some View {
        let length = poller.timeline?.length ?? 0
        let position = dragTo ?? poller.timeline?.position ?? 0
        let breaks = poller.seen.merged(with: s.adBreaks)
        return GeometryReader { g in
            let x = { (t: Double) in length > 0 ? CGFloat(min(max(t / length, 0), 1)) * g.size.width : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(s.ad ? Color.orange : .accentColor).frame(width: x(position), height: 4)
                ForEach(breaks, id: \.self) { t in
                    Rectangle().fill(.orange).frame(width: 2, height: 10).offset(x: x(t) - 1)
                }
                Circle().fill(.white).shadow(radius: 1).frame(width: 12, height: 12).offset(x: x(position) - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard length > 0 else { return }
                    dragTo = Double(min(max(v.location.x / g.size.width, 0), 1)) * length
                }
                .onEnded { _ in
                    if let target = dragTo { send(.seek(target), poller) }
                    dragTo = nil
                })
        }
        .frame(height: 14)
        .disabled(!s.canSeek || length == 0)
        .opacity(s.canSeek && length > 0 ? 1 : 0.5)
        .help(breaks.isEmpty ? "Drag to seek" : "Drag to seek · orange ticks are ad breaks")
    }

    // MARK: - Text

    private func time(_ poller: PlayerPoller, _ s: PlayerState) -> String {
        guard let t = poller.timeline else { return s.streamType == .live ? "LIVE" : "—" }
        return "\(Self.clock(dragTo ?? t.position)) / \(Self.clock(t.length))"
    }

    private func badges(_ s: PlayerState) -> String {
        var out = [s.ad ? "AD" : s.buffering ? "BUFFERING" : s.playing ? "PLAYING" : "PAUSED"]
        switch s.streamType {
        case .vod: out.append("VOD")
        case .live: out.append("LIVE")
        case .liveDvr: out.append("LIVE · DVR")
        case nil: break
        }
        if let drm = s.drm { out.append(drm.isEmpty ? "DRM" : "DRM " + drm.joined(separator: "/")) }
        if s.muted { out.append("MUTED") }
        if s.casting { out.append("CASTING") }
        if let role = s.role, role != "Primary" { out.append(role.uppercased()) }
        return out.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(max(seconds, 0).rounded(.down))
        let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
