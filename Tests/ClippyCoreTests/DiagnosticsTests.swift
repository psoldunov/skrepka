import Foundation
import Testing

@testable import ClippyCore

@Suite("Capture health")
@MainActor
struct CaptureHealthTests {
    private let start = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("A fresh install is not blocked")
    func startsUnblocked() {
        let health = CaptureHealth()
        #expect(!health.isBlocked)
        #expect(health.lastCapturedAt == nil)
    }

    @Test("One unreadable read is not enough to declare a block")
    func toleratesASingleUnreadableRead() {
        // A poll landing between clearContents() and the write that follows it
        // produces exactly one of these on a healthy machine.
        let health = CaptureHealth()
        health.record(.rejectedUnreadable, at: start)
        #expect(!health.isBlocked)
    }

    @Test("A run of unreadable reads is a block")
    func detectsSustainedUnreadableReads() {
        let health = CaptureHealth()
        for _ in 0..<CaptureHealth.blockedThreshold {
            health.record(.rejectedUnreadable, at: start)
        }
        #expect(health.isBlocked)
    }

    @Test("A capture clears the block and records the time")
    func captureResetsTheRun() {
        let health = CaptureHealth()
        for _ in 0..<CaptureHealth.blockedThreshold {
            health.record(.rejectedUnreadable, at: start)
        }
        health.record(.captured(Self.item), at: start)
        #expect(!health.isBlocked)
        #expect(health.lastCapturedAt == start)
    }

    @Test("A successful probe proves access without claiming a capture")
    func probeProvesAccess() {
        // The "Allow Once" case: the policy stays `.ask` and no capture has
        // landed, so the round trip is the only evidence there is.
        let health = CaptureHealth()
        #expect(!health.hasReadSuccessfully)
        health.recordSuccessfulProbe()
        #expect(health.hasReadSuccessfully)
        // Nothing was captured, so the report must not print a capture time.
        #expect(health.lastCapturedAt == nil)
    }

    @Test("A successful probe clears a run of failed reads")
    func probeResetsTheRun() {
        let health = CaptureHealth()
        for _ in 0..<CaptureHealth.blockedThreshold {
            health.record(.rejectedUnreadable, at: start)
        }
        #expect(health.isBlocked)
        health.recordSuccessfulProbe()
        #expect(!health.isBlocked)
    }

    @Test("A rejection that required reading bytes also clears the block")
    func readableRejectionResetsTheRun() {
        // Clippy could only have decided "too large" by reading the data, so
        // access demonstrably works even though nothing was stored.
        let health = CaptureHealth()
        for _ in 0..<CaptureHealth.blockedThreshold {
            health.record(.rejectedUnreadable, at: start)
        }
        health.record(.rejectedTooLarge(byteCount: 999), at: start)
        #expect(!health.isBlocked)
        #expect(health.lastCapturedAt == nil)
    }

    private static let item = ClipItem(
        kind: .text,
        text: "hello",
        payload: ClipPayload(representations: [PasteboardType.string: Data("hello".utf8)])
    )
}

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    private func snapshot(
        access: PasteboardAccess = .alwaysAllow,
        blocked: Bool = false,
        lastCapture: Date? = nil,
        probeSucceeded: Bool = false,
        accessibility: Bool = true,
        pasteAutomatically: Bool = true,
        loginItem: DiagnosticsSnapshot.LoginItemState = .enabled,
        storage: DiagnosticsSnapshot.Storage = .onDisk(path: "/tmp/clippy.store"),
        itemCount: Int = 7
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "0.1.0 (1)",
            systemVersion: "Version 26.6.2",
            pasteboardAccess: access,
            isCaptureBlocked: blocked,
            lastCapturedAt: lastCapture,
            probeSucceeded: probeSucceeded,
            isAccessibilityTrusted: accessibility,
            pasteAutomatically: pasteAutomatically,
            loginItem: loginItem,
            storage: storage,
            itemCount: itemCount
        )
    }

    @Test("A capture proves access works even when the policy is undecided")
    func captureProvesAccess() {
        // `.notYetAsked` is what an app that has never triggered the alert
        // reports, working or not — so the capture is the evidence, not the
        // policy.
        let date = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(snapshot(access: .notYetAsked, lastCapture: date).clipboardStatus == .working)
        #expect(snapshot(access: .alwaysAllow).clipboardStatus == .working)
    }

    @Test("Nothing captured and an undecided policy is unknown, not working")
    func undecidedPolicyIsUnknown() {
        #expect(snapshot(access: .notYetAsked).clipboardStatus == .unknown)
        #expect(snapshot(access: .ask).clipboardStatus == .unknown)
    }

    @Test("A successful probe is proof, even with the policy left at Ask")
    func probeProvesAccess() {
        // "Allow Once" is the case this exists for: the policy stays `.ask`
        // forever, so without the probe the welcome window would refuse to
        // report `.working` on a machine that reads the clipboard fine.
        #expect(snapshot(access: .ask, probeSucceeded: true).clipboardStatus == .working)
        #expect(snapshot(access: .notYetAsked, probeSucceeded: true).clipboardStatus == .working)
    }

    @Test("A denial still outranks a probe that once succeeded")
    func denialOutranksTheProbe() {
        #expect(snapshot(access: .alwaysDeny, probeSucceeded: true).clipboardStatus == .blocked)
        #expect(snapshot(blocked: true, probeSucceeded: true).clipboardStatus == .blocked)
    }

    @Test("A denial or a run of blocked reads is blocked, whatever else is true")
    func blockedBeatsEvidence() {
        let date = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(snapshot(access: .alwaysDeny).clipboardStatus == .blocked)
        // Even a past capture cannot outrank reads that are failing right now.
        #expect(snapshot(blocked: true, lastCapture: date).clipboardStatus == .blocked)
    }

    @Test("A healthy install reports no problem")
    func healthyInstallHasNoProblem() {
        #expect(snapshot().primaryProblem == nil)
    }

    @Test("Storage failure outranks every other problem")
    func storageOutranksTheRest() {
        let broken = snapshot(
            access: .alwaysDeny,
            blocked: true,
            accessibility: false,
            storage: .inMemory(reason: "disk full")
        )
        #expect(broken.primaryProblem == .storageUnavailable)
    }

    @Test("A denial policy is a problem even before any read is attempted")
    func denialIsAProblem() {
        #expect(snapshot(access: .alwaysDeny).primaryProblem == .clipboardAccessDenied)
    }

    @Test("A run of blocked reads is a problem whatever the policy says")
    func blockedCaptureIsAProblem() {
        // .notYetAsked cannot be read as healthy: an app that has never
        // triggered the alert reports it whether or not it works.
        #expect(snapshot(access: .notYetAsked, blocked: true).primaryProblem == .clipboardAccessDenied)
    }

    @Test("Missing Accessibility only matters when paste-back is on")
    func accessibilityOnlyMattersWhenUsed() {
        #expect(snapshot(accessibility: false).primaryProblem == .accessibilityMissing)
        #expect(snapshot(accessibility: false, pasteAutomatically: false).primaryProblem == nil)
    }

    @Test("The report names the storage path and the problem")
    func reportCarriesTheEssentials() {
        let text = DiagnosticsReport.text(for: snapshot(access: .alwaysDeny))
        #expect(text.contains("Clippy 0.1.0 (1)"))
        #expect(text.contains("Clipboard access: Denied"))
        #expect(text.contains("/tmp/clippy.store"))
        #expect(text.contains("Stored items: 7"))
        #expect(text.contains(DiagnosticsProblem.clipboardAccessDenied.summary))
    }

    @Test("A never-captured install says so rather than printing a date")
    func reportHandlesNoCaptures() {
        #expect(DiagnosticsReport.text(for: snapshot()).contains("Last capture: never"))
    }

    @Test("A capture time prints as a full UTC timestamp")
    func reportPrintsTheCaptureTime() {
        // Guards the bug this test was written for: `.iso8601.timeZone(...)`
        // renders a style carrying only that one field, so every timestamp
        // came out as the bare string "Z".
        let date = Date(timeIntervalSince1970: 1_756_000_000)
        let text = DiagnosticsReport.text(for: snapshot(lastCapture: date))
        #expect(text.contains("Last capture: 2025-08-24T01:46:40Z"))
    }

    @Test("The system version is not double-labelled")
    func reportDoesNotRepeatVersion() {
        // operatingSystemVersionString already starts with "Version".
        #expect(!DiagnosticsReport.text(for: snapshot()).contains("macOS Version"))
    }

    @Test("An in-memory store is named as such, with the reason")
    func reportExplainsInMemoryStorage() {
        let text = DiagnosticsReport.text(for: snapshot(storage: .inMemory(reason: "disk full")))
        #expect(text.contains("in memory only — disk full"))
    }
}
