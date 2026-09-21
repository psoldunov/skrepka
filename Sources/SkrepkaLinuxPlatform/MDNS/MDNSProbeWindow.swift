import Foundation

/// Whether a probe round is listening for defences yet, and whether one came.
///
/// RFC 6762 §8.1: "Apparently conflicting Multicast DNS responses received
/// *before* the first probe packet is sent MUST be silently ignored" — they
/// answer somebody else's question, or a stale probe of this host's own. The
/// window is closed through the random start-up delay and opens as the first
/// probe goes out; only a conflict noted while it is open counts.
struct MDNSProbeWindow: Sendable, Hashable {
    static let closed = MDNSProbeWindow(isOpen: false, sawConflict: false)
    static let opened = MDNSProbeWindow(isOpen: true, sawConflict: false)

    let isOpen: Bool
    let sawConflict: Bool

    func noting(conflict: Bool) -> MDNSProbeWindow {
        guard isOpen, conflict else { return self }
        return MDNSProbeWindow(isOpen: true, sawConflict: true)
    }
}
