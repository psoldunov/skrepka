import SwiftUI

/// The three settings panes.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case history
    case privacy
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .history: "History"
        case .privacy: "Privacy"
        case .diagnostics: "Status"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        }
    }
}

/// A segmented control on a glass track.
///
/// All three segments live inside one track so the bar reads as a single
/// control; the selected one is a brighter piece of glass that morphs between
/// positions via `glassEffectID`. A saturated accent fill was tried first and
/// looked like a blob with two loose icons beside it.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    @Namespace private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let trackPadding: CGFloat = 4

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    segment(for: tab)
                }
            }
            .padding(Self.trackPadding)
            .background(track)
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(for tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.26)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Before the glass modifiers: applied after them the segment reports no
        // accessibility name at all, because the glass wraps it in a new
        // element.
        .accessibilityLabel(Text(tab.title))
        .accessibilityIdentifier(tab.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // The glass goes on the segment itself. In a `.background` it renders
        // over the label instead of behind it, and `.identity` is how an
        // unselected segment opts out — there is no `glassEffect(isEnabled:)`
        // overload in the macOS 26 SDK.
        .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(tab, in: namespace)
    }

    @ViewBuilder
    private var track: some View {
        if reduceTransparency {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        } else {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }
}
