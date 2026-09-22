import Foundation
import Observation
import SkrepkaSync

/// How far each picker row's bytes have got on their way from a peer, for the
/// progress bar that stands in for the row's subtitle while they arrive.
///
/// Keyed by entry id, because that is what a row has. A transfer is named by
/// content hash — the identity it has on both machines — so each snapshot is
/// resolved to ids once, here, rather than once per row per frame.
@MainActor
@Observable
public final class TransferProgress {
    /// From 0 to 1, for every entry whose bytes are arriving.
    public private(set) var fractions: [UUID: Double] = [:]

    public init() {}

    /// The fraction for one row, or nil when nothing is arriving for it.
    public func fraction(for id: UUID) -> Double? {
        fractions[id]
    }

    /// Replaces the state with `transfers`. A transfer whose entry `resolve`
    /// cannot find — deleted since the fetch began — is left out.
    public func apply(_ transfers: [PayloadTransfer], resolve: (String) -> UUID?) {
        var next: [UUID: Double] = [:]
        for transfer in transfers {
            guard let id = resolve(transfer.contentHash) else { continue }
            next[id] = transfer.fraction
        }
        // Compared first so an unchanged snapshot does not redraw every row
        // that reads this.
        if next != fractions { fractions = next }
    }
}
