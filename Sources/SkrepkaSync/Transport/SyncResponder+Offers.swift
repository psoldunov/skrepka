import Foundation

// The two requests that read history out of this device: an index, and the
// bytes of something in it. Here rather than in `SyncResponder.swift` for
// length alone — they share its per-connection state, which is why that
// state is internal rather than private.
extension SyncResponder {
    /// What this peer may be offered now: its capabilities, and this device's
    /// file-size limit as it stands at this moment rather than at `hello`.
    func currentFilter() async -> CapabilityFilter {
        peerFilter.limitingFiles(to: await fileSync.maximumBytes)
    }

    func answerIndexRequest(since cursor: Date?) async throws -> [SyncMessage] {
        // Filtered before it is recorded: what is withheld may not be asked for.
        let items = await currentFilter().items(try await store.syncIndex(since: cursor))
        recordOffer(items)
        return [
            .indexOffer(
                items: items,
                tombstones: try await store.tombstones(since: cursor),
                isFinal: true
            )
        ]
    }

    /// Remembers what this connection may go on to ask for the bytes of.
    func recordOffer(_ items: [SyncClipMeta]) {
        let hashes = items.map(\.contentHash)
        if offeredHashes.count + hashes.count > Self.offeredHashLimit {
            offeredHashes = Set(hashes)
        } else {
            offeredHashes.formUnion(hashes)
        }
    }

    /// One slice, so the asking side controls the pace and can resume.
    ///
    /// A hash this connection was never offered is refused rather than answered,
    /// and the two outcomes are deliberately different. A representation this
    /// store cannot serve answers with an empty final chunk at offset zero — the
    /// peer asked whether these bytes are available here, and "no" is an
    /// ordinary answer rather than a fault, which the asking side detects by
    /// comparing what it got against the descriptor's byte count. Giving that
    /// same answer for an *unoffered* hash would let a peer walk arbitrary
    /// hashes and read this device's contents out of which ones come back
    /// non-empty, so the connection goes instead.
    func answerPayloadRequest(
        contentHash: String,
        key: RepresentationKey,
        offset: Int64
    ) async throws -> SyncMessage {
        guard offeredHashes.contains(contentHash) else {
            await connection.close()
            throw SyncTransportError.payloadNotOffered(contentHash: contentHash)
        }
        // A withheld bundle answers as bytes this store cannot serve: the hash
        // was offered, so the request is legitimate, but that form of it was
        // not — the peer has no capability for it, or it is over this device's
        // file-size limit.
        guard
            let payload = try await store.payload(for: contentHash, key: key),
            await currentFilter().offers(key, byteCount: payload.count),
            offset >= 0, offset < Int64(payload.count)
        else {
            return .payloadChunk(
                PayloadChunk(
                    contentHash: contentHash,
                    key: key,
                    offset: offset,
                    bytes: Data(),
                    isFinal: true
                )
            )
        }

        let start = payload.startIndex + Int(offset)
        let end = min(start + SyncLimits.payloadChunkBytes, payload.endIndex)
        return .payloadChunk(
            PayloadChunk(
                contentHash: contentHash,
                key: key,
                offset: offset,
                bytes: Data(payload[start..<end]),
                isFinal: end == payload.endIndex
            )
        )
    }
}
