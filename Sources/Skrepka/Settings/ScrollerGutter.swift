import AppKit
import SwiftUI

/// Lays a `ScrollView`'s content out to one width whether or not it scrolls.
///
/// Overlay scrollers float over the content and cost it nothing. Legacy ones —
/// System Settings ▸ Appearance ▸ Show scroll bars ▸ Always, or a pointing
/// device that reports no scroll gestures — are laid out *beside* the content,
/// so a pane tall enough to scroll is drawn a scroller's width narrower than
/// one that fits. In the settings window, where every pane shares one scroll
/// view, that meant switching to Status redrew every card 17 points narrower.
///
/// It takes both halves below, and neither works alone:
///
/// - Clearing `autohidesScrollers` keeps the clip view the same width in every
///   pane. On its own it does not move the content: SwiftUI sizes a scroll
///   view's document view from the scroll view's own width when the content
///   fits, and only from the clip view's width when it scrolls. A pane that fit
///   therefore stayed full width while the clip narrowed around it, and lost
///   its right-hand padding to the scroller instead of its width.
/// - Padding the content by however far the document view overhangs the clip
///   view is what closes that gap: 17 points on a pane that fits, none on one
///   that scrolls, so both are laid out to the clip width.
///
/// Measuring the overhang rather than subtracting a constant is deliberate. A
/// constant has to be subtracted from the container width, which makes the
/// content fixed-width — and a SwiftUI `ScrollView` shrinks itself to fit
/// fixed-width content, so it reserves the gutter a second time out of its own
/// width and the padding comes out wrong again. The measurement leaves the
/// content flexible, and it is self-correcting: it re-reads on every layout
/// pass, so switching "Show scroll bars" or plugging in a mouse is picked up
/// without an observer.
///
/// Reserving the gutter rather than forcing `scrollerStyle` to `.overlay`: a
/// permanently visible scroller is exactly what "Always" asks for, and
/// overriding that setting in one window would take it away from someone who
/// chose it deliberately. Under overlay scrollers ``gutterWidth`` is zero and
/// the whole thing is inert, which is the common case and wants no change.
struct ScrollerGutter: ViewModifier {
    @State private var overhang: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.trailing, overhang)
            .background(GutterProbe(overhang: $overhang))
    }

    /// The most a scroller can cost the content beside it, right now.
    ///
    /// Only a bound on the measurement — the padding actually applied is what
    /// the document view overhangs by. The branch is on
    /// `preferredScrollerStyle` rather than on the width, because
    /// `scrollerWidth(for:scrollerStyle:)` answers 17 for `.overlay` too and an
    /// overlay scroller is drawn *over* the content, taking none of it.
    static var gutterWidth: CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
}

extension View {
    /// Keeps this scroll content one width whether or not it is tall enough to
    /// scroll. See ``ScrollerGutter``.
    ///
    /// Applied to the content inside the `ScrollView`, not around it, so the
    /// probe reaches the right scroll view and the padding lands on the
    /// document view.
    func scrollerGutter() -> some View {
        modifier(ScrollerGutter())
    }
}

// MARK: - Reading the scroll view

/// Reaches the `NSScrollView` SwiftUI builds around the content, keeps its
/// scrollers on screen, and reports how far the content overhangs them.
///
/// There is no SwiftUI equivalent: `scrollIndicators(_:)` says whether an
/// indicator is shown, not whether showing it costs the content any width.
private struct GutterProbe: NSViewRepresentable {
    @Binding var overhang: CGFloat

    func makeNSView(context: Context) -> NSView {
        GutterProbeView { overhang = $0 }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-handed on every update: the binding captured at construction
        // belongs to the view value that made it, and that one is long gone.
        (nsView as? GutterProbeView)?.report = { overhang = $0 }
    }
}

private final class GutterProbeView: NSView {
    var report: (CGFloat) -> Void
    /// The last overhang handed to SwiftUI. Nil until the first measurement, so
    /// the opening value is always sent even when it is zero.
    private var reported: CGFloat?

    init(report: @escaping (CGFloat) -> Void) {
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // NSView's designated initializer from a nib. This view only ever
        // exists behind ``ScrollerGutter``, so there is nothing to decode.
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        measure()
    }

    /// Re-measured on every layout pass rather than read once.
    ///
    /// `NSScroller.h` says AppKit sends `-setScrollerStyle:` to every scroll
    /// view when the user's "Show scroll bars" preference changes and makes
    /// each one re-tile; this view is inside the document view, so it is laid
    /// out again as part of that. That is what makes the gutter follow the
    /// setting on a window built once and cached for the life of the process.
    override func layout() {
        super.layout()
        measure()
    }

    /// Both halves of the fix, in the order they have to happen.
    ///
    /// `autohidesScrollers` is written only on a change:
    /// `setAutohidesScrollers:` re-tiles the scroll view, and re-tiling from
    /// inside `layout()` is how a layout loop starts. The overhang is likewise
    /// only reported when it moves, so a steady state costs no SwiftUI update.
    /// It settles in three passes and stays there — including when the extra
    /// padding is enough to rewrap a line.
    private func measure() {
        guard let scrollView = enclosingScrollView else { return }
        if scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = false
        }
        guard let documentView = scrollView.documentView else { return }
        let clipped = documentView.frame.width - scrollView.contentView.frame.width
        let overhang = min(max(clipped, 0), ScrollerGutter.gutterWidth)
        guard overhang != reported else { return }
        reported = overhang
        report(overhang)
    }
}
