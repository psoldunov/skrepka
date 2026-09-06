import Foundation
import SkrepkaSync

extension ProbeStore {
    /// `SyncClipMeta` is immutable by design, so every edit is a new value.
    static func rebuilt(
        _ meta: SyncClipMeta,
        createdAt: Date? = nil,
        isPinned: LWWRegister<Bool>? = nil,
        representations: [RepresentationDescriptor]? = nil
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: meta.contentHash,
            kind: meta.kind,
            preview: meta.preview,
            createdAt: createdAt ?? meta.createdAt,
            isPinned: isPinned ?? meta.isPinned,
            isConcealed: meta.isConcealed,
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            sourceBundleID: meta.sourceBundleID,
            originDeviceID: meta.originDeviceID,
            representations: representations ?? meta.representations
        )
    }

    static func repinned(
        _ meta: SyncClipMeta,
        isPinned: Bool,
        deviceID: SyncDeviceID,
        at now: Date
    ) -> SyncClipMeta {
        rebuilt(
            meta,
            isPinned: LWWRegister(value: isPinned, timestamp: now, deviceID: deviceID)
        )
    }
}
