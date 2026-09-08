import Foundation
import SkrepkaCore
import SkrepkaSync

extension Daemon {
    /// A captured item as the protocol describes it.
    ///
    /// Nil before this device has an identity, which is the same condition
    /// under which the store refuses to build an index at all: `SyncClipMeta`
    /// names the device that recorded the content, and `SyncDeviceID` is
    /// derived from a certificate rather than invented.
    ///
    /// Deliberately the same construction the macOS coordinator makes in
    /// `SyncCoordinator+LivePush.swift`. Two devices describing one item must
    /// produce identical metadata, or the merge sees two items where there is
    /// one — so this is a place where duplication is the requirement rather
    /// than the smell.
    func meta(for item: ClipItem, originDeviceID: SyncDeviceID) -> SyncClipMeta? {
        let representations = item.payload.representations.compactMap { type, data in
            RepresentationKeyMap.key(forUTI: type)
                .map { RepresentationDescriptor(key: $0, byteCount: data.count) }
        }
        return SyncClipMeta(
            contentHash: item.contentHash,
            kind: item.kind.rawValue,
            preview: item.text,
            createdAt: item.createdAt,
            isPinned: LWWRegister(
                value: item.isPinned,
                timestamp: item.createdAt,
                deviceID: originDeviceID
            ),
            isConcealed: item.isConcealed,
            imageWidth: item.imageSize?.width,
            imageHeight: item.imageSize?.height,
            // No Linux analogue — design §8. Carried as nil rather than filled
            // with a process name, which is not what any surface reading it
            // means by "which app did this come from".
            sourceBundleID: item.sourceBundleID,
            originDeviceID: originDeviceID,
            representations: representations
        )
    }

    /// Pasteboard-keyed bytes as wire-keyed bytes.
    ///
    /// A type with no canonical media type is dropped rather than renamed:
    /// `RepresentationKeyMap` refusing to name it means no peer could read
    /// those bytes anyway.
    static func wirePayloads(_ item: ClipItem) -> [RepresentationKey: Data] {
        var wire: [RepresentationKey: Data] = [:]
        for (type, data) in item.payload.representations {
            guard let key = RepresentationKeyMap.key(forUTI: type) else { continue }
            wire[key] = data
        }
        return wire
    }
}
