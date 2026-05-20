//
//  CheckForUpdatesView.swift
//  Beaver
//
//  Lightweight "Check for Updates…" menu item that talks to Sparkle's
//  `SPUUpdater`. Owns the small published bool that disables the menu
//  item while a check is already in flight — without this, you can
//  spam-click the menu and queue duplicate update dialogs.
//
//  Pattern is from Sparkle 2's SwiftUI docs:
//  https://sparkle-project.org/documentation/programmatic-setup/#swiftui
//

import Sparkle
import SwiftUI

/// Drives the "Check for Updates…" menu item's enabled state. Sparkle
/// exposes `canCheckForUpdates` as a KVO-observable property on
/// `SPUUpdater`; we mirror it into an `@Published` so SwiftUI updates
/// the menu when a check starts/finishes.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
