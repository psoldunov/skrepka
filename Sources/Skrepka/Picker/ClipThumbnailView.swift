import SkrepkaCore
import SwiftUI

/// The leading visual on a row.
///
/// Anything Skrepka could render a picture of — image data, and image files —
/// gets a real preview wide enough to recognise the picture from; a 30-point
/// square tells you nothing about a screenshot. A copy of several files gets a
/// stack of their own icons, the way the Dock draws a folder. Everything else
/// gets a square kind symbol, so text rows stay compact.
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
    /// The icons of the files this entry holds, front first, or empty when it
    /// holds too few to stack. Resolved by the list for the same reason
    /// ``image`` is.
    let stackImages: [NSImage]

    /// Square side for non-image rows.
    static let symbolSide: CGFloat = 30
    /// Image rows get a landscape preview at this size.
    static let previewSize = CGSize(width: 84, height: 48)
    /// The tile a stack of file icons is drawn in. Squarer than a preview and
    /// taller than a symbol: the layers behind the front icon lean out of its
    /// footprint, and a tile that only fitted the front icon would crop them.
    static let stackSize = CGSize(width: 52, height: 48)

    var body: some View {
        Group {
            if let stack = FileIconStackView(images: stackImages) {
                stack
            } else if let image {
                preview(image)
            } else {
                symbol
            }
        }
        .overlay(alignment: .bottomTrailing) { fileCount }
        .accessibilityLabel(item.typeLabel)
    }

    private func preview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: Self.previewSize.width, height: Self.previewSize.height)
            .clipped()
            .background(Color.primary.opacity(0.06))
            .modifier(TileChrome())
    }

    private var symbol: some View {
        Image(systemName: item.isConcealed ? "lock.fill" : item.kind.symbolName)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: Self.symbolSide, height: Self.symbolSide)
            .background(Color.primary.opacity(0.06))
            .modifier(TileChrome())
    }

    /// How many files the row holds.
    ///
    /// Kept even beside a stack, because a stack is three icons whether the copy
    /// held three files or thirty: it says "several", and this says how many.
    @ViewBuilder private var fileCount: some View {
        if item.fileCount > 1, !item.isConcealed {
            Text("\(item.fileCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.thickMaterial, in: .rect(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .padding(3)
        }
    }
}

/// The rounded, hairline-bordered tile a preview or a kind symbol sits in.
///
/// Not applied to a stack: a pile of icons is not one object in a frame, and
/// boxing it would draw a border around the empty corners the tilt leaves.
private struct TileChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
    }
}
