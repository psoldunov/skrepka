import Foundation

/// Content hashes this device accepted from a peer a moment ago, so it never
/// pushes one of them straight back.
///
/// The backstop, not the main guard. A received write is kept out of capture
/// where it is made — the Mac pauses its watcher around a synchronous
/// pasteboard write, and the Linux sessions drop the echo of a
/// `SelectionWrite.handoff` — and ``ClipboardHandoff`` refuses the handed-over
/// hash for as long as nothing else is copied. What this still covers is a
/// burst: a hand-over remembers only the newest push, so the older ones of a
/// quick run are refused here, for thirty seconds. Without any of it, one
/// missed echo is not a duplicate row but a loop: A pushes to B, B captures
/// it, B pushes back to A, forever.
///
/// Exact hashes only, which is why it cannot be the main guard: an echo whose
/// bytes changed on the round trip — a link that comes back from Linux as
/// text, a multi-file copy that comes back as one file — carries a different
/// hash and walks straight past.
///
/// **Bounded by count and by age, and both bounds are load-bearing.** Every
/// entry is put here by a remote peer, so an unbounded set is a slow leak with
/// a network interface in front of it; and an entry that never expires would
/// silently stop a genuine re-copy from ever syncing again.
///
/// A value type with an injected instant rather than an actor reading the
/// clock: the ageing rule is the part worth testing, and a test that cannot
/// choose "now" cannot test a thirty-second window without waiting thirty
/// seconds. Owned by ``LivePushGate`` beside the hand-over, one per device.
public struct RecentHashes: Sendable, Hashable {
    /// Entries kept before the oldest is dropped.
    ///
    /// A live push is one clipboard item, and a human copying as fast as they
    /// can manage does not reach this in the ``defaultLifetime`` window. Far
    /// enough above ordinary use that reaching it means a peer is flooding,
    /// which is the case the ceiling exists for rather than one it should
    /// accommodate.
    public static let defaultCapacity = 64

    /// How long an entry suppresses a re-broadcast.
    ///
    /// Long enough to cover a pasteboard write that lands well outside the
    /// pause window — Continuity latency is seconds, per design §3.4 — and
    /// short enough that a user deliberately re-copying the same text a minute
    /// later still sees it sync.
    ///
    /// Suppressing a genuine re-copy inside the window costs nothing anyway:
    /// the peer this device would push to is the peer the content came from, so
    /// it already holds it.
    public static let defaultLifetime: TimeInterval = 30

    private struct Entry: Sendable, Hashable {
        let hash: String
        let acceptedAt: Date
    }

    private let capacity: Int
    private let lifetime: TimeInterval
    /// Oldest first, so trimming and expiry both work from the front.
    private var entries: [Entry] = []

    public init(capacity: Int = defaultCapacity, lifetime: TimeInterval = defaultLifetime) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    /// Records a hash this device has just accepted from a peer, dropping
    /// whatever has expired or no longer fits.
    ///
    /// Re-remembering a hash already held moves it to the back rather than
    /// adding a second copy: a peer that pushes the same content twice should
    /// extend the suppression, not spend two slots on it.
    public mutating func remember(_ hash: String, at now: Date) {
        // `lifetime` read into a local first: a predicate that reached back
        // through `self` would be an access to this value while `entries` is
        // exclusively borrowed, which is an exclusivity violation rather than a
        // style question.
        let lifetime = lifetime
        entries.removeAll { $0.hash == hash || now.timeIntervalSince($0.acceptedAt) > lifetime }
        entries.append(Entry(hash: hash, acceptedAt: now))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Whether `hash` was accepted from a peer recently enough to suppress.
    ///
    /// Non-mutating, so a caller on a read path does not have to hold the set
    /// `inout`. Expired entries are ignored here and removed by the next
    /// ``remember(_:at:)``; a set nothing writes to any more holds at most
    /// ``defaultCapacity`` strings and answers false for all of them.
    public func contains(_ hash: String, at now: Date) -> Bool {
        entries.contains { $0.hash == hash && !isExpired($0, at: now) }
    }

    /// Entries still held, oldest first, expired ones included. For tests and
    /// diagnostics; nothing in the protocol reads it.
    public var hashes: [String] { entries.map(\.hash) }

    private func isExpired(_ entry: Entry, at now: Date) -> Bool {
        now.timeIntervalSince(entry.acceptedAt) > lifetime
    }
}
