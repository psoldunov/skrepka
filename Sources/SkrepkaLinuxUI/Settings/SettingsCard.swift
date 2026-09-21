import CGtk4

/// A heading, a rounded card of rows with hairlines between them, and the
/// small print under it — the macOS pane's `SettingsCard`.
final class SettingsCard {
    /// The heading, card and footer together, for a page to append.
    let widget: GtkWidgetPointer
    private let card: GtkWidgetPointer
    private let heading: GtkWidgetPointer?
    private let footer: GtkWidgetPointer
    private var rowCount = 0

    init(title: String?, footer footerText: String? = nil) throws {
        guard let column = GtkBuild.box(vertical: true, spacing: 7),
            let card = GtkBuild.box(vertical: true, spacing: 0, classes: [SettingsStyle.card]),
            let footer = SettingsWidgets.footer(footerText ?? "")
        else { throw SettingsError.widgetCreationFailed }
        let heading = title.flatMap(SettingsWidgets.heading)
        if let heading { GtkBuild.append(heading, to: column) }
        GtkBuild.append(card, to: column)
        GtkBuild.append(footer, to: column)
        GtkBuild.setVisible(footer, !(footerText ?? "").isEmpty)

        self.widget = column
        self.card = card
        self.heading = heading
        self.footer = footer
    }

    /// Adds a row at the bottom, with a hairline above it unless it is the
    /// first.
    func add(_ row: GtkWidgetPointer) {
        if rowCount > 0, let separator = SettingsWidgets.separator() {
            GtkBuild.append(separator, to: card)
        }
        GtkBuild.append(row, to: card)
        rowCount += 1
    }

    /// Takes every row out, for a card whose rows are rebuilt.
    func removeAll() {
        SettingsWidgets.empty(card)
        rowCount = 0
    }

    func setTitle(_ text: String) {
        if let heading { GtkBuild.setText(heading, text.uppercased()) }
    }

    func setFooter(_ text: String) {
        GtkBuild.setText(footer, text)
        GtkBuild.setVisible(footer, !text.isEmpty)
    }
}
