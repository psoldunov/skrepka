import SwiftUI

/// The line a row's subtitle gives way to while its bytes arrive from a peer:
/// a thin bar and how far along it is.
///
/// Sized to the subtitle it replaces — the 11-point line — so a row neither
/// grows when a transfer starts nor shrinks when it ends, and the list under
/// the pointer stays put.
struct TransferBarView: View {
    let fraction: Double
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(isSelected ? .white : .accentColor)
                .frame(maxWidth: 160)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.secondary)
                )
        }
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Arriving from another device")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}
