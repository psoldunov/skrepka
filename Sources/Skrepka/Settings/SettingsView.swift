import SkrepkaCore
import SwiftUI

/// The settings window.
///
/// A vibrant window with a glass tab bar and glass cards, rather than a stock
/// `Form` in a grey box — the picker is made of Liquid Glass and settings
/// should look like the same application.
struct SettingsView: View {
    /// Fixed on purpose. Letting the window size itself to each pane made it
    /// grow from its bottom-left origin, so the tab bar jumped every time the
    /// user switched tabs. Pinning the top edge after the fact still showed the
    /// jump for a frame; not resizing at all is the only stable answer.
    ///
    /// The height is General's — the tallest pane — plus its bottom padding and
    /// nothing else. Panes that grow past it (the exclusion list, or General
    /// once a permission notice appears) scroll.
    static let windowSize = CGSize(width: 560, height: 460)

    let coordinator: AppCoordinator
    /// Owned by the window controller so `show(tab:)` can jump straight to a
    /// pane — the window is cached and reused, so a `@State` here would ignore
    /// every request after the first.
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
                // Sits in the title bar band, level with the traffic lights,
                // the way a toolbar would — anything lower leaves an empty
                // strip across the top of the window.
                .padding(.top, 9)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    pane
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.horizontalPadding)
                .padding(.bottom, 24)
            }
            // Only bounces when a pane is genuinely taller than the window —
            // the exclusion list is the one that grows.
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(SettingsBackdrop().ignoresSafeArea())
        // On the window rather than on the Sync pane: a peer can ask to pair
        // while the user is looking at any tab, and a sheet attached to a view
        // that is not on screen never appears.
        .sheet(
            item: Binding(
                get: { coordinator.sync.pendingPairing },
                set: { if $0 == nil { coordinator.sync.dismissPairing() } }
            )
        ) { pairing in
            PairingSheet(
                pairing: pairing,
                confirm: { coordinator.sync.answerPairing(true) },
                cancel: { coordinator.sync.dismissPairing() }
            )
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selection {
        case .general:
            GeneralSettingsView(coordinator: coordinator)
        case .history:
            HistorySettingsView(coordinator: coordinator)
        case .privacy:
            PrivacySettingsView(preferences: coordinator.preferences) {
                coordinator.preferencesChanged()
            }
        case .sync:
            SyncSettingsView(coordinator: coordinator)
        case .diagnostics:
            DiagnosticsSettingsView(coordinator: coordinator)
        }
    }
}
