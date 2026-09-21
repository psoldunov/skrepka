import Foundation
import SkrepkaIPC
import SkrepkaSync

// The `Transfers` member and the `TransfersChanged` signal: every entry whose
// bytes are arriving from a peer, for a picker row to draw a progress bar
// from. Since interface version 5.
extension Daemon {
    /// The transfers in flight now.
    public func transfersDocument() async -> TransfersDocument {
        Self.document(await transfers.current)
    }

    /// Every change to the transfers in flight, starting with how they stand
    /// now — see `TransferMonitor.updates()`, which spaces them out.
    public func transferUpdates() async -> AsyncStream<[PayloadTransfer]> {
        await transfers.updates()
    }

    /// `transfers` as the bus carries them.
    static func document(_ transfers: [PayloadTransfer]) -> TransfersDocument {
        TransfersDocument(
            transfers: transfers.map {
                TransfersDocument.Transfer(
                    contentHash: $0.contentHash,
                    receivedBytes: $0.receivedBytes,
                    totalBytes: $0.totalBytes
                )
            }
        )
    }
}
