import SkrepkaIPC

/// The Privacy pane, as the widgets draw it. Information only: nothing on it
/// is a setting.
public struct PrivacyPaneState: Sendable, Hashable {
    public let banner: SyncPaneState.Banner?
    /// The markers the daemon honours, each as the MIME type and value a
    /// person could look up. Empty until the daemon has said.
    public let markers: [String]
    /// What the markers card says when there are none to list.
    public let markersPlaceholder: String?

    public init(_ model: PreferencesModel) {
        banner = PreferencesBanner.banner(model)
        markers = model.document?.protectedMarkers ?? []
        switch model.availability {
        case .ready where markers.isEmpty:
            markersPlaceholder = "This skrepkad lists no markers."
        case .ready:
            markersPlaceholder = nil
        case .loading:
            markersPlaceholder = "Asking skrepkad…"
        case .unsupported, .unreachable:
            markersPlaceholder = "skrepkad did not say which markers it honours."
        }
    }

    public static let protectedSubtitle = """
        A copy a password manager marks as secret is never recorded, and never reaches \
        a paired device.
        """

    public static let markersFooter = """
        A password manager sets one of these beside what it copies, to say the copy \
        must not be kept.
        """

    public static let exclusionsTitle = "Why there is no list of apps to ignore"

    public static let exclusionsBody = """
        On a Mac, Skrepka can ignore copies made in chosen apps, because macOS says \
        which app is in front. Wayland does not: the clipboard protocols Skrepka reads \
        hand over what was copied and nothing about who copied it, so there is no app \
        to match a list against.
        """

    public static let exclusionsFooter = """
        If an app copies something private without marking it, clear it from the \
        picker — select it and press Delete.
        """
}
