import Foundation

/// The answer to ``SkrepkaInterface/Member/preview``: the picture one entry
/// holds, for a client to draw a thumbnail from.
///
/// ## Why the bytes cross the bus at all
///
/// ``ClipDocument`` deliberately carries none — a list of forty entries is not
/// the place for a screenshot. A thumbnail is different: it is asked for one
/// entry at a time, only for an entry whose ``ClipDocument/hasPreview`` says
/// there is something to draw, and a client that keeps what it decoded asks
/// once per picture. The alternatives were worse. Scaling in the daemon needs
/// an image decoder in a process that deliberately links no GUI stack, and
/// writing the picture to a cache file leaves a copy of clipboard content on
/// disk that outlives the history entry it came from.
///
/// ## Why base64 in JSON rather than `ay`
///
/// The same trade ``SubmitRequest`` makes. A D-Bus byte array is one value per
/// byte in the library this project uses, which turns a two-megabyte PNG into
/// two million enum cases on each side of the call. A string is one buffer.
public struct PreviewDocument: SkrepkaDocument, Hashable {
    /// The absolute preview cap. A `maxBytes` of 0 uses it; a larger value is
    /// clamped to it. Large enough for a full-screen screenshot at the Steam
    /// Deck's resolution many times over, small enough that a camera RAW copied
    /// by accident is refused rather than base64-encoded onto the session bus.
    public static let defaultByteLimit = 16 * 1024 * 1024

    public let version: UInt32

    /// The entry the preview belongs to, resolved from whatever selector was
    /// passed — so a client caches by the same key ``ClipDocument`` carries.
    public let contentHash: String

    /// The canonical media type of ``data`` — `image/png`, `image/jpeg` — or
    /// nil when there is no picture to answer with.
    public let mediaType: String?

    /// The picture's bytes, base64-encoded. Nil when there is none, or when it
    /// is over the limit; ``detail`` says which.
    public let data: String?

    /// The size of the picture in bytes, even when it was too large to send,
    /// so a client can say "too large to preview" rather than "no preview".
    public let byteCount: Int?

    /// Why there is no data, in a sentence for a person. Empty when there is.
    public let detail: String

    public init(
        contentHash: String,
        mediaType: String?,
        data: String?,
        byteCount: Int?,
        detail: String = "",
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.contentHash = contentHash
        self.mediaType = mediaType
        self.data = data
        self.byteCount = byteCount
        self.detail = detail
    }

    /// A preview carrying `bytes`.
    public static func picture(_ bytes: Data, mediaType: String, contentHash: String) -> PreviewDocument {
        PreviewDocument(
            contentHash: contentHash,
            mediaType: mediaType,
            data: bytes.base64EncodedString(),
            byteCount: bytes.count
        )
    }

    /// No picture, and why.
    public static func unavailable(
        _ detail: String,
        contentHash: String,
        byteCount: Int? = nil
    ) -> PreviewDocument {
        PreviewDocument(
            contentHash: contentHash, mediaType: nil, data: nil, byteCount: byteCount, detail: detail)
    }

    /// The decoded picture, or nil when there is none or the base64 is broken.
    public var bytes: Data? {
        data.flatMap { Data(base64Encoded: $0) }
    }
}
