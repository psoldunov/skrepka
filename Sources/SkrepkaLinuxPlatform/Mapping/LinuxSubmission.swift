import Foundation
import SkrepkaCore
import SkrepkaSync

/// A clip handed over by a client rather than read off the clipboard.
///
/// **This exists for GNOME.** Mutter implements no data-control protocol, so
/// `SessionProbe` finds nothing to watch on a GNOME Wayland session; the Phase
/// 8 Shell extension runs inside the compositor, sees the copy happen, and
/// submits it over the daemon's D-Bus interface.
///
/// The submission goes through the *same* `CaptureRules` a clipboard read does,
/// which is why it becomes a `PasteboardSnapshot` here rather than a `ClipItem`
/// directly. A client is not trusted to have applied the user's exclusion list,
/// the size ceiling, or the privacy-marker rules — and a path that skipped them
/// would be a way to get a password manager's clipping into the history that
/// the ordinary path refuses.
public enum LinuxSubmission {
    /// Turns canonical-media-type-keyed bytes into a snapshot the capture rules
    /// can judge.
    ///
    /// The keys arriving here are canonical media types — what the sync wire
    /// uses, and what a Shell extension reads off the clipboard — rather than
    /// the pasteboard type identifiers the store indexes by. They are mapped
    /// through the same table the clipboard backends use, so a submitted
    /// `text/plain;charset=utf-8` becomes the same stored representation a
    /// captured one does; two paths producing two different rows for one
    /// clipping would be invisible until a peer saw both.
    ///
    /// A type this build cannot name is dropped rather than stored under an
    /// invented identifier. A submission of nothing but unmappable types
    /// produces an empty snapshot, which `CaptureRules` rejects as empty — the
    /// right answer, and the same one an unreadable clipboard gets.
    public static func snapshot(
        representations: [String: Data],
        sourceApplication: String?,
        isConcealed: Bool,
        capturedAt: Date = Date()
    ) -> PasteboardSnapshot {
        var targets: [String: Data] = [:]
        for (canonical, bytes) in representations {
            guard !bytes.isEmpty,
                let target = RepresentationKeyMap.linuxTarget(forCanonical: canonical)
            else { continue }
            if targets[target] == nil { targets[target] = bytes }
        }
        // The concealed hint has to be among the *offered targets*, not only
        // in the flag. `LinuxRepresentationMap.declaredTypes(forOfferedTargets:
        // concealedHintResolvedSecret:)` builds the declared-type list from the
        // targets, and `CaptureRules` reads that list to decide whether a clip
        // carried a privacy marker — so a submission that set the flag and
        // offered no hint target was rejected as *unreadable* rather than as
        // concealed. The same outcome for this clip, and the wrong reason
        // everywhere it is reported.
        var offered = Array(targets.keys)
        if isConcealed { offered.append(PrivacyMarkers.kdePasswordManagerHint) }
        var snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: offered.sorted(),
            payloads: targets,
            concealedHintSecret: isConcealed,
            capturedAt: capturedAt
        )
        guard let sourceApplication, !sourceApplication.isEmpty else { return snapshot }
        // The builder writes nil here — design §8 says Linux has no analogue of
        // a source bundle identifier, and a backend reading the clipboard
        // genuinely cannot know. A *client* can: a Shell extension is told
        // which window had focus. So the one caller that has the answer
        // supplies it, and the exclusion list works on GNOME as a result.
        snapshot = PasteboardSnapshot(
            representations: snapshot.representations,
            declaredTypes: snapshot.declaredTypes,
            fileURLs: snapshot.fileURLs,
            sourceBundleID: sourceApplication,
            capturedAt: snapshot.capturedAt
        )
        return snapshot
    }
}
