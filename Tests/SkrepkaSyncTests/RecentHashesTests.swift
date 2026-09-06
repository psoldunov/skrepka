import Foundation
import Testing

@testable import SkrepkaSync

/// The phase's `recentHashSetIsBounded`, in both directions.
///
/// Every entry in this set is put there by a remote peer, so an unbounded one is
/// a leak with a network interface in front of it; and an entry that never
/// expired would silently stop a genuine re-copy from ever syncing again. Both
/// bounds matter and only one of them is visible in ordinary use, which is why
/// each is asserted rather than described.
@Suite("Recently received hashes")
struct RecentHashesTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A remembered hash is recognised, and an unknown one is not")
    func remembersWhatItWasTold() {
        var hashes = RecentHashes()
        hashes.remember("a", at: Self.now)
        #expect(hashes.contains("a", at: Self.now))
        #expect(!hashes.contains("b", at: Self.now))
    }

    @Test("Past its capacity the oldest entries are dropped")
    func boundedByCount() {
        var hashes = RecentHashes(capacity: 3, lifetime: 3600)
        for index in 0..<5 {
            hashes.remember("hash-\(index)", at: Self.now)
        }

        #expect(hashes.hashes == ["hash-2", "hash-3", "hash-4"])
        #expect(!hashes.contains("hash-0", at: Self.now))
        #expect(!hashes.contains("hash-1", at: Self.now))
        #expect(hashes.contains("hash-4", at: Self.now))
    }

    @Test("Past its lifetime an entry stops suppressing")
    func boundedByAge() {
        var hashes = RecentHashes(capacity: 8, lifetime: 30)
        hashes.remember("a", at: Self.now)

        #expect(hashes.contains("a", at: Self.now.addingTimeInterval(30)))
        #expect(!hashes.contains("a", at: Self.now.addingTimeInterval(31)))
    }

    /// The count bound has to be enforced over *live* entries, or a burst of
    /// expired ones would evict the entries that are still doing work.
    @Test("Expired entries are removed rather than counted against the capacity")
    func expiredEntriesAreRemoved() {
        var hashes = RecentHashes(capacity: 3, lifetime: 30)
        for index in 0..<3 {
            hashes.remember("old-\(index)", at: Self.now)
        }

        let later = Self.now.addingTimeInterval(31)
        hashes.remember("new", at: later)

        #expect(hashes.hashes == ["new"])
        #expect(hashes.contains("new", at: later))
    }

    /// A peer that pushes the same content twice should extend the suppression,
    /// not spend two of a small number of slots on it.
    @Test("Re-remembering a hash extends it rather than duplicating it")
    func rememberingTwiceExtends() {
        var hashes = RecentHashes(capacity: 4, lifetime: 30)
        hashes.remember("a", at: Self.now)
        hashes.remember("b", at: Self.now)
        let later = Self.now.addingTimeInterval(20)
        hashes.remember("a", at: later)

        #expect(hashes.hashes == ["b", "a"])
        // `a` was refreshed at `later`, so it outlives the original window.
        #expect(hashes.contains("a", at: Self.now.addingTimeInterval(45)))
        #expect(!hashes.contains("b", at: Self.now.addingTimeInterval(45)))
    }

    /// A capacity of zero would make the set answer false for everything, which
    /// silently removes the guard rather than making it small.
    @Test("A capacity below one is raised to one")
    func capacityIsAtLeastOne() {
        var hashes = RecentHashes(capacity: 0, lifetime: 30)
        hashes.remember("a", at: Self.now)
        #expect(hashes.contains("a", at: Self.now))
    }
}
