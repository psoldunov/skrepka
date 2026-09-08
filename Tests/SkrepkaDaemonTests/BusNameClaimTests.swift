import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// The name claim, and the ordering it exists to enforce.
///
/// **What is not tested here, and why.** The case this closes is a *second*
/// `skrepkad` losing `RequestName` to a first — and that needs a live session
/// bus with a daemon already on it, which the build container has not. Nothing
/// below pretends otherwise: the reply codes are asserted through
/// the pure function that reads them, and the ordering is asserted through a
/// bus address that cannot be connected to on any machine. A test that claimed
/// to prove the two-daemon case would be a test that quietly proved nothing.
@Suite("Claiming the bus name")
struct BusNameClaimTests {
    /// A socket path nothing is listening on, on every machine — not a bus that
    /// happens to be absent in the container and present on a desktop. The
    /// difference matters: a test written against "no bus here" passes locally
    /// by talking to the real one.
    static let deadAddress = "/nonexistent/skrepka-tests/there-is-no-bus-here"

    static func deadSession() -> BusSession {
        BusSession(bus: .session, address: deadAddress)
    }

    static func temporaryOptions() -> DaemonOptions {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-claim-\(UUID().uuidString)", directoryHint: .isDirectory)
        return options
    }

    @Test("becoming the primary owner is the only reply that counts as winning")
    func onlyPrimaryOwnerWins() throws {
        try BusNameClaim.verify(replyCode: BusNameClaim.becamePrimaryOwner)
    }

    @Test("every other RequestName reply is reported as the name being taken")
    func everyOtherReplyIsAName() {
        // 2 is `IN_QUEUE`, 3 is `EXISTS`, 4 is `ALREADY_OWNER`. `DO_NOT_QUEUE`
        // is set, so 2 should be unreachable — and a bus that sent it anyway
        // would mean this process is queued behind another daemon, which is the
        // same answer for the user as 3.
        for code: UInt32 in [0, 2, 3, 4] {
            #expect(throws: ServiceError.nameAlreadyOwned) {
                try BusNameClaim.verify(replyCode: code)
            }
        }
    }

    @Test("the losing daemon's message says which name, and how to stop the other one")
    func theMessageIsWrittenForAPerson() {
        // Read through `DaemonRunner.describe` rather than off the enum: that is
        // the function the journal line goes through, and the restructure that
        // moved the claim out of `DaemonService` could have left it printing a
        // D-Bus error or a store error instead.
        let message = DaemonRunner.describe(ServiceError.nameAlreadyOwned)
        #expect(message.contains(SkrepkaInterface.busName))
        #expect(message.contains("systemctl --user stop skrepkad"))
    }

    @Test("a claim that cannot be made is reported as a bus failure, not a store one")
    func aFailedClaimReportsTheBus() async throws {
        var failure: (any Error)?
        do {
            try await BusNameClaim.claim(SkrepkaInterface.busName, over: Self.deadSession())
        } catch {
            failure = error
        }
        let error = try #require(failure, "a dead address cannot answer RequestName")
        #expect(DaemonRunner.describe(error).contains("cannot connect to the bus"))
    }

    @Test("the store is not opened when the name cannot be claimed")
    func nothingTouchesTheStoreBeforeTheNameIsWon() async {
        // The bug this closes: `Daemon.init` opens `SQLiteHistoryStore`, which
        // installs the schema — a write — so a claim made any later than this
        // meant the losing daemon had already written to the winner's database.
        // A connect failure rather than a name-already-owned reply, because the
        // latter needs a live bus; both reach this ordering the same way.
        let options = Self.temporaryOptions()
        let code = await DaemonRunner.run(options, over: Self.deadSession())
        #expect(code == DaemonRunner.Exit.cannotStart)
        let store = options.storeURL(environment: [:])
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(!FileManager.default.fileExists(atPath: store.deletingLastPathComponent().path))
    }
}
