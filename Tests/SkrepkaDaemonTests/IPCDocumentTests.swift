import Foundation
import SkrepkaIPC
import Testing

/// What a client does with a document it did not write.
///
/// The headline is the newer-daemon case. `SkrepkaInterface` promises members
/// are added and never re-signatured, so a document from a later release is by
/// construction still readable here — and a client that refused it would break
/// for exactly the reason the payloads were made JSON in the first place.
@Suite("IPC documents")
struct IPCDocumentTests {
    @Test("a document at this version round-trips")
    func roundTrip() throws {
        let document = ActionDocument.succeeded("Copied.", subject: "a1b2c3")
        let decoded = try SkrepkaDocumentCoding.decode(
            ActionDocument.self, from: try SkrepkaDocumentCoding.encode(document))
        #expect(decoded == document)
    }

    @Test("a newer daemon's document decodes, unknown keys and all")
    func newerDocumentStillDecodes() throws {
        let future = SkrepkaInterface.version + 1
        let json = """
            {"detail":"Copied.","ok":true,"version":\(future),"whatIsThis":{"added":"later"}}
            """
        let decoded = try SkrepkaDocumentCoding.decode(ActionDocument.self, from: json)
        #expect(decoded.ok)
        #expect(decoded.detail == "Copied.")
        // The version is carried through rather than rewritten: a caller that
        // wants to know which daemon answered can still ask.
        #expect(decoded.version == future)
    }

    @Test("a newer document that genuinely will not decode says why")
    func newerDocumentThatFailsReportsItsVersion() {
        let future = SkrepkaInterface.version + 2
        // `ok` is missing, so this cannot decode at any version.
        let json = #"{"detail":"Copied.","version":\#(future)}"#
        do {
            _ = try SkrepkaDocumentCoding.decode(ActionDocument.self, from: json)
            Issue.record("a document with no `ok` should not have decoded")
        } catch let failure as SkrepkaDocumentCoding.Failure {
            guard case .unsupportedVersion(let found, let supported) = failure else {
                Issue.record("expected unsupportedVersion, got \(failure)")
                return
            }
            #expect(found == future)
            #expect(supported == SkrepkaInterface.version)
        } catch {
            Issue.record("expected a coding failure, got \(error)")
        }
    }

    @Test("malformed JSON is a malformed error, not a crash")
    func malformedJSON() {
        for text in ["", "not json at all", "{", #"{"version":}"#] {
            do {
                _ = try SkrepkaDocumentCoding.decode(ActionDocument.self, from: text)
                Issue.record("`\(text)` should not have decoded")
            } catch let failure as SkrepkaDocumentCoding.Failure {
                guard case .malformed = failure else {
                    Issue.record("expected malformed for `\(text)`, got \(failure)")
                    continue
                }
            } catch {
                Issue.record("expected a coding failure for `\(text)`, got \(error)")
            }
        }
    }

    /// A document at this version that omits a required key is malformed, not
    /// "unsupported" — the version has nothing to do with why it failed.
    @Test("a current-version document that will not decode is malformed")
    func currentVersionFailureIsMalformed() {
        let json = #"{"detail":"Copied.","version":\#(SkrepkaInterface.version)}"#
        do {
            _ = try SkrepkaDocumentCoding.decode(ActionDocument.self, from: json)
            Issue.record("a document with no `ok` should not have decoded")
        } catch let failure as SkrepkaDocumentCoding.Failure {
            guard case .malformed = failure else {
                Issue.record("expected malformed, got \(failure)")
                return
            }
        } catch {
            Issue.record("expected a coding failure, got \(error)")
        }
    }

    @Test("a selector that names nothing is refused rather than guessed at")
    func clipSelectorValidation() {
        #expect(ClipSelector(validating: "1") == ClipSelector.position(1))
        #expect(ClipSelector(validating: "0a1b") == ClipSelector.hash("0a1b"))
        #expect(ClipSelector(validating: "0") == nil)
        #expect(ClipSelector(validating: "") == nil)
        #expect(ClipSelector(validating: "-1") == nil)
        // The lenient spelling, for a wire caller with nowhere to report it:
        // position zero, which resolves to nothing.
        #expect(ClipSelector("0") == .position(0))
        #expect(ClipSelector("") == .position(0))
    }
}
