//
//  ConnectTVSheet.swift
//  Beaver
//
//  D94: Connect a TV… — from the Connected pill's menu, the empty
//  "waiting for a device" screen and the app menu. Beaver reads the TV's
//  app over the Chrome DevTools Protocol (`TVBridge`).

import SwiftUI

/// A TV connected before, for one-click reconnect.
struct RecentTV: Codable, Hashable, Identifiable {
    var host: String
    var port: Int
    var name: String?
    var id: String { "\(host):\(port)" }
    var title: String { name ?? id }
}

/// The last few TVs, newest first, in `UserDefaults`.
enum RecentTVs {
    static let key = "recentTVs"

    static func load() -> [RecentTV] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentTV].self, from: $0) } ?? []
    }

    static func remember(_ tv: RecentTV) {
        let all = [tv] + load().filter { $0.id != tv.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(all.prefix(5))), forKey: key)
    }
}

struct ConnectTVSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var name = ""
    @State private var error: String?
    @State private var connecting: Task<Void, Never>?
    @State private var recent = RecentTVs.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect a TV").font(.title3.weight(.semibold))
                Text("Beaver reads the TV app's console over DevTools. The TV's developer mode must be on, and no other DevTools window attached to it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(recent) { tv in
                        Button { connect(host: tv.host, port: tv.port, name: tv.name) } label: {
                            Label(tv.name.map { "\($0) — \(tv.id)" } ?? tv.id, systemImage: "tv")
                        }
                        .buttonStyle(.link)
                        .disabled(connecting != nil)
                    }
                }
            }
            Form {
                TextField("IP address", text: $host, prompt: Text("192.168.1.40"))
                TextField("Port", text: $port, prompt: Text("9222"))
                Text("Vizio 9555 · Vidaa 9226 · others usually 9222")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $name, prompt: Text("Optional, e.g. Living room Vizio"))
            }
            .disabled(connecting != nil)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if connecting != nil {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    connecting?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") { connectTyped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || connecting != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// "192.168.1.40:9555" in the address field works too.
    private func connectTyped() {
        var address = host.trimmingCharacters(in: .whitespaces)
        var typedPort = port.trimmingCharacters(in: .whitespaces)
        let parts = address.split(separator: ":")
        if typedPort.isEmpty, parts.count == 2 {
            address = String(parts[0]); typedPort = String(parts[1])
        }
        guard let number = typedPort.isEmpty ? 9222 : Int(typedPort) else {
            error = "The port is a number, e.g. 9555."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        connect(host: address, port: number, name: trimmed.isEmpty ? nil : trimmed)
    }

    private func connect(host: String, port: Int, name: String?) {
        error = nil
        connecting = Task {
            defer { connecting = nil }
            do {
                let id = try await env.connectTV(host: host, port: port, name: name)
                guard !Task.isCancelled else { return }
                env.viewingSessionId = id
                env.selectedTab = .logs
                toasts.success("Connected \(name ?? "\(host):\(port)")")
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
