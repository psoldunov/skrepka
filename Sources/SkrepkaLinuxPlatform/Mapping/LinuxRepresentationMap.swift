import Foundation
import SkrepkaCore
import SkrepkaSync

/// The boundary between what a Linux clipboard offers and what
/// ``PasteboardSnapshot`` speaks.
///
/// ## Why the snapshot speaks UTIs on Linux
///
/// `CaptureRules`, `ClipKind`, `ThumbnailMaker`, `ContentSize` and the store all
/// key off `PasteboardType` — macOS uniform type identifiers. Making a Linux
/// snapshot speak MIME instead would mean a second capture pipeline, which is
/// exactly what Phase 4 spent its time avoiding. So the identifiers stay the
/// vocabulary of the *snapshot*, and this type is where MIME becomes them. The
/// wire keeps speaking MIME — that is ``RepresentationKeyMap``'s job, at a
/// different boundary — and neither vocabulary leaks into the other.
///
/// ## And why there is no table here
///
/// Design §8's table lives in ``RepresentationKeyMap`` and this composes it:
/// MIME → canonical → UTI. What is added is only what §8's table has no cell
/// for — the X11 atoms that predate MIME on the clipboard, and the two GNOME
/// spellings of a file list. A second copy of §8 would drift from the first.
public enum LinuxRepresentationMap {
    /// X11 selection targets that are not MIME types at all.
    ///
    /// ICCCM predates MIME on the clipboard, so an X11 owner may offer only
    /// these. Modern GTK and Qt applications offer the MIME spellings as well,
    /// but a terminal, `xclip` or an Xt-era application may not.
    ///
    /// `TEXT` is deliberately absent. ICCCM §2.6.2 leaves its encoding to the
    /// owner, so bytes received under it cannot be decoded without guessing,
    /// and every owner that offers it offers something better beside it.
    ///
    /// `STRING` is ICCCM Latin-1 rather than UTF-8. It is mapped anyway because
    /// an owner offering only `STRING` is offering the only text it has, and
    /// ``decoded(_:forTarget:)`` transcodes it rather than storing mojibake.
    static let x11TextTargets: [String: String] = [
        "UTF8_STRING": "text/plain;charset=utf-8",
        "STRING": "text/plain",
    ]

    /// Every target worth asking a clipboard for, richest first.
    ///
    /// Ordered rather than a set because a Wayland offer is served through one
    /// pipe per target and the order decides which arrives first — and because
    /// a deterministic order makes the tests mean something.
    ///
    /// Derived from ``RepresentationKeyMap`` rather than listed, so a row added
    /// to design §8's table is a target Linux starts reading with no edit here.
    public static let interestingTargets: [String] = {
        var seen: Set<String> = []
        var ordered: [String] = []
        // Ranked by the identifier the target maps to, so "richest first" means
        // the same thing on both platforms.
        for uti in PasteboardType.readOrder {
            guard let canonical = RepresentationKeyMap.canonical(forUTI: uti) else { continue }
            for target in RepresentationKeyMap.entries.first(where: { $0.canonical == canonical })?
                .linuxTargets ?? []
            where seen.insert(target).inserted {
                ordered.append(target)
            }
        }
        for (atom, canonical) in x11TextTargets.sorted(by: { $0.key < $1.key }) {
            guard RepresentationKeyMap.canonical(forLinuxTarget: canonical) != nil,
                seen.insert(atom).inserted
            else { continue }
            ordered.append(atom)
        }
        return ordered
    }()

    /// The identifier a ``PasteboardSnapshot`` should file this target's bytes
    /// under, or nil when nothing here can carry them.
    ///
    /// Nil is a decision, not a gap: a target with no identifier is one no
    /// surface in this app can render or paste, and storing its bytes under an
    /// invented key would produce a row that pastes garbage.
    public static func pasteboardType(forTarget target: String) -> String? {
        let canonical = x11TextTargets[target] ?? target
        guard let key = RepresentationKeyMap.canonical(forLinuxTarget: canonical) else { return nil }
        return RepresentationKeyMap.uti(forCanonical: key)
    }

    /// The targets to advertise for an identifier when Skrepka owns the
    /// selection, most standard first.
    ///
    /// A text identifier additionally advertises the X11 atoms, because an
    /// application that only knows `UTF8_STRING` is exactly the one that cannot
    /// ask for the MIME spelling. Harmless on Wayland, where a MIME-shaped
    /// string is simply an unusual MIME type nobody asks for.
    public static func targets(forPasteboardType identifier: String) -> [String] {
        guard let canonical = RepresentationKeyMap.canonical(forUTI: identifier),
            let entry = RepresentationKeyMap.entries.first(where: { $0.canonical == canonical })
        else { return [] }
        let atoms =
            x11TextTargets
            .filter { entry.linuxTargets.contains($0.value) }
            .keys
            .sorted()
        return entry.linuxTargets + atoms
    }

    /// What the snapshot should declare, given the targets a clipboard offered.
    ///
    /// Both vocabularies, deliberately. The identifiers are what
    /// `CaptureRules.emptyReason(declaredTypes:)` weighs to tell a clipboard
    /// holding nothing Skrepka wants from one whose every read failed; the raw
    /// targets are the faithful record of what was on offer, which is what a
    /// diagnostics report has to show.
    ///
    /// - Parameter concealedHintResolvedSecret: whether
    ///   ``PrivacyMarkers/kdePasswordManagerHint``, if it was offered, carried
    ///   the value that means "do not store". The hint is stripped when it did
    ///   not: it is the one convention in `PrivacyMarkers` whose meaning is in
    ///   its payload rather than its name, Klipper stores an entry hinted
    ///   anything else normally, and leaving the bare name in would reject
    ///   every clip a KDE application labelled `public`.
    public static func declaredTypes(
        forOfferedTargets targets: [String],
        concealedHintResolvedSecret: Bool
    ) -> [String] {
        var declared: [String] = []
        var seen: Set<String> = []
        for target in targets {
            if target == PrivacyMarkers.kdePasswordManagerHint, !concealedHintResolvedSecret {
                continue
            }
            if seen.insert(target).inserted { declared.append(target) }
            if let identifier = pasteboardType(forTarget: target), seen.insert(identifier).inserted {
                declared.append(identifier)
            }
        }
        return declared
    }

    /// Whether the KDE hint's bytes are the ones that mean "do not store".
    ///
    /// Compared against the literal payload rather than treated as a flag: a
    /// hint of `public` is one Klipper stores normally, and rejecting on the
    /// bare presence of the target would silently drop every clip a KDE
    /// application labelled. Here rather than in either backend because both
    /// need it and two spellings of one comparison is how they drift.
    public static func isConcealed(hint: Data?) -> Bool {
        guard let hint, let value = String(bytes: hint, encoding: .utf8) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            == PrivacyMarkers.kdePasswordManagerHintSecret
    }

    /// The bytes as the snapshot should store them, or nil when they cannot be
    /// used at all.
    ///
    /// Three targets need work rather than a copy:
    ///
    /// - `STRING` is ICCCM Latin-1. Transcoded to UTF-8, because every reader
    ///   downstream — search, the preview text, the store — assumes UTF-8, and
    ///   Latin-1 bytes above 0x7F silently fail `String(data:encoding:.utf8)`.
    /// - `x-special/gnome-copied-files` carries a verb line GNOME uses to say
    ///   cut versus copy. There is no such verb on macOS (design §8), so the
    ///   line is dropped and what is left is an ordinary `text/uri-list`.
    /// - `public.file-url` holds one URL on macOS and a list on Linux, so a URI
    ///   list is reduced to its first entry — the rest of them reach the
    ///   snapshot through `fileURLs` instead, which is the same split
    ///   `PasteboardReader` makes.
    public static func decoded(_ data: Data, forTarget target: String) -> Data? {
        switch target {
        case "STRING":
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            return Data(text.utf8)
        case "x-special/gnome-copied-files", "text/uri-list":
            guard let first = URIList.parse(data).first else { return nil }
            return Data(first.absoluteString.utf8)
        default:
            return data
        }
    }
}
