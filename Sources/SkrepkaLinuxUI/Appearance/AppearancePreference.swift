/// What the desktop says about how apps should look: dark or light, and the
/// accent colour.
///
/// The value the picker draws from and the appearance portal reports, kept as
/// plain data so the two meet here rather than knowing about each other. The
/// macOS picker never needs this — SwiftUI reads both from the environment —
/// and on Linux the answer comes over D-Bus from `xdg-desktop-portal`, which
/// KDE and GNOME both implement, or from GTK's own settings when there is no
/// portal to ask.
public struct AppearancePreference: Sendable, Equatable {
    /// `org.freedesktop.appearance color-scheme`: 0 no preference, 1 prefer
    /// dark, 2 prefer light.
    public enum ColorScheme: Sendable, Equatable {
        case noPreference
        case dark
        case light
    }

    public let colorScheme: ColorScheme
    /// `org.freedesktop.appearance accent-color`, or nil when the desktop sets
    /// none — which is also what a portal older than the key answers.
    public let accent: RGBColor?

    public init(colorScheme: ColorScheme, accent: RGBColor?) {
        self.colorScheme = colorScheme
        self.accent = accent
    }

    /// Nothing known yet: no preference and no accent.
    public static let unknown = AppearancePreference(colorScheme: .noPreference, accent: nil)
}

/// A colour as the appearance portal spells it: three channels in 0...1.
public struct RGBColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Channels outside 0...1 are clamped rather than refused. The portal
    /// documents the range, and "out of range" is a reason to draw the nearest
    /// colour rather than no colour.
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `rgb(r,g,b)` with 0...255 channels, which is what GTK CSS parses.
    public var cssValue: String {
        "rgb(\(Self.byte(red)),\(Self.byte(green)),\(Self.byte(blue)))"
    }

    private static func byte(_ channel: Double) -> Int {
        Int((channel * 255).rounded())
    }
}
