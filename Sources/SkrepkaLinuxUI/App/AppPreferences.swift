import Foundation

/// What `app.json` holds: the settings `skrepka-gui` keeps for itself, which
/// the daemon never reads.
///
/// ```json
/// {"interfaceScale":125,"version":1}
/// ```
///
/// Its own file, beside the daemon's `config.json` in `$XDG_CONFIG_HOME/skrepka`
/// rather than inside it: the daemon owns that file and rewrites it whole on
/// every change, and it drops a key it does not know. How large the picker is
/// drawn is nothing the daemon, the CLI or another device has any use for.
///
/// Every member reads as its default when it is missing, so a file written by
/// an older build — or an empty `{}` — still loads. The version is written for
/// a later format to tell this one apart by, and not read: there is no older
/// format to migrate from.
struct AppPreferences: Codable, Sendable, Hashable {
    /// The format this build writes.
    static let currentVersion = 1

    /// ``InterfaceScale/percent``.
    let interfaceScale: Int

    static let `default` = AppPreferences(scale: .standard)

    init(scale: InterfaceScale) {
        interfaceScale = scale.percent
    }

    private enum CodingKeys: String, CodingKey {
        case version, interfaceScale
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interfaceScale =
            try container.decodeIfPresent(Int.self, forKey: .interfaceScale)
            ?? InterfaceScale.standard.percent
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(interfaceScale, forKey: .interfaceScale)
    }

    /// The interface size — the design size for a percentage out of
    /// ``InterfaceScale/accepted``, so a hand edit to 500 cannot draw a picker
    /// wider than the screen.
    var scale: InterfaceScale {
        InterfaceScale(percent: interfaceScale) ?? .standard
    }
}
