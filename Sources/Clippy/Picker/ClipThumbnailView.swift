import ClippyCore
import SwiftUI

/// The leading visual on a row.
///
/// Image entries get a real preview wide enough to recognise the picture from —
/// a 30-point square tells you nothing about a screenshot. Everything else gets
/// a square kind symbol, so text rows stay compact.
struct ClipThumbnailView: View {
    let item: ClipSummary

    /// Square side for non-image rows.
    static let symbolSide: CGFloat = 30
    /// Image rows get a landscape preview at this size.
    static let previewSize = CGSize(width: 84, height: 48)

    /// The decoded thumbnail, or nil when the row should show a kind symbol.
    ///
    /// Cached: this is read on every body evaluation, and decoding a 256-point
    /// PNG per visible row per keystroke is real work on the main actor.
    private var previewImage: NSImage? {
        guard !item.isConcealed else { return nil }
        return ThumbnailCache.shared.image(for: item)
    }

    var body: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                    .clipped()
                    .background(Color.primary.opacity(0.06))
            } else {
                Image(systemName: item.isConcealed ? "lock.fill" : item.kind.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.symbolSide, height: Self.symbolSide)
                    .background(Color.primary.opacity(0.06))
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .accessibilityLabel(item.kind.displayName)
    }
}
