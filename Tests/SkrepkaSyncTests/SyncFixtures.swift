import Foundation

@testable import SkrepkaSync

/// Shared, deterministic sample values.
///
/// Every timestamp is built from whole milliseconds, because that is the
/// precision the wire carries and the model normalises to: a fixture built from
/// `Date()` would compare unequal to itself after a round trip for reasons that
/// have nothing to do with the test.
enum SyncFixtures {
    /// Device identifiers derived the way real ones are, so they are always
    /// valid hex of the right length. Named `a` and `b` after their sort order,
    /// which several tie-break tests depend on.
    static let deviceA = SyncDeviceID(certificateDER: Data("certificate-one".utf8))
    static let deviceB = SyncDeviceID(certificateDER: Data("certificate-two".utf8))

    /// A fixed instant, on a millisecond boundary.
    static let epoch = Date(timeIntervalSince1970: 1_757_000_000)

    static func time(_ secondsAfterEpoch: Double) -> Date {
        epoch.addingTimeInterval(secondsAfterEpoch)
    }

    static func pin(
        _ value: Bool,
        at seconds: Double = 0,
        by device: SyncDeviceID = deviceA
    ) -> LWWRegister<Bool> {
        LWWRegister(value: value, timestamp: time(seconds), deviceID: device)
    }

    static func meta(
        _ contentHash: String,
        createdAt seconds: Double = 0,
        pinned: LWWRegister<Bool>? = nil,
        origin: SyncDeviceID = deviceA,
        kind: String = "text",
        preview: String = "sample",
        representations: [RepresentationDescriptor] = [
            RepresentationDescriptor(
                key: RepresentationKey(
                    canonical: "text/plain;charset=utf-8",
                    origin: "public.utf8-plain-text"
                ),
                byteCount: 6
            )
        ]
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: contentHash,
            kind: kind,
            preview: preview,
            createdAt: time(seconds),
            isPinned: pinned ?? pin(false, by: origin),
            isConcealed: false,
            imageWidth: nil,
            imageHeight: nil,
            sourceBundleID: "com.apple.Safari",
            originDeviceID: origin,
            representations: representations
        )
    }

    static func tombstone(
        _ contentHash: String,
        deletedAt seconds: Double = 0,
        by device: SyncDeviceID = deviceA
    ) -> Tombstone {
        Tombstone(contentHash: contentHash, deletedAt: time(seconds), deviceID: device)
    }

    /// A non-ASCII device name on purpose: the wire carries UTF-8, and a name
    /// that round-trips only because it happened to be ASCII proves nothing.
    static let identity = PeerIdentity(
        deviceID: deviceA,
        deviceName: "Работа",
        platform: .macos,
        protocolVersion: .current,
        capabilities: ["livePush", "payloadResume"]
    )

    /// Certificate bytes shaped like a DER sequence, including a zero byte, so
    /// a byte-string field is exercised rather than a text one in disguise.
    static let pairRequest = PairRequest(
        deviceID: deviceB,
        deviceName: "desktop",
        platform: .linux,
        certificateDER: Data([0x30, 0x82, 0x01, 0x0a, 0x00, 0xff]),
        pairedAt: time(12)
    )

    static func payloadChunk(key: RepresentationKey) -> PayloadChunk {
        PayloadChunk(
            contentHash: "ee",
            key: key,
            offset: 262_144,
            bytes: Data(repeating: 0xab, count: 1024),
            isFinal: true
        )
    }

    /// One well-formed message of every type, so a test can assert it covered
    /// all of them rather than the handful someone remembered.
    static func allMessages() -> [SyncMessageType: SyncMessage] {
        let key = RepresentationKey(canonical: "image/png", origin: "public.png")
        let messages: [SyncMessage] = [
            .hello(identity),
            .pairRequest(pairRequest),
            .pairConfirm(deviceID: deviceA, accepted: true, shortAuthenticationString: "A3F291BC"),
            .indexOffer(
                items: [meta("aa"), meta("bb", createdAt: 30)],
                tombstones: [tombstone("cc", deletedAt: 5)],
                isFinal: false
            ),
            .indexRequest(since: time(-90)),
            .itemMeta(meta("dd", createdAt: 7, pinned: pin(true, at: 8, by: deviceB))),
            .payloadRequest(contentHash: "ee", key: key, offset: 262_144),
            .payloadChunk(payloadChunk(key: key)),
            .tombstone([tombstone("ff", deletedAt: 1), tombstone("00", deletedAt: 2, by: deviceB)]),
            .livePush(meta: meta("11"), inline: [key: Data([0x89, 0x50, 0x4e, 0x47])]),
            .ping(nonce: -4_611_686_018_427_387_904),
        ]
        return Dictionary(uniqueKeysWithValues: messages.map { ($0.type, $0) })
    }
}
