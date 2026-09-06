import Foundation
import Testing

@testable import SkrepkaSync

/// The two things ``SyncClipMeta`` normalises on the way in, and the fold the
/// merge engine relies on.
@Suite("Sync clip metadata")
struct SyncClipMetaTests {
    /// Cutting a preview mid-scalar would produce a `String` that is not valid
    /// UTF-8, which is a decode failure on the far end rather than a shorter
    /// preview — so the cap lands on a character boundary.
    @Test("A preview is capped at the byte limit, on a character boundary")
    func capsThePreviewOnACharacterBoundary() {
        // Four bytes each, so the limit falls mid-character however it divides.
        let long = String(repeating: "😀", count: SyncLimits.previewByteLimit)
        let meta = SyncFixtures.meta("aa", preview: long)

        #expect(meta.preview.utf8.count <= SyncLimits.previewByteLimit)
        #expect(meta.preview.utf8.count > SyncLimits.previewByteLimit - 4)
        #expect(long.hasPrefix(meta.preview))
        // Still valid UTF-8 after the cut, which is what the boundary buys.
        #expect(String(data: Data(meta.preview.utf8), encoding: .utf8) == meta.preview)

        let short = "already short"
        #expect(SyncFixtures.meta("bb", preview: short).preview == short)
    }

    @Test("createdAt is held at wire precision")
    func normalisesCreatedAt() {
        let ragged = SyncFixtures.epoch.addingTimeInterval(0.000_4)
        let meta = SyncClipMeta(
            contentHash: "aa",
            kind: "text",
            preview: "x",
            createdAt: ragged,
            isPinned: SyncFixtures.pin(false),
            originDeviceID: SyncFixtures.deviceA
        )
        #expect(meta.createdAt == SyncFixtures.epoch)
    }

    /// Sorted on the way in, so two peers describing one item produce the same
    /// bytes — which is what the deterministic encoding depends on.
    @Test("Representations are sorted however they were listed")
    func sortsRepresentations() {
        let png = RepresentationDescriptor(
            key: RepresentationKey(canonical: "image/png"),
            byteCount: 2
        )
        let text = RepresentationDescriptor(
            key: RepresentationKey(canonical: "text/plain;charset=utf-8"),
            byteCount: 1
        )
        let forwards = SyncFixtures.meta("aa", representations: [png, text])
        let backwards = SyncFixtures.meta("aa", representations: [text, png])
        #expect(forwards.representations == [png, text])
        #expect(forwards == backwards)
    }

    /// The fold the engine uses for duplicate offers: `createdAt` by maximum,
    /// the pin by its register, everything else from one deterministically
    /// chosen side.
    @Test("Combining two descriptions of one item is commutative")
    func combiningIsCommutative() {
        let early = SyncFixtures.meta(
            "aa",
            createdAt: 10,
            pinned: SyncFixtures.pin(true, at: 30),
            origin: SyncFixtures.deviceA,
            preview: "one"
        )
        let late = SyncFixtures.meta(
            "aa",
            createdAt: 40,
            pinned: SyncFixtures.pin(false, at: 5, by: SyncFixtures.deviceB),
            origin: SyncFixtures.deviceB,
            preview: "two"
        )

        let forwards = early.combining(late)
        #expect(forwards == late.combining(early))
        #expect(forwards.createdAt == late.createdAt)
        #expect(forwards.isPinned == early.isPinned)
        #expect(forwards.contentHash == "aa")
    }

    /// The case `(originDeviceID, createdAt)` cannot separate. Two peers can
    /// hold the same content, recorded by the same device at the same instant,
    /// and still describe it differently — a representation list is a claim
    /// about what its owner can serve, so the Linux peer's is legitimately the
    /// shorter. A `>=` on that pair alone answers true in both directions here,
    /// and every field taken from the chosen side would then depend on which
    /// argument the caller wrote first.
    @Test("Combining is commutative when the origin and the instant both match")
    func combiningBreaksAnEqualKey() {
        let text = RepresentationDescriptor(
            key: RepresentationKey(canonical: "text/plain;charset=utf-8"),
            byteCount: 6
        )
        let pdf = RepresentationDescriptor(
            key: RepresentationKey(canonical: "application/pdf"),
            byteCount: 4096
        )
        let rich = SyncFixtures.meta("aa", createdAt: 10, representations: [text, pdf])
        let plain = SyncFixtures.meta("aa", createdAt: 10, representations: [text])

        #expect(rich.combining(plain) == plain.combining(rich))
        // Idempotent too, which the tie-break must not break either.
        #expect(rich.combining(rich) == rich)
        #expect(plain.combining(plain) == plain)
    }

    /// The tie-break reaches every field taken wholesale, not only the list of
    /// representations, and a preview that happens to contain the characters
    /// the key is built from cannot collide with a different pair of fields.
    @Test("An equal key is broken by the remaining fields, separators and all")
    func tieBreakCoversEveryAdoptedField() {
        let awkward = SyncFixtures.meta("aa", createdAt: 10, preview: "6:sample3:x")
        let plain = SyncFixtures.meta("aa", createdAt: 10, preview: "sample")
        #expect(awkward.combining(plain) == plain.combining(awkward))

        let named = SyncFixtures.meta("aa", createdAt: 10, kind: "image")
        #expect(named.combining(plain) == plain.combining(named))
    }
}
