/// The line at the top of the History and Privacy panes: the daemon's
/// failure, a daemon too old to change settings, or what the last change had
/// to say — in that order, for ``SyncPaneState/banner(_:)``'s reason.
enum PreferencesBanner {
    static func banner(_ model: PreferencesModel) -> SyncPaneState.Banner? {
        switch model.availability {
        case .unreachable(let failure):
            return SyncPaneState.Banner(
                tone: .problem, message: failure.message, detail: failure.remedy, isDismissible: false)
        case .unsupported(let version):
            return SyncPaneState.Banner(
                tone: .info,
                message: "Update skrepkad to change these settings.",
                detail: """
                    The skrepkad running now speaks version \(version) of Skrepka's interface, \
                    and changing settings from here needs version \(PreferencesModel.requiredVersion). \
                    Install Skrepka again, then run systemctl --user restart skrepkad.
                    """,
                isDismissible: false
            )
        case .loading, .ready:
            guard let notice = model.notice else { return nil }
            return SyncPaneState.Banner(
                tone: notice.tone, message: notice.message, detail: notice.detail, isDismissible: true)
        }
    }
}
