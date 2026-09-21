import Foundation
import SkrepkaIPC

/// The canned answers the demo's fake daemon gives: a Steam Deck paired with
/// a Mac, with a Linux laptop in sight, and a history worth counting.
enum DemoDocuments {
    static let macID = String(repeating: "ab", count: 32)
    static let laptopID = String(repeating: "ef", count: 32)

    typealias Retention = SettingsDocument.Retention

    static func settings(syncEnabled: Bool = true, retention: Retention? = nil) -> SettingsDocument {
        SettingsDocument(
            retention: retention ?? SettingsDocument.Retention(maximumItems: 500, maximumAgeDays: 30),
            sync: SettingsDocument.Sync(isEnabled: syncEnabled, isLockedOff: false),
            history: SettingsDocument.HistoryCounts(entries: 412, pinned: 7, images: 38),
            protectedMarkers: [
                "x-kde-passwordManagerHint = secret",
                "org.nspasteboard.ConcealedType",
                "org.nspasteboard.TransientType",
            ]
        )
    }

    static func peers() -> PeersDocument {
        PeersDocument(
            localDeviceID: String(repeating: "12", count: 32),
            localFingerprint: "1A2B-3C4D-5E6F-7A8B",
            localName: "steamdeck",
            peers: [mac(), laptop()],
            pairingPort: nil
        )
    }

    private static func mac() -> PeerDocument {
        PeerDocument(
            deviceID: macID,
            fingerprint: "ABABABAB",
            name: "MacBook Pro",
            platform: "macos",
            isPaired: true,
            isSighted: true,
            isAcceptingPairing: false,
            linkState: "synced",
            livePush: true,
            lastSyncedAt: Date() - 90,
            livePushChoice: PeerDocument.LivePushChoiceName.followsPlatformDefault,
            livePushDefault: PeerDocument.LivePushDefaultName.on
        )
    }

    private static func laptop() -> PeerDocument {
        PeerDocument(
            deviceID: laptopID,
            fingerprint: "EFEFEFEF",
            name: "framework",
            platform: "linux",
            isPaired: false,
            isSighted: true,
            isAcceptingPairing: true,
            linkState: "not paired",
            livePush: false,
            lastSyncedAt: nil
        )
    }

    static func diagnostics(withProblems: Bool) -> DiagnosticsDocument {
        DiagnosticsDocument(
            daemonVersion: "0.2.1",
            deviceFingerprint: "1A2B-3C4D-5E6F-7A8B",
            session: DiagnosticsDocument.Session(
                backend: "extDataControl",
                backendName: "ext-data-control-v1",
                waylandGlobals: ["wl_seat", "ext_data_control_manager_v1"],
                waylandDisplay: "wayland-0",
                x11Display: ":0",
                desktop: "KDE",
                isXWaylandFallback: false,
                problem: nil,
                isBlocking: false,
                restarts: withProblems ? 2 : 0
            ),
            network: DiagnosticsDocument.Network(
                responder: "avahi",
                responderProblem: withProblems ? "avahi-daemon is not running" : nil,
                isPublished: !withProblems,
                syncPort: 52_871,
                pairedCount: 1,
                sightedCount: withProblems ? 0 : 1
            ),
            storage: DiagnosticsDocument.Storage(
                path: "/home/deck/.local/share/skrepka/history.sqlite",
                itemCount: 412,
                lastCapturedAt: Date() - 240,
                mode: "0600"
            ),
            problems: withProblems
                ? ["Nothing on this network can find this device: avahi-daemon is not running."] : []
        )
    }
}
