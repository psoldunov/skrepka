import SwiftUI

/// The key hints along the bottom edge of the panel.
struct FooterHintsView: View {
    private struct Hint: Identifiable {
        let keys: [String]
        let label: String
        var id: String { keys.joined() }
    }

    private static let hints: [Hint] = [
        Hint(keys: ["↑", "↓"], label: "Navigate"),
        Hint(keys: ["↩"], label: "Paste"),
        Hint(keys: ["⇧", "⌘", "↩"], label: "Plain text"),
        Hint(keys: ["⌘", "P"], label: "Pin"),
        Hint(keys: ["esc"], label: "Close"),
    ]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.hints) { hint in
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        ForEach(hint.keys, id: \.self) { KeyCap(symbol: $0) }
                    }
                    Text(hint.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One keyboard key, drawn as a small cap so the hints read as keys rather than
/// as punctuation that wandered into the sentence.
struct KeyCap: View {
    let symbol: String

    private var isWide: Bool { symbol.count > 1 }

    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: isWide ? nil : 17, minHeight: 17)
            .padding(.horizontal, isWide ? 5 : 0)
            .background {
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4.5)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                    }
            }
            .fixedSize()
    }
}
