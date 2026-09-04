import AppKit
import SwiftUI

/// Shared furniture for the settings window.
///
/// The window is transparent and vibrant, with glass cards floating on it —
/// so the chrome here is what carries the material, not a `Form`.
enum SettingsMetrics {
    static let cornerRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 18
    static let horizontalPadding: CGFloat = 22
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
}

/// Puts a view on a glass surface.
///
/// Applied to the content itself, never via `.background`: a glass background
/// renders *over* what it backs and blurs it into an empty box. Reduce
/// Transparency swaps the material, because the macOS 26 SDK ships no
/// `glassEffect(isEnabled:)` overload.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = SettingsMetrics.cornerRadius

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = SettingsMetrics.cornerRadius) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

/// A titled group of rows on one glass surface.
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface()

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// One line inside a ``SettingsCard``: label, optional explanation, trailing
/// control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 11) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}

/// Hairline between rows in a card. Inset so it reads as a divider rather than
/// a cut across the glass.
struct SettingsRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, SettingsMetrics.rowHorizontalPadding)
    }
}

/// A status line for something that needs the user's attention, and the one
/// button that resolves it.
struct SettingsNotice: View {
    enum Tone {
        case warning
        case error

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let tone: Tone
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: tone.symbol)
                .font(.system(size: 12))
                .foregroundStyle(tone.color)

            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(tone.color.opacity(0.10))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// The vibrant base the glass cards sit on.
///
/// The window itself is transparent, so without this the cards would sample the
/// desktop directly and text would fight whatever wallpaper is behind it.
struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
