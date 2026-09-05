import SkrepkaCore
import SwiftUI

/// The leading visual on a row.
///
/// Anything Skrepka could render a picture of — image data, and image files —
/// gets a real preview wide enough to recognise the picture from; a 30-point
/// square tells you nothing about a screenshot. Everything else gets a square
/// kind symbol, so text rows stay compact.
struct ClipThumbnailView: View {
    let item: ClipSummary
    /// Already resolved by the list, from `ThumbnailCache`. Nil means a kind
    /// symbol — the entry has no picture, is concealed, or would not decode.
    ///
    /// Handed in rather than looked up here so the resolution happens once per
    /// row that is actually built, and synchronously: a row that fetched its own
    /// preview asynchronously would draw a symbol first and swap it for the
    /// picture a frame later, which reads as the list flickering as it scrolls.
    let image: NSImage?

    /// Square side for non-image rows.
    static let symbolSide: CGFloat = 30
    /// Image rows get a landscape preview at this size.
    static let previewSize = CGSize(width: 84, height: 48)

    var body: some View {
        Group {
            if let image {
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
