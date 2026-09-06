import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Retention")
struct RetentionPolicyTests {
    private func summary(
        age: TimeInterval,
        pinned: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ClipSummary {
        ClipSummary(
            id: UUID(),
            kind: .text,
            text: "entry",
            sourceBundleID: nil,
            createdAt: now.addingTimeInterval(-age),
            isPinned: pinned,
            isConcealed: false,
            imageSize: nil,
            byteCount: nil,
            hasThumbnail: false
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Count limit evicts the oldest unpinned entries")
    func evictsByCount() {
        let policy = RetentionPolicy(maximumItems: 2, maximumAge: nil)
        let entries = (0..<5).map { summary(age: TimeInterval($0) * 60, now: now) }
        let doomed = policy.idsToEvict(from: entries, now: now)
        #expect(doomed.count == 3)
        // The two newest survive.
        #expect(!doomed.contains(entries[0].id))
        #expect(!doomed.contains(entries[1].id))
    }

    @Test("Age limit evicts anything past the cutoff")
    func evictsByAge() {
        let policy = RetentionPolicy(maximumItems: nil, maximumAge: 3600)
        let entries = [
            summary(age: 60, now: now),
            summary(age: 7200, now: now),
        ]
        let doomed = policy.idsToEvict(from: entries, now: now)
        #expect(doomed == [entries[1].id])
    }

    @Test("Pinned entries survive both limits")
    func pinnedSurvive() {
        let policy = RetentionPolicy(maximumItems: 1, maximumAge: 60)
        let entries = [
            summary(age: 99_999, pinned: true, now: now),
            summary(age: 99_999, pinned: true, now: now),
            summary(age: 99_999, now: now),
        ]
        let doomed = policy.idsToEvict(from: entries, now: now)
        #expect(doomed == [entries[2].id])
    }

    @Test("Unlimited evicts nothing")
    func unlimitedKeepsEverything() {
        let entries = (0..<50).map { summary(age: TimeInterval($0) * 86400, now: now) }
        #expect(RetentionPolicy.unlimited.idsToEvict(from: entries, now: now).isEmpty)
    }

    @Test("Pinned entries do not count against the item limit")
    func pinnedDoNotConsumeQuota() {
        let policy = RetentionPolicy(maximumItems: 2, maximumAge: nil)
        let entries = [
            summary(age: 0, pinned: true, now: now),
            summary(age: 10, pinned: true, now: now),
            summary(age: 20, now: now),
            summary(age: 30, now: now),
        ]
        #expect(policy.idsToEvict(from: entries, now: now).isEmpty)
    }
}
