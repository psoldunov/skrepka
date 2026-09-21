import Foundation

/// The named capabilities a peer advertises in `hello`, and what this build
/// advertises.
///
/// A capability is a promise about what the advertiser will do with something,
/// not merely that it can decode it. ``files`` is the case that makes the
/// difference matter: a 0.2 peer decodes an index entry naming a file bundle
/// perfectly well, drops the representation on the way into its store — it has
/// no type to keep it under — and then finds it missing on every exchange. It
/// would fetch the same bundle every ``PeerLink/resyncInterval`` for as long as
/// the two stayed paired. So a peer that has not promised to keep bundles is
/// never told about one — see ``CapabilityFilter``.
public enum SyncCapability {
    /// Keeps ``FileBundle`` representations it is offered, and so may be
    /// offered them.
    public static let files = "files"

    /// What this build puts in its own `hello`. Pass it as
    /// ``PeerIdentity/capabilities`` when building the local identity.
    public static let local: [String] = [files]
}

/// What one peer may be told, given the capabilities it advertised.
///
/// Applied on the way out and nowhere else: to the index a responder offers
/// and to the live push an initiator sends. A peer that never said `hello` on
/// a connection is treated as advertising nothing, which is the safe reading —
/// it costs a new peer a bundle for one exchange at worst, where the opposite
/// costs an old one a fetch loop.
public struct CapabilityFilter: Sendable, Hashable {
    public let capabilities: Set<String>

    public init(capabilities: some Sequence<String>) {
        self.capabilities = Set(capabilities)
    }

    /// Advertises nothing, so everything optional is withheld.
    public static let none = CapabilityFilter(capabilities: [])

    public var acceptsFiles: Bool { capabilities.contains(SyncCapability.files) }

    /// `meta` with every representation this peer may not be offered removed.
    ///
    /// Only the descriptor list changes. `contentHash` is over the content the
    /// item was copied as, not over the list of forms it is offered in, so the
    /// same item described with and without a bundle is still one item.
    public func meta(_ meta: SyncClipMeta) -> SyncClipMeta {
        guard !acceptsFiles, meta.representations.contains(where: Self.isBundle) else { return meta }
        return SyncClipMeta(
            contentHash: meta.contentHash,
            kind: meta.kind,
            preview: meta.preview,
            createdAt: meta.createdAt,
            isPinned: meta.isPinned,
            isConcealed: meta.isConcealed,
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            sourceBundleID: meta.sourceBundleID,
            originDeviceID: meta.originDeviceID,
            representations: meta.representations.filter { !Self.isBundle($0) }
        )
    }

    public func items(_ items: [SyncClipMeta]) -> [SyncClipMeta] {
        acceptsFiles ? items : items.map(meta)
    }

    /// Payload bytes with the same representations removed as ``meta(_:)``
    /// removes from the descriptor list.
    public func payloads(_ payloads: [RepresentationKey: Data]) -> [RepresentationKey: Data] {
        guard !acceptsFiles else { return payloads }
        return payloads.filter { $0.key.canonical != FileBundle.canonicalKey }
    }

    private static func isBundle(_ descriptor: RepresentationDescriptor) -> Bool {
        descriptor.key.canonical == FileBundle.canonicalKey
    }
}
