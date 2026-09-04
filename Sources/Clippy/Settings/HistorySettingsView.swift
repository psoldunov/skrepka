import ClippyCore
import SwiftUI

/// Retention limits, a summary of what is stored, and the clear button.
struct HistorySettingsView: View {
    let coordinator: AppCoordinator

    @State private var isConfirmingClear = false

    private var preferences: Preferences { coordinator.preferences }

    private static let itemChoices: [Int?] = [100, 250, 500, 1000, 5000, nil]
    private static let ageChoices: [Int?] = [1, 7, 30, 90, 365, nil]

    var body: some View {
        HistorySummary(items: coordinator.store.items)

        SettingsCard(
            title: "Retention",
            footer: "Pinned entries are never discarded, whatever these say."
        ) {
            SettingsRow(title: "Keep at most", symbol: "tray.full") {
                Picker(
                    "",
                    selection: Binding(
                        get: { preferences.maximumItems },
                        set: {
                            preferences.maximumItems = $0
                            coordinator.preferencesChanged()
                        }
                    )
                ) {
                    ForEach(Self.itemChoices, id: \.self) { choice in
                        Text(choice.map { "\($0) items" } ?? "Unlimited").tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsRowSeparator()

            SettingsRow(title: "Discard after", symbol: "calendar") {
                Picker(
                    "",
                    selection: Binding(
                        get: { preferences.maximumAgeDays },
                        set: {
                            preferences.maximumAgeDays = $0
                            coordinator.preferencesChanged()
                        }
                    )
                ) {
                    ForEach(Self.ageChoices, id: \.self) { choice in
                        Text(choice.map(Self.ageLabel) ?? "Never").tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsCard(
            title: "Stored data",
            footer: "Clippy stores history in Application Support and never sends it anywhere."
        ) {
            SettingsRow(
                title: "Clear history",
                subtitle: "Remove stored entries from this Mac.",
                symbol: "trash"
            ) {
                Button("Clear…", role: .destructive) { isConfirmingClear = true }
                    .buttonStyle(.bordered)
            }
        }
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear, keeping pinned", role: .destructive) {
                coordinator.store.clear(keepingPinned: true)
            }
            Button("Clear everything", role: .destructive) {
                coordinator.store.clear(keepingPinned: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private static func ageLabel(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
}

/// Three glass tiles: what is actually in the store right now.
private struct HistorySummary: View {
    let items: [ClipSummary]

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                MetricTile(value: items.count, label: "Entries")
                MetricTile(value: items.count { $0.isPinned }, label: "Pinned")
                MetricTile(value: items.count(where: \.isPicture), label: "Images")
            }
        }
    }
}

/// Just the number and what it counts.
///
/// An icon per tile was tried and read as clutter — the caption already says
/// what the number is.
private struct MetricTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted())
                .font(.system(size: 25, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .glassSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
