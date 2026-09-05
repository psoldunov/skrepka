import SwiftUI

/// The search row along the top of the panel.
///
/// A plain `TextField`, not `.searchable`: on macOS that resolves to toolbar
/// placement and needs a `NavigationSplitView` or toolbar host, neither of
/// which a borderless panel has.
struct SearchField: View {
    @Binding var text: String
    let resultCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search clipboard…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))

            if !text.isEmpty {
                Text("\(resultCount)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
