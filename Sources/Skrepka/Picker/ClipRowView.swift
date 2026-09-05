import SkrepkaCore
import SwiftUI

/// One history entry.
///
/// Flat by design: the panel already provides the glass surface, so a row is
/// just content plus a selection fill. That is what makes the list read as one
/// object rather than a stack of pills.
struct ClipRowView: View {
    let item: ClipSummary
    let index: Int
    let isSelected: Bool
    /// Resolved by the list, so the row draws its picture in the same pass it
    /// draws everything else. See ``ClipThumbnailView/image``.
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 11) {
            ClipThumbnailView(item: item, image: thumbnail)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))

                subtitle
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(Color.white.opacity(0.75))
                            : AnyShapeStyle(.secondary)
                    )
            }

            Spacer(minLength: 8)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(Color.white.opacity(0.9))
                            : AnyShapeStyle(.secondary)
                    )
            }
            if index < 9 {
                ShortcutBadge(number: index + 1, isSelected: isSelected)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: PickerMetrics.rowHeight(for: item), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : .clear)
        }
        .contentShape(.rect(cornerRadius: 8))
    }

    private var subtitle: Text {
        var parts: [String] = [item.kind.displayName]
        if let imageSize = item.imageSize {
            parts.append(imageSize.description)
        }
        if item.lineCount > 1 {
            parts.append("\(item.lineCount) lines")
        }
        if let name = item.sourceBundleID.flatMap(AppNameCache.shared.displayName(forBundleID:)) {
            parts.append(name)
        }
        parts.append(item.createdAt.formatted(.relative(presentation: .numeric)))
        return Text(parts.joined(separator: " · "))
    }
}

/// The ⌘N affordance on the first nine rows.
private struct ShortcutBadge: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.tertiary)
            )
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
            }
    }
}
