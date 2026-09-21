import Foundation
import SkrepkaIPC
import SkrepkaLinuxUI

/// An in-process daemon with canned answers, so the Settings window can be
/// drawn and clicked through without `skrepkad`. Changes are kept, so a flipped
/// switch or a new retention choice stays put.
actor FakeSettingsDaemon: SettingsDaemon {
    private let version: UInt32
    private let withProblems: Bool
    private var document = DemoDocuments.settings()

    /// - Parameter version: The interface version to claim; below 4 shows the
    ///   "update skrepkad" banner.
    init(version: UInt32, withProblems: Bool) {
        self.version = version
        self.withProblems = withProblems
    }

    func interfaceVersion() async throws -> UInt32 { version }

    func settings() async throws -> SettingsDocument { document }

    func setSettings(_ patch: SettingsPatch) async throws -> ActionDocument {
        let retention = SettingsDocument.Retention(
            maximumItems: patch.maximumItems ?? document.retention.maximumItems,
            maximumAgeDays: patch.maximumAgeDays ?? document.retention.maximumAgeDays)
        document = DemoDocuments.settings(
            syncEnabled: patch.syncEnabled ?? document.sync.isEnabled, retention: retention)
        return .succeeded("settings changed")
    }

    func clear(keepingPinned: Bool) async throws -> ActionDocument {
        .succeeded(keepingPinned ? "cleared 405 entries, kept 7 pinned" : "cleared 412 entries")
    }

    func diagnostics() async throws -> DiagnosticsDocument {
        DemoDocuments.diagnostics(withProblems: withProblems)
    }

    // MARK: - SyncDaemon

    func peers() async throws -> PeersDocument { DemoDocuments.peers() }

    func openPairing(seconds: UInt32) async throws -> PairingWindowDocument {
        PairingWindowDocument(port: 5555, expiresAt: Date() + 300)
    }

    func closePairing() async throws -> ActionDocument { .succeeded() }

    func pairWith(deviceID: String) async throws -> PairingProposalDocument {
        PairingProposalDocument(
            deviceID: deviceID,
            fingerprint: "EFEFEFEF",
            name: "framework",
            platform: "linux",
            shortAuthString: "A3F2-91BC-D4E7-0182",
            direction: PairingProposalDocument.Direction.outgoing,
            expiresAt: Date() + 120)
    }

    func confirmPairing(deviceID: String, accept: Bool) async throws -> ActionDocument { .succeeded() }

    func unpair(fingerprint: String) async throws -> ActionDocument { .succeeded("forgot MacBook Pro") }

    func setLivePush(device: String, choice: String) async throws -> ActionDocument {
        .succeeded("live clipboard is \(choice)")
    }

    func syncNow() async throws -> ActionDocument { .succeeded("asked 1 peer to sync") }

    func pairingRequests() async throws -> AsyncStream<PairingProposalDocument> {
        AsyncStream { _ in }
    }
}
