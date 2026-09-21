import CGtk4

/// The Privacy pane's widgets: what is always protected, the markers behind
/// it, and why there is no list of apps to ignore. Information only.
final class PrivacyPane {
    var onDismissBanner: (() -> Void)? {
        get { banner.onDismiss }
        set { banner.onDismiss = newValue }
    }

    let page: SettingsPage
    private let banner: SyncBanner
    private let markers: SettingsCard
    private var drawn: PrivacyPaneState?

    init() throws {
        guard let good = SettingsWidgets.dot() else { throw SettingsError.widgetCreationFailed }
        let page = try SettingsPage(title: SettingsSection.privacy.title)
        let banner = try SyncBanner()

        let protected = try SettingsCard(title: "Always protected")
        let passwords = try SettingsRow(
            title: "Password manager content",
            subtitle: PrivacyPaneState.protectedSubtitle,
            icon: ["dialog-password-symbolic", "changes-prevent-symbolic", "security-high-symbolic"])
        SettingsWidgets.setTone(good, SettingsStyle.tone(DiagnosticsPaneState.Tone.good))
        passwords.addTrailing(good)
        protected.add(passwords.widget)

        let markers = try SettingsCard(
            title: "Markers Skrepka honours", footer: PrivacyPaneState.markersFooter)

        let exclusions = try SettingsCard(
            title: "Never record from", footer: PrivacyPaneState.exclusionsFooter)
        let why = try SettingsRow(
            title: PrivacyPaneState.exclusionsTitle,
            subtitle: PrivacyPaneState.exclusionsBody,
            icon: ["dialog-information-symbolic", "help-about-symbolic"])
        exclusions.add(why.widget)

        for child in [banner.widget, protected.widget, markers.widget, exclusions.widget] {
            page.append(child)
        }
        self.page = page
        self.banner = banner
        self.markers = markers
    }

    func render(_ state: PrivacyPaneState) {
        guard state != drawn else { return }
        drawn = state
        banner.render(state.banner)
        markers.removeAll()
        let placeholder = state.markersPlaceholder.flatMap { try? SettingsRow(title: $0, subtitle: nil) }
        if let placeholder { markers.add(placeholder.widget) }
        for marker in state.markers {
            // A row GTK would not build is left out; the rest still show.
            guard let line = GtkBuild.box(vertical: false, spacing: 0, classes: [SettingsStyle.row]),
                let value = SettingsWidgets.value(marker, isLiteral: true)
            else { continue }
            gtk_widget_set_hexpand(value, 1)
            gtk_label_set_xalign(skrepka_as_label(value), 0)
            GtkBuild.append(value, to: line)
            markers.add(line)
        }
    }
}
