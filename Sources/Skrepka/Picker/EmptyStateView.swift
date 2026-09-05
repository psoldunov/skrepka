import SkrepkaCore
import SwiftUI

/// Shown when the history is empty, or when nothing matches the query.
struct EmptyStateView: View {
    let hasQuery: Bool
    /// Skrepka is not allowed to read the clipboard. Saying "nothing copied
    /// yet" in that state is a lie the user cannot act on.
    var isBlocked = false

    var body: some View {
        VStack(spacing: 8) {
            glyph

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    /// What sits above the wording. An idle history is the one state that is
    /// about Skrepka rather than about something going wrong, so it shows the
    /// app's own mark; the other two describe the problem and keep a system
    /// symbol.
    private enum Glyph {
        case mark
        case system(name: String, warning: Bool)
    }

    private var glyphKind: Glyph {
        if isBlocked { return .system(name: "exclamationmark.triangle", warning: true) }
        return hasQuery ? .system(name: "magnifyingglass", warning: false) : .mark
    }

    @ViewBuilder private var glyph: some View {
        switch glyphKind {
        case .mark:
            PaperclipMark()
                .fill(.tertiary)
                .frame(width: 34, height: 34)
        case .system(let name, let warning):
            Image(systemName: name)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        }
    }

    /// The blocked wording comes from ``DiagnosticsProblem``, which owns it for
    /// the menu bar row and the Status pane too — three surfaces, one sentence.
    private var title: String {
        if isBlocked { return DiagnosticsProblem.clipboardAccessDenied.headline }
        return hasQuery ? "No matches" : "Nothing copied yet"
    }

    private var detail: String {
        if isBlocked { return DiagnosticsProblem.clipboardAccessDenied.remedy }
        return hasQuery ? "Try a shorter search." : "Copy something and it will show up here."
    }
}
