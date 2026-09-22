import DBUS
import Foundation

// The progress of entries arriving from a peer, since interface version 5: the
// snapshot a picker reads when it opens, and every change after.
extension DaemonProxy {
    /// Every entry whose bytes are arriving now.
    public func transfers() async throws -> TransfersDocument {
        try await document(TransfersDocument.self, SkrepkaInterface.Member.transfers)
    }

    /// One snapshot per `TransfersChanged`, until the caller stops reading or
    /// the connection ends.
    ///
    /// Subscribed before the match rule is added, for the reason
    /// ``pairingRequests()`` gives. A snapshot this build cannot read is
    /// skipped rather than ending the stream: the next one replaces it whole.
    public func transferChanges() async throws -> AsyncStream<TransfersDocument> {
        let signals = await connection.subscribeToSignal(
            interface: SkrepkaInterface.name,
            member: SkrepkaInterface.Signal.transfersChanged
        )
        let rule = """
            type='signal',sender='\(SkrepkaInterface.busName)',\
            interface='\(SkrepkaInterface.name)',\
            member='\(SkrepkaInterface.Signal.transfersChanged)'
            """
        try await addMatch(rule)
        return AsyncStream { continuation in
            let task = Task {
                for await message in signals {
                    guard case .string(let json) = message.body.first,
                        let document = try? SkrepkaDocumentCoding.decode(TransfersDocument.self, from: json)
                    else { continue }
                    continuation.yield(document)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
