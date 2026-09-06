import AppKit
import SwiftUI

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

/// Gives a permission row's trailing control the same width in every state.
///
/// Without it the row is sized by whichever control happens to be on screen, so
/// swapping a tick for "Open Settings" narrows the text column, wraps the
/// subtitle onto a second line and grows the row — the window jumps as a
/// permission changes hands.
///
/// The width comes from an invisible copy of the longest label rather than a
/// constant, because a constant is wrong in both directions: too small and
/// "Open Settings" truncates silently under Accessibility ▸ Bold Text, too
/// large and every spare point comes out of the text column beside it, where
/// the subtitles then wrap. `hidden()` documents that a view "remains in the
/// view hierarchy and affects layout", so the stack is always exactly as wide
/// as that button really renders, at whatever font metrics are in force.
struct PermissionControl: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button(SettingsMetrics.widestPermissionLabel) {}
                .font(SettingsMetrics.controlFont)
                .hidden()
                // `hidden()` promises no interaction, but says nothing about
                // the accessibility tree — VoiceOver must not find a button
                // that is not there.
                .accessibilityHidden(true)
            content
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = SettingsMetrics.cornerRadius) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }

    /// Pins a permission row's trailing control to one width in every state.
    /// See ``PermissionControl``.
    func permissionControl() -> some View {
        modifier(PermissionControl())
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

/// A row's verdict, as a symbol.
///
/// A symbol and not a word: three "OK" pills stacked down a card read as a
/// wall of text, and the tick is the same one the welcome window shows, so a
/// granted permission looks identical wherever it appears. The label is
/// carried for assistive technology, since the colour is doing real work.
struct StatusIndicator: View {
    enum State {
        case good
        case warning
        case bad
        case neutral

        var symbol: String {
            switch self {
            case .good: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .bad: "xmark.octagon.fill"
            case .neutral: "minus.circle.fill"
            }
        }

        /// What VoiceOver reads in place of the symbol.
        var label: String {
            switch self {
            case .good: "OK"
            case .warning: "Needs attention"
            case .bad: "Blocked"
            case .neutral: "Off"
            }
        }

        var color: Color {
            switch self {
            case .good: .green
            case .warning: .orange
            case .bad: .red
            case .neutral: .secondary
            }
        }
    }

    let state: State

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: 14))
            .foregroundStyle(state.color)
            .accessibilityLabel(state.label)
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
