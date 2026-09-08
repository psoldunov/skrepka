import Foundation

/// What a member that *does* something answers.
///
/// Every mutating member answers this rather than returning nothing, and that
/// is about the CLI more than about the bus. `skrepka copy 3` has to say
/// whether it copied, and D-Bus's own way of saying "no" — an error reply — is
/// the wrong shape for "that entry has no representation this session can
/// write", which is an ordinary outcome the user needs the detail of rather
/// than a fault.
///
/// D-Bus errors are still used, and the line is: an error reply means the call
/// could not be attempted (unknown member, bad argument, daemon shutting down);
/// an `ok: false` here means it was attempted and did not happen, and
/// ``detail`` says why in a sentence written for a person.
public struct ActionDocument: SkrepkaDocument, Hashable {
    public let version: UInt32
    public let ok: Bool

    /// One sentence, written for a user rather than for a log. Empty on the
    /// dull success, where there is nothing to say.
    public let detail: String

    /// What the action acted on, where naming it is useful — the resolved
    /// `contentHash` for a copy, the peer's fingerprint for a pairing. Nil
    /// otherwise.
    public let subject: String?

    public init(
        ok: Bool,
        detail: String = "",
        subject: String? = nil,
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.ok = ok
        self.detail = detail
        self.subject = subject
    }

    public static func succeeded(_ detail: String = "", subject: String? = nil) -> ActionDocument {
        ActionDocument(ok: true, detail: detail, subject: subject)
    }

    public static func refused(_ detail: String, subject: String? = nil) -> ActionDocument {
        ActionDocument(ok: false, detail: detail, subject: subject)
    }
}
