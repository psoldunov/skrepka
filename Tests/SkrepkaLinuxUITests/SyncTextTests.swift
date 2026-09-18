import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// The wording the Settings window builds: failures, sentences, times.
@Suite("Settings: wording")
struct SyncTextTests {
    @Test("a daemon that is not running is said so, with the command that starts it")
    func notRunning() {
        let error = IPCError.busError(
            member: "Peers", name: "org.freedesktop.DBus.Error.ServiceUnknown", detail: "")
        let failure = SyncFailure(describing: error)
        #expect(failure.message == "The Skrepka daemon is not running.")
        #expect(failure.remedy?.contains("systemctl --user start skrepkad") == true)
    }

    @Test("the daemon's own refusal is shown as a sentence, without the bus error's name")
    func daemonSentence() {
        let error = IPCError.busError(
            member: "OpenPairing",
            name: "org.freedesktop.DBus.Error.Failed",
            detail: "sync is turned off on this device, so it cannot pair"
        )
        let failure = SyncFailure(describing: error)
        #expect(failure.message == "Sync is turned off on this device, so it cannot pair.")
        #expect(failure.remedy == nil)
    }

    @Test("a slow daemon keeps the CLI's advice")
    func timedOut() {
        let failure = SyncFailure(describing: IPCError.timedOut(member: "Peers", after: .seconds(10)))
        #expect(failure.message == "The Skrepka daemon did not answer in time.")
        #expect(failure.remedy == IPCError.timedOut(member: "Peers", after: .seconds(10)).remedy)
    }

    @Test(
        "fragments become sentences, and sentences are left alone",
        arguments: [
            ("forgot MacBook", "Forgot MacBook."),
            ("asked 2 peers to sync", "Asked 2 peers to sync."),
            ("Already a sentence.", "Already a sentence."),
            ("  padded  ", "Padded."),
            ("", ""),
        ]
    )
    func sentences(input: String, expected: String) {
        #expect(SyncText.sentence(input) == expected)
    }

    @Test(
        "how long ago, to the minute",
        arguments: [
            (0.0, "just now"),
            (59.0, "just now"),
            (60.0, "1 minute ago"),
            (125.0, "2 minutes ago"),
            (3600.0, "1 hour ago"),
            (7300.0, "2 hours ago"),
            (90_000.0, "more than a day ago"),
            (-30.0, "just now"),
        ]
    )
    func ago(seconds: Double, expected: String) {
        let now = SyncFixtures.now
        #expect(SyncText.ago(now - seconds, now: now) == expected)
    }

    @Test("a clock time is the zone's own, in 24 hours")
    func clock() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(SyncText.clock(SyncFixtures.now, in: .gmt) == "08:00")
        #expect(SyncText.clock(SyncFixtures.now, in: tokyo) == "17:00")
    }
}
