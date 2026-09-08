import Foundation

/// A clip a client observed and the daemon could not.
///
/// **This exists for GNOME.** Mutter implements no data-control protocol, so on
/// a GNOME Wayland session the daemon's `SessionProbe` finds nothing to watch
/// and capture is dead. The Phase 8 Shell extension runs *inside* the
/// compositor, where it can see a copy happen, and this is how it hands one
/// over. Nothing else should call it: a client that submits what the daemon can
/// already see records every copy twice.
///
/// Designing it now rather than with the extension is the phase plan's own
/// instruction, and the reason is that the extension ships through a review
/// queue — an interface retrofitted around a JavaScript client written later is
/// one the daemon cannot change afterwards.
public struct SubmitRequest: SkrepkaDocument, Hashable {
    public let version: UInt32

    /// Canonical media type to bytes, base64-encoded.
    ///
    /// Base64 because this is a JSON document, and the alternative — a D-Bus
    /// `a{say}` — is the typed-container shape ``SkrepkaInterface`` explains
    /// why this interface does not use. It costs a third in size on a payload
    /// that is already bounded by ``sizeLimit``.
    ///
    /// Keys are the same canonical MIME strings the sync wire uses, so an
    /// extension that reads `text/plain;charset=utf-8` off the clipboard writes
    /// exactly that here.
    public let representations: [String: String]

    /// What put it on the clipboard, where the client can say. Used for the
    /// user's exclusion list, so an extension that can name the source app
    /// makes exclusions work on GNOME too.
    public let sourceApplication: String?

    /// Whether the client believes this content is a password or otherwise
    /// concealed — the `x-kde-passwordManagerHint` and
    /// `org.nspasteboard.ConcealedType` cases.
    ///
    /// Believed and never overridden downward: the daemon applies its own
    /// privacy rules as well, and a client that says `true` is obeyed. D-7 puts
    /// concealed content nowhere near the wire, and a client is closer to the
    /// evidence than the daemon is here.
    public let isConcealed: Bool

    /// The largest submission the daemon accepts, in bytes, before base64.
    ///
    /// The same ceiling capture applies to what it reads itself
    /// (`CaptureRules.defaultMaximumItemBytes`), restated here so a client can
    /// refuse locally rather than encode 40 MB to be told no. A submission over
    /// it is refused rather than truncated.
    public static let sizeLimit = 32 * 1024 * 1024

    public init(
        representations: [String: String],
        sourceApplication: String? = nil,
        isConcealed: Bool = false,
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.representations = representations
        self.sourceApplication = sourceApplication
        self.isConcealed = isConcealed
    }

    /// The decoded payload, or nil where a value was not base64.
    ///
    /// Nil rather than a partial dictionary: a submission with one unreadable
    /// representation is a client bug, and recording the other half would store
    /// a clip that pastes as something different from what was copied.
    public func decodedRepresentations() -> [String: Data]? {
        var decoded: [String: Data] = [:]
        for (type, base64) in representations {
            guard let bytes = Data(base64Encoded: base64) else { return nil }
            decoded[type] = bytes
        }
        return decoded
    }
}
