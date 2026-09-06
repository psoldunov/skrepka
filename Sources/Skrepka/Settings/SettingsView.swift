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
    ///
    /// It moves with ``SettingsMetrics/tabBarTopPadding``: dropping the tab bar
    /// clear of the traffic lights pushes every pane down by the same amount,
    /// and a window left at its old height would have started scrolling
    /// General to pay for it.
    static let windowSize = CGSize(width: 560, height: 471)

    let coordinator: AppCoordinator
    /// Owned by the window controller so `show(tab:)` can jump straight to a
    /// pane — the window is cached and reused, so a `@State` here would ignore
    /// every request after the first.
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
                // Below the title bar band rather than level with it: the bar
                // is centred and five tabs wide, so it now reaches back across
                // the traffic lights.
                .padding(.top, SettingsMetrics.tabBarTopPadding)
                .padding(.bottom, SettingsMetrics.tabBarBottomPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    pane
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.horizontalPadding)
                .padding(.bottom, 24)
                // Inside the content, so it reaches this scroll view rather
                // than one further out. Keeps every pane the same width whether
                // or not it is tall enough to show a scroller.
                .scrollerGutter()
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
