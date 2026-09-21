import CGtk4

/// A shortcut drawn as keycaps, one per key — or a word in their place when
/// there is no shortcut to draw.
final class KeycapRow {
    let widget: GtkWidgetPointer
    private let caps: GtkWidgetPointer
    private let word: GtkWidgetPointer
    private var drawn: [String]?

    init() throws {
        guard let box = GtkBuild.box(vertical: false, spacing: 6),
            let caps = GtkBuild.box(vertical: false, spacing: 4),
            let word = SettingsWidgets.value("")
        else { throw SettingsError.widgetCreationFailed }
        GtkBuild.append(caps, to: box)
        GtkBuild.append(word, to: box)
        self.widget = box
        self.caps = caps
        self.word = word
    }

    /// Draws `keys`, or `fallback` when there are none.
    func render(keys: [String], fallback: String) {
        GtkBuild.setText(word, fallback)
        GtkBuild.setVisible(word, keys.isEmpty)
        GtkBuild.setVisible(caps, !keys.isEmpty)
        guard keys != drawn else { return }
        drawn = keys
        SettingsWidgets.empty(caps)
        for key in keys {
            guard let cap = GtkBuild.label(key, classes: [SettingsStyle.keycap], centred: true) else {
                continue
            }
            GtkBuild.append(cap, to: caps)
        }
        skrepka_set_accessible_label(widget, keys.isEmpty ? fallback : keys.joined(separator: " plus "))
    }
}
