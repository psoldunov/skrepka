import CGtk4

/// The right-hand side of the Settings window: one page per section in a
/// stack, showing the one the sidebar picked.
final class SettingsContent {
    let stack: GtkWidgetPointer
    let panes: PreferencesController.Panes

    init() throws {
        guard let stack = gtk_stack_new() else { throw SettingsError.widgetCreationFailed }
        let panes = PreferencesController.Panes(
            general: try GeneralPane(),
            history: try HistoryPane(),
            privacy: try PrivacyPane(),
            sync: try SyncPane(),
            diagnostics: try DiagnosticsPane()
        )
        let pages: [(SettingsSection, SettingsPage)] = [
            (.general, panes.general.page),
            (.history, panes.history.page),
            (.privacy, panes.privacy.page),
            (.sync, panes.sync.page),
            (.diagnostics, panes.diagnostics.page),
        ]
        let typed = skrepka_as_stack(stack)
        for (section, page) in pages {
            gtk_stack_add_named(typed, page.root, section.rawValue)
        }
        gtk_stack_set_transition_type(typed, GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(typed, 120)
        gtk_widget_set_hexpand(stack, 1)
        self.stack = stack
        self.panes = panes
    }

    func show(_ section: SettingsSection) {
        gtk_stack_set_visible_child_name(skrepka_as_stack(stack), section.rawValue)
    }
}
