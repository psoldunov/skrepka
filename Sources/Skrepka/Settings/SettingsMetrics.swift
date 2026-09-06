import SwiftUI

/// The numbers the settings window and the welcome window are laid out to.
///
/// Both surfaces draw the same cards on the same glass, so the spacing lives
/// here rather than twice.
enum SettingsMetrics {
    static let cornerRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 18
    static let horizontalPadding: CGFloat = 22
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
    /// Clearance between the top of the window and the tab bar.
    ///
    /// The bar is centred, so a fifth tab widened it towards the traffic
    /// lights rather than away from them; sitting level with a toolbar left it
    /// crowding them on both axes at once. Dropping it clear of the title bar
    /// band is what buys the separation back, and ``SettingsView/windowSize``
    /// carries the same number so the tallest pane still fits underneath.
    static let tabBarTopPadding: CGFloat = 20
    static let tabBarBottomPadding: CGFloat = 16

    /// The longest label any permission row's trailing control shows.
    ///
    /// ``PermissionControl`` renders this invisibly behind every one of them to
    /// size the slot, so the width is measured rather than guessed. Add a
    /// longer label anywhere and this is the one line to update.
    static let widestPermissionLabel = "Open Settings"

    /// The type every small control in a card is set in — buttons, the shortcut
    /// readout, Done. Shared so ``PermissionControl``'s invisible sizer measures
    /// exactly what the visible button renders.
    static let controlFont = Font.system(size: 12, weight: .medium)
}
