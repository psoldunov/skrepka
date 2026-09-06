import Foundation
import SkrepkaCore

/// Fixed sizes for every part of the picker.
///
/// The panel's height is computed from these before it is shown, rather than
/// measured from SwiftUI and fed back — resizing an `NSPanel` from inside a
/// layout pass tears the glass. Views apply the same constants, so what is
/// computed is what is drawn.
enum PickerMetrics {
    static let searchFieldHeight: CGFloat = 50
    static let footerHeight: CGFloat = 34
    static let separatorHeight: CGFloat = 1
    static let listVerticalPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 2
    static let standardRowHeight: CGFloat = 46
    static let imageRowHeight: CGFloat = 64
    static let emptyStateHeight: CGFloat = 150

    static var chromeHeight: CGFloat {
        searchFieldHeight + footerHeight + separatorHeight * 2
    }

    /// A row is tall when it draws something worth looking at: a picture, or the
    /// stack of icons a copy of several files gets. Both need the height; a kind
    /// symbol does not, and text rows stay compact because most rows are text.
    static func rowHeight(for item: ClipSummary) -> CGFloat {
        guard !item.isConcealed else { return standardRowHeight }
        return item.hasThumbnail || item.hasStackIcons ? imageRowHeight : standardRowHeight
    }

    /// Height the panel wants for these results, before the screen clamps it.
    static func panelHeight(for items: [ClipSummary]) -> CGFloat {
        guard !items.isEmpty else { return chromeHeight + emptyStateHeight }
        let rows = items.reduce(0) { $0 + rowHeight(for: $1) }
        let spacing = rowSpacing * CGFloat(max(0, items.count - 1))
        return chromeHeight + listVerticalPadding * 2 + rows + spacing
    }
}
