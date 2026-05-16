//
//  SessionsView.swift
//  LoggerNext
//

import SwiftUI

struct SessionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm: SessionsViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if vm == nil {
                vm = SessionsViewModel(store: env.store)
            }
        }
    }

    @ViewBuilder
    private func content(vm: SessionsViewModel) -> some View {
        @Bindable var env = env
        List(vm.sessions, selection: $env.viewingSessionId) { item in
            HStack(spacing: 12) {
                Image(systemName: item.iconName)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(Optional(item.id))
            .contentShape(Rectangle())
        }
        .overlay {
            if vm.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Connect a mobile client to record one.")
                )
            }
        }
    }
}
