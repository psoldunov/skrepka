import Foundation
import SkrepkaIPC

@testable import SkrepkaLinuxUI

/// A daemon for the General, History, Privacy and Diagnostics panes' calls:
/// it records each member called, claims whatever interface version the test
/// gives it, and applies a patch to the settings it answers.
actor FakePreferencesDaemon: SettingsDaemon {
    private(set) var calls: [String] = []
    private let version: UInt32
    private var document: SettingsDocument
    private let answer: ActionDocument

    init(
        version: UInt32 = 4,
        document: SettingsDocument = PreferencesFixtures.settings(),
        answer: ActionDocument = .succeeded()
    ) {
        self.version = version
        self.document = document
        self.answer = answer
    }

    func interfaceVersion() async throws -> UInt32 {
        calls.append("interfaceVersion")
        return version
    }

    func settings() async throws -> SettingsDocument {
        calls.append("settings")
        return document
    }

    func setSettings(_ patch: SettingsPatch) async throws -> ActionDocument {
        calls.append("setSettings")
        guard answer.ok else { return answer }
        document = PreferencesFixtures.settings(
            maximumItems: patch.maximumItems ?? document.retention.maximumItems,
            maximumAgeDays: patch.maximumAgeDays ?? document.retention.maximumAgeDays,
            syncEnabled: patch.syncEnabled ?? document.sync.isEnabled)
        return answer
    }

    func clear(keepingPinned: Bool) async throws -> ActionDocument {
        calls.append("clear \(keepingPinned)")
        return .succeeded("cleared 3 entries")
    }

    func diagnostics() async throws -> DiagnosticsDocument {
        calls.append("diagnostics")
        return PreferencesFixtures.diagnostics()
    }

    // MARK: - SyncDaemon, unused here

    func peers() async throws -> PeersDocument { SyncFixtures.document() }

    func openPairing(seconds: UInt32) async throws -> PairingWindowDocument {
        PairingWindowDocument(port: 5555, expiresAt: SyncFixtures.now + 300)
    }

    func closePairing() async throws -> ActionDocument { .succeeded() }

    func pairWith(deviceID: String) async throws -> PairingProposalDocument {
        SyncFixtures.proposal(deviceID)
    }

    func confirmPairing(deviceID: String, accept: Bool) async throws -> ActionDocument { .succeeded() }

    func unpair(fingerprint: String) async throws -> ActionDocument { .succeeded() }

    func setLivePush(device: String, choice: String) async throws -> ActionDocument { .succeeded() }

    func syncNow() async throws -> ActionDocument { .succeeded() }

    func pairingRequests() async throws -> AsyncStream<PairingProposalDocument> { AsyncStream { _ in } }
}

/// Documents the daemon could have sent, for the non-Sync panes' tests.
enum PreferencesFixtures {
    static func settings(
        maximumItems: Int = 500,
        maximumAgeDays: Int = 30,
        syncEnabled: Bool = true,
        isLockedOff: Bool = false,
        markers: [String] = ["x-kde-passwordManagerHint = secret"]
    ) -> SettingsDocument {
        SettingsDocument(
            retention: SettingsDocument.Retention(maximumItems: maximumItems, maximumAgeDays: maximumAgeDays),
            sync: SettingsDocument.Sync(isEnabled: syncEnabled, isLockedOff: isLockedOff),
            history: SettingsDocument.HistoryCounts(entries: 42, pinned: 3, images: 5),
            protectedMarkers: markers
        )
    }

    static func diagnostics(problems: [String] = [], isBlocking: Bool = false) -> DiagnosticsDocument {
        DiagnosticsDocument(
            daemonVersion: "0.2.1",
            deviceFingerprint: "1A2B-3C4D",
            session: DiagnosticsDocument.Session(
                backend: "extDataControl",
                backendName: "ext-data-control-v1",
                waylandGlobals: [],
                waylandDisplay: "wayland-0",
                x11Display: nil,
                desktop: "KDE",
                isXWaylandFallback: false,
                problem: isBlocking ? "no data-control protocol" : nil,
                isBlocking: isBlocking,
                restarts: 0),
            network: DiagnosticsDocument.Network(
                responder: "avahi",
                responderProblem: nil,
                isPublished: true,
                syncPort: 5000,
                pairedCount: 1,
                sightedCount: 1),
            storage: DiagnosticsDocument.Storage(
                path: "/home/deck/.local/share/skrepka/history.sqlite",
                itemCount: 42,
                lastCapturedAt: nil,
                mode: "0600"),
            problems: problems
        )
    }

    /// A model that has read `document`.
    static func ready(_ document: SettingsDocument = settings()) -> PreferencesModel {
        PreferencesModel().applying(.loaded(.ready(document)), now: SyncFixtures.now)
    }
}
