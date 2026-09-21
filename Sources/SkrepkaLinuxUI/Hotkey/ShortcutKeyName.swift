/// The names Skrepka shows for the keys of a shortcut.
///
/// A desktop's own description of a binding is shown as the desktop wrote it —
/// KDE's "Meta+Shift+V" stays Meta, because that is what KDE's own shortcut
/// settings and its confirmation dialog call the key. Only the portal's raw
/// grammar, which the app shows until the desktop has described the binding
/// (`LOGO+SHIFT+v`), is turned into those words.
enum ShortcutKeyName {
    /// The portal grammar's modifier names, and KDE's word for each.
    private static let portalModifiers: [String: String] = [
        "LOGO": "Meta", "SHIFT": "Shift", "CTRL": "Ctrl", "ALT": "Alt",
    ]

    /// One key's name as Skrepka shows it: a portal-grammar modifier in KDE's
    /// words, a single letter in capitals as it is printed on the key,
    /// anything else as given.
    static func display(_ key: String) -> String {
        if let name = portalModifiers[key] { return name }
        return key.count == 1 ? key.uppercased() : key
    }

    /// A `+`-joined chord with each key named by ``display(_:)``. Anything
    /// that is not a plain chord is returned as it is.
    static func display(chord: String) -> String {
        guard !chord.contains(" "), chord.contains("+") else { return chord }
        return chord.split(separator: "+", omittingEmptySubsequences: false)
            .map { display(String($0)) }
            .joined(separator: "+")
    }
}
