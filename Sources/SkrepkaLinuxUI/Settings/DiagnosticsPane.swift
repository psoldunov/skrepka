import CGtk4

/// The Status pane's widgets — `diagnostics` in code, "Status" on screen as
/// on the Mac: the overview and problems first, then the
/// clipboard, network, storage and daemon cards, then Copy Report.
///
/// Decides nothing: ``render(_:)`` copies a ``DiagnosticsPaneState`` onto the
/// widgets. The fact cards are rebuilt when the facts change — a handful of
/// rows, a few times a session.
final class DiagnosticsPane {
    var onRefresh: (() -> Void)?
    /// Copy, with the report to copy.
    var onCopy: ((String) -> Void)?

    let page: SettingsPage
    private let status: SettingsCard
    private let facts: GtkWidgetPointer
    private let copy: GtkWidgetPointer
    private let refresh: GtkWidgetPointer
    private var drawn: DiagnosticsPaneState?

    init() throws {
        guard let facts = GtkBuild.box(vertical: true, spacing: 18),
            let copy = GtkBuild.button("Copy"),
            let refresh = GtkBuild.button("Check Again")
        else { throw SettingsError.widgetCreationFailed }
        let page = try SettingsPage(title: SettingsSection.diagnostics.title)
        let status = try SettingsCard(title: "Overview")
        let report = try SettingsCard(title: "Report", footer: DiagnosticsPaneState.reportFooter)
        let copyRow = try SettingsRow(
            title: "Copy diagnostics",
            subtitle: "Versions, the clipboard session, the network and storage.",
            icon: ["edit-copy-symbolic", "document-save-symbolic"])
        copyRow.addTrailing(copy)
        report.add(copyRow.widget)

        for child in [status.widget, facts, report.widget] {
            page.append(child)
        }
        self.page = page
        self.status = status
        self.facts = facts
        self.copy = copy
        self.refresh = refresh
        // Check Again moves to a fresh row on every rebuild, and a widget's
        // only reference is its parent's; this one keeps it alive between
        // rows. Held for the pane's lifetime, which is the window's.
        g_object_ref_sink(UnsafeMutableRawPointer(refresh))
        GtkSignal.connect(UnsafeMutableRawPointer(copy), "clicked") { [weak self] in
            guard let self, let text = self.drawn?.report else { return }
            self.onCopy?(text)
            gtk_button_set_label(skrepka_as_button(self.copy), "Copied")
        }
        GtkSignal.connect(UnsafeMutableRawPointer(refresh), "clicked") { [weak self] in
            self?.onRefresh?()
        }
    }

    func render(_ state: DiagnosticsPaneState) {
        guard state != drawn else { return }
        drawn = state
        renderStatus(state)
        SettingsWidgets.empty(facts)
        for card in state.cards {
            if let widget = try? Self.card(card) { GtkBuild.append(widget, to: facts) }
        }
        GtkBuild.setEnabled(copy, state.report != nil)
        gtk_button_set_label(skrepka_as_button(copy), "Copy")
    }

    private func renderStatus(_ state: DiagnosticsPaneState) {
        // Taken out of its row before the rebuild drops the row, so the
        // button survives it — the pane holds its own reference (see init).
        if let parent = gtk_widget_get_parent(refresh) {
            gtk_box_remove(skrepka_as_box(parent), refresh)
        }
        status.removeAll()
        let headline = try? SettingsRow(title: state.headline, subtitle: state.placeholder)
        if let headline, let dot = SettingsWidgets.dot() {
            SettingsWidgets.setTone(dot, SettingsStyle.tone(state.tone))
            headline.addTrailing(refresh)
            headline.addTrailing(dot)
            status.add(headline.widget)
        }
        for problem in state.problems {
            // A row GTK would not build is left out; the rest still show.
            guard let row = try? SettingsRow(title: problem, subtitle: nil, icon: Self.warningIcon) else {
                continue
            }
            status.add(row.widget)
        }
    }

    private static let warningIcon = ["dialog-warning-symbolic", "emblem-important-symbolic"]

    private static func card(_ card: DiagnosticsPaneState.Card) throws -> GtkWidgetPointer {
        let widget = try SettingsCard(title: card.title)
        for fact in card.rows {
            let row = try SettingsRow(title: fact.title, subtitle: nil)
            gtk_widget_add_css_class(row.widget, SettingsStyle.compactRow)
            if let value = SettingsWidgets.value(fact.value, isLiteral: fact.isLiteral) {
                row.addTrailing(value)
            }
            widget.add(row.widget)
        }
        for note in card.notes {
            let row = try SettingsRow(title: note, subtitle: nil, icon: warningIcon)
            widget.add(row.widget)
        }
        return widget.widget
    }
}
