import Foundation
import SkrepkaCore

/// Turns "these targets were offered and here are the bytes for some of them"
/// into a ``PasteboardSnapshot``.
///
/// One builder for both platforms' backends: Wayland receives through a pipe
/// and X11 through a window property, and by the time either has bytes the
/// remaining work — mapping targets to identifiers, decoding the two that need
/// it, and pulling the file list out of a URI list — is identical. Written once
/// so a fix to either half is a fix to both.
enum LinuxSnapshotBuilder {
    /// - Parameters:
    ///   - offeredTargets: every target the owner advertised, in its order.
    ///   - payloads: the bytes actually received, keyed by target. A target
    ///     that was offered but could not be read is simply absent — that is
    ///     what makes `CaptureRules.emptyReason(declaredTypes:)` able to tell
    ///     an empty clipboard from an unreadable one.
    ///   - concealedHintSecret: whether the KDE password-manager hint resolved
    ///     to the value that means "do not store".
    static func snapshot(
        offeredTargets: [String],
        payloads: [String: Data],
        concealedHintSecret: Bool,
        capturedAt: Date = Date()
    ) -> PasteboardSnapshot {
        let declaredTypes = LinuxRepresentationMap.declaredTypes(
            forOfferedTargets: offeredTargets,
            concealedHintResolvedSecret: concealedHintSecret
        )

        // Nothing is read for a concealed clip in the first place, but building
        // the snapshot from whatever did arrive would be a way for a future
        // caller to leak one. The rejection is carried by `declaredTypes`, and
        // `CaptureRules` refuses it before it looks at a byte.
        guard !concealedHintSecret else {
            return PasteboardSnapshot(
                representations: [:],
                declaredTypes: declaredTypes,
                capturedAt: capturedAt
            )
        }

        var representations: [String: Data] = [:]
        // Richest first, so that where two targets map to one identifier — as
        // `text/plain;charset=utf-8` and `text/plain` both do — the better one
        // wins rather than whichever the dictionary happened to yield.
        for target in LinuxRepresentationMap.interestingTargets {
            guard let data = payloads[target], !data.isEmpty,
                let identifier = LinuxRepresentationMap.pasteboardType(forTarget: target),
                representations[identifier] == nil,
                let decoded = LinuxRepresentationMap.decoded(data, forTarget: target),
                !decoded.isEmpty
            else { continue }
            representations[identifier] = decoded
        }

        return PasteboardSnapshot(
            representations: representations,
            declaredTypes: declaredTypes,
            fileURLs: fileURLs(in: payloads),
            // No Linux analogue exists — design §8. The field stays nil rather
            // than being filled with a process name, which is not what any
            // surface reading it means by "which app did this come from".
            sourceBundleID: nil,
            capturedAt: capturedAt
        )
    }

    /// Every file the copy holds.
    ///
    /// `text/uri-list` first because it is the standard one; GNOME's own
    /// spelling is consulted only when the standard target was not offered, so
    /// a copy that carries both is not counted twice or read in the wrong
    /// order.
    private static func fileURLs(in payloads: [String: Data]) -> [URL] {
        for target in ["text/uri-list", "x-special/gnome-copied-files"] {
            guard let data = payloads[target] else { continue }
            let urls = URIList.parse(data)
            if !urls.isEmpty { return urls }
        }
        return []
    }
}
