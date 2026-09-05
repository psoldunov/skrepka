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
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isBlocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))

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

    private var symbol: String {
        if isBlocked { return "exclamationmark.triangle" }
        return hasQuery ? "magnifyingglass" : "clipboard"
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
