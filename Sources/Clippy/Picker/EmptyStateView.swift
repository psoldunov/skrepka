import SwiftUI

/// Shown when the history is empty, or when nothing matches the query.
struct EmptyStateView: View {
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasQuery ? "magnifyingglass" : "clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            Text(hasQuery ? "No matches" : "Nothing copied yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text(
                hasQuery
                    ? "Try a shorter search."
                    : "Copy something and it will show up here."
            )
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
        }
        .padding(30)
    }
}
