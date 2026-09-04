import SwiftUI

/// A hairline that stays visible on glass.
///
/// `Divider` renders against a control background and all but disappears on a
/// translucent panel, so the panel draws its own.
struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.11))
            .frame(minWidth: 1, minHeight: 1)
    }
}
