import Foundation

/// Every entry whose bytes are on their way to this device from a peer: what
/// ``SkrepkaInterface/Member/transfers`` answers and
/// ``SkrepkaInterface/Signal/transfersChanged`` carries. Since interface
/// version 5.
///
/// A whole snapshot every time rather than one entry's progress, so a client
/// that subscribed halfway through a transfer, or missed a signal, is right
/// again on the next one. It is small: a transfer is only listed while it is
/// in flight, and only if it is more than one chunk — smaller ones finish in a
/// single reply and never appear.
///
/// The daemon spaces the signal out, at most about ten a second while bytes
/// are arriving; a transfer starting or finishing is sent at once.
public struct TransfersDocument: SkrepkaDocument, Hashable {
    /// One entry's fetch.
    public struct Transfer: Codable, Sendable, Hashable {
        /// The entry, as ``ClipDocument/contentHash`` names it.
        public let contentHash: String
        /// Bytes that have arrived so far.
        public let receivedBytes: Int
        /// Bytes the fetch set out to bring.
        public let totalBytes: Int

        public init(contentHash: String, receivedBytes: Int, totalBytes: Int) {
            self.contentHash = contentHash
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
        }

        /// How far along, from 0 to 1. Clamped, because a peer can understate
        /// a size and a bar past its end reads worse than a full one.
        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
        }
    }

    public let version: UInt32
    /// Every transfer in flight, in content-hash order.
    public let transfers: [Transfer]

    public init(transfers: [Transfer], version: UInt32 = SkrepkaInterface.version) {
        self.version = version
        self.transfers = transfers
    }
}
