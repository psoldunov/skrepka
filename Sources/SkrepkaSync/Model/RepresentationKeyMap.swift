import Foundation

/// The representation table of design §8, in one place.
///
/// macOS UTI ↔ canonical media type, and the Linux direction, with the lossy
/// cases named rather than silently dropped. `com.apple.flat-rtfd` maps to
/// nothing and ``unmappableUTIs`` says so; flattening it to HTML plus PNG is
/// Phase 3's job, not this map's.
public enum RepresentationKeyMap {
    /// One row of design §8.
    public struct Entry: Sendable, Hashable {
        /// IANA media type carried on the wire.
        public let canonical: String
        /// The macOS uniform type identifier for the same content.
        public let uti: String
        /// Linux clipboard targets for the same content, most standard first.
        public let linuxTargets: [String]
        /// What crossing this boundary costs, in the words of design §8. `nil`
        /// where nothing is lost.
        public let loss: String?
    }

    /// Design §8's table, verbatim. `public.url` is deliberately absent: §8
    /// gives it no row, and inventing `text/uri-list` for it would collide with
    /// `public.file-url`, which does have one.
    public static let entries: [Entry] = [
        Entry(
            canonical: "text/plain;charset=utf-8",
            uti: "public.utf8-plain-text",
            linuxTargets: ["text/plain;charset=utf-8", "text/plain"],
            loss: nil
        ),
        Entry(canonical: "text/html", uti: "public.html", linuxTargets: ["text/html"], loss: nil),
        Entry(canonical: "image/png", uti: "public.png", linuxTargets: ["image/png"], loss: nil),
        Entry(canonical: "image/tiff", uti: "public.tiff", linuxTargets: ["image/tiff"], loss: nil),
        Entry(
            canonical: "application/pdf",
            uti: "com.adobe.pdf",
            linuxTargets: ["application/pdf"],
            loss: "Nothing on Linux puts PDF on the clipboard."
        ),
        Entry(
            canonical: "text/rtf",
            uti: "public.rtf",
            linuxTargets: ["text/rtf"],
            loss: """
                Heavy. GTK4 registers no RTF serializer; only LibreOffice and Qt apps offer it. \
                In practice Linux rich text is text/html.
                """
        ),
        Entry(
            canonical: "text/uri-list",
            uti: "public.file-url",
            linuxTargets: ["text/uri-list", "x-special/gnome-copied-files"],
            loss: """
                Cardinality mismatch — macOS carries one URL, text/uri-list is a list. \
                The cut-versus-copy verb has no macOS equivalent, and the path exists only on \
                the origin machine, so the URI crosses as text and not as a live file reference.
                """
        ),
    ]

    /// macOS types with no canonical form at all, and why.
    ///
    /// Named rather than left as a silent `nil` from ``canonical(forUTI:)``: a
    /// caller that cannot tell "no mapping exists" from "I spelled the UTI
    /// wrong" will paper over the first case, and RTFD is exactly the case
    /// where papering over it loses the user's attachments.
    public static let unmappableUTIs: [String: String] = [
        "com.apple.flat-rtfd": """
        Total. RTFD is an Apple bundle — RTF plus embedded attachments. It must be flattened \
        to HTML plus PNG before it crosses, which is a transformation and not a mapping.
        """
    ]

    public static func canonical(forUTI uti: String) -> String? {
        entries.first { $0.uti == uti }?.canonical
    }

    public static func uti(forCanonical canonical: String) -> String? {
        entries.first { $0.canonical == canonical }?.uti
    }

    public static func canonical(forLinuxTarget target: String) -> String? {
        entries.first { $0.linuxTargets.contains(target) }?.canonical
    }

    /// The Linux target to advertise for a canonical key — the most standard
    /// one, where a row lists more than one.
    public static func linuxTarget(forCanonical canonical: String) -> String? {
        entries.first { $0.canonical == canonical }?.linuxTargets.first
    }

    /// Builds the wire key for a macOS representation, keeping the UTI as
    /// opaque passthrough so a Mac↔Mac round trip stays lossless.
    public static func key(forUTI uti: String) -> RepresentationKey? {
        guard let canonical = canonical(forUTI: uti) else { return nil }
        return RepresentationKey(canonical: canonical, origin: uti)
    }

    /// Builds the wire key for a Linux representation.
    public static func key(forLinuxTarget target: String) -> RepresentationKey? {
        guard let canonical = canonical(forLinuxTarget: target) else { return nil }
        return RepresentationKey(canonical: canonical, origin: target)
    }
}
