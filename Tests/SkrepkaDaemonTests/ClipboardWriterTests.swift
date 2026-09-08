import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon
@testable import SkrepkaLinuxPlatform

/// Turning wire-keyed bytes into a Linux selection, and back.
@Suite("Linux clipboard writer")
struct ClipboardWriterTests {
    @Test("a wire key becomes the Linux target, not the sender's own name")
    func keysOffCanonicalNotOrigin() {
        // `origin` is the *sender's* name for the representation, which is a
        // macOS uniform type identifier when the sender was a Mac. Offering
        // `public.utf8-plain-text` as an X11 target would advertise something
        // no Linux application asks for, and the paste would come back empty.
        let key = RepresentationKey(canonical: "text/plain;charset=utf-8", origin: "public.utf8-plain-text")
        let targets = LinuxClipboardWriter.targets(for: [key: Data("hello".utf8)])
        #expect(targets["text/plain;charset=utf-8"] == Data("hello".utf8))
        #expect(targets["public.utf8-plain-text"] == nil)
    }

    @Test("a key with no Linux target is dropped rather than invented")
    func dropsUnmappableKeys() {
        let key = RepresentationKey(canonical: "application/x-nothing-here")
        #expect(LinuxClipboardWriter.targets(for: [key: Data([1, 2, 3])]).isEmpty)
    }

    @Test("an empty representation is dropped")
    func dropsEmptyBytes() {
        let key = RepresentationKey(canonical: "text/plain;charset=utf-8")
        #expect(LinuxClipboardWriter.targets(for: [key: Data()]).isEmpty)
    }

    /// Empty is a real answer and the caller must check it.
    ///
    /// Setting a selection with no targets claims the clipboard and serves
    /// nothing, which loses whatever was on it — so both call sites guard on
    /// this rather than passing an empty dictionary through.
    @Test("nothing mappable produces an empty dictionary, not a nil-ish one")
    func emptyIsAnAnswer() {
        #expect(LinuxClipboardWriter.targets(for: [:]).isEmpty)
    }
}

/// A clip submitted over the bus rather than read off the clipboard.
@Suite("Client submissions")
struct SubmissionTests {
    @Test("a submission becomes a snapshot the ordinary capture rules judge")
    func submissionGoesThroughCaptureRules() {
        let snapshot = LinuxSubmission.snapshot(
            representations: ["text/plain;charset=utf-8": Data("hello".utf8)],
            sourceApplication: "org.gnome.Nautilus",
            isConcealed: false
        )
        let decision = CaptureRules().decide(snapshot)
        let item = decision.item
        #expect(item?.text == "hello")
        // A client can name the window that had focus, where a backend reading
        // the clipboard genuinely cannot — which is what makes the user's
        // exclusion list work on GNOME.
        #expect(item?.sourceBundleID == "org.gnome.Nautilus")
    }

    @Test("a concealed submission is refused, not stored")
    func refusesConcealedSubmissions() {
        let snapshot = LinuxSubmission.snapshot(
            representations: ["text/plain;charset=utf-8": Data("hunter2".utf8)],
            sourceApplication: nil,
            isConcealed: true
        )
        let decision = CaptureRules().decide(snapshot)
        #expect(decision.item == nil)
        #expect(decision == .rejectedPrivacyMarker)
    }

    @Test("the exclusion list applies to a submission too")
    func honoursTheExclusionList() {
        let snapshot = LinuxSubmission.snapshot(
            representations: ["text/plain;charset=utf-8": Data("hello".utf8)],
            sourceApplication: "org.keepassxc.KeePassXC",
            isConcealed: false
        )
        let rules = CaptureRules(excludedBundleIDs: ["org.keepassxc.KeePassXC"])
        #expect(rules.decide(snapshot).item == nil)
    }

    @Test("a type this build cannot name is dropped, and nothing else is stored")
    func dropsUnmappableTypes() {
        let snapshot = LinuxSubmission.snapshot(
            representations: ["application/x-nothing-here": Data([1, 2, 3])],
            sourceApplication: nil,
            isConcealed: false
        )
        // An empty snapshot, which `CaptureRules` rejects as empty — the same
        // answer an unreadable clipboard gets.
        #expect(snapshot.representations.isEmpty)
        #expect(CaptureRules().decide(snapshot).item == nil)
    }

    @Test("base64 that is not base64 is refused before anything is stored")
    func refusesBadBase64() {
        let request = SubmitRequest(representations: ["text/plain;charset=utf-8": "not base64!!"])
        // Nil rather than a partial dictionary: a submission with one
        // unreadable representation would otherwise store a clip that pastes
        // as something different from what was copied.
        #expect(request.decodedRepresentations() == nil)
    }

    @Test("a well-formed submission decodes")
    func decodesBase64() throws {
        let bytes = Data("hello".utf8)
        let request = SubmitRequest(
            representations: ["text/plain;charset=utf-8": bytes.base64EncodedString()])
        let decoded = try #require(request.decodedRepresentations())
        #expect(decoded["text/plain;charset=utf-8"] == bytes)
    }
}
