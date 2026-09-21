import SkrepkaCore

/// The symbolic icon a row's kind tile shows, as a fallback chain.
///
/// `g_themed_icon_new_from_names` takes several names and draws the first the
/// theme has, so every kind lists more than one — a name that exists in Breeze
/// (KDE, the Steam Deck) and one that exists in Adwaita (GNOME), so the tile is
/// never a missing-image glyph on either. Pure and free of GTK so the chains
/// can be tested; ``PickerRowView`` turns the chosen chain into a `GIcon`.
enum PickerIconName {
    /// The fallback chain for a document of `kind`, or for a concealed entry
    /// regardless of kind.
    static func names(kind: String, isConcealed: Bool) -> [String] {
        if isConcealed {
            return ["system-lock-screen-symbolic", "changes-prevent-symbolic", "dialog-password-symbolic"]
        }
        switch ClipKind(rawValue: kind) {
        case .link:
            return ["insert-link-symbolic", "emblem-web-symbolic", "text-x-generic-symbolic"]
        case .folder:
            return ["folder-symbolic", "inode-directory-symbolic"]
        case .image, .imageFile:
            return ["image-x-generic-symbolic", "emblem-photos-symbolic", "insert-image-symbolic"]
        case .file:
            return ["text-x-generic-symbolic", "application-x-generic-symbolic"]
        case .text, .richText, .none:
            return ["format-justify-left-symbolic", "view-list-symbolic", "text-x-generic-symbolic"]
        }
    }
}
