import AppKit
import SwiftUI

/// A copy of several files, drawn as a pile of their own icons.
///
/// The Dock draws a folder this way and it is read at a glance: a row showing
/// three overlapping icons is three things before a single word of the subtitle
/// has been read, where one preview with a badge on it is one thing with a
/// number attached.
///
/// Front icon upright and full size; the ones behind it smaller, lifted, and
/// tilted apart so each is visible without any of them competing with the front.
/// Icons rather than a generic card, because the whole point is recognising
/// *which* files — the app's own artwork, the folder, the PDF.
struct FileIconStackView: View {
    /// Icons front first, as ``ClipSummary/stackIcons`` stores them.
    let images: [NSImage]

    /// Nil when there is nothing to stack, so the row can fall through to its
    /// preview or its kind symbol with one `if let` instead of two checks that
    /// could disagree.
    init?(images: [NSImage]) {
        guard !images.isEmpty else { return nil }
        self.images = images
    }

    /// Side of the front icon. The tile is larger than this so the layers behind
    /// have somewhere to lean.
    ///
    /// These numbers were chosen by rendering the stack and looking at it, from
    /// four candidates the user picked between. This is the tight one: the
    /// layers behind peek out rather than fan out, which keeps a list of rows
    /// calm at the cost of a copy of three reading much like a copy of two when
    /// every file wears the same icon. The badge beside it carries the count,
    /// which is what makes the quiet version affordable.
    private static let frontSide: CGFloat = 34
    /// How much smaller each layer behind the front is drawn.
    private static let scaleStep: CGFloat = 0.12
    /// How far each layer behind is lifted, in points.
    private static let riseStep: CGFloat = 4
    /// How far each layer behind is tilted, in degrees, alternating sides so a
    /// stack of three fans rather than leans.
    private static let tiltStep: Double = 8

    var body: some View {
        ZStack {
            // Back to front: SwiftUI draws later children on top, and index 0
            // is the file the entry leads with.
            ForEach(layers.reversed()) { layer in
                Image(nsImage: layer.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side(at: layer.id), height: side(at: layer.id))
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .rotationEffect(.degrees(tilt(at: layer.id)), anchor: .bottom)
                    .offset(y: -rise(at: layer.id))
            }
        }
        .frame(width: ClipThumbnailView.stackSize.width, height: ClipThumbnailView.stackSize.height)
    }

    /// One icon and how far back it sits. Depth is the identity: three copies of
    /// the same document icon are three layers, so the picture cannot be.
    private struct Layer: Identifiable {
        let id: Int
        let image: NSImage
    }

    private var layers: [Layer] {
        images.enumerated().map { Layer(id: $0.offset, image: $0.element) }
    }

    private func side(at depth: Int) -> CGFloat {
        Self.frontSide * (1 - Self.scaleStep * CGFloat(depth))
    }

    private func rise(at depth: Int) -> CGFloat {
        Self.riseStep * CGFloat(depth)
    }

    /// Right, then left — a fan rather than a lean.
    private func tilt(at depth: Int) -> Double {
        guard depth > 0 else { return 0 }
        return depth.isMultiple(of: 2) ? -Self.tiltStep : Self.tiltStep
    }
}
