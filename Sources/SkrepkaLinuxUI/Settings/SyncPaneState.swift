import Foundation
import SkrepkaIPC

/// The Sync pane, as the widgets draw it: every string and every enabled flag,
/// decided here so the GTK side only copies them onto widgets.
///
/// `Hashable` so the pane can skip rebuilding the device list when a poll
/// changed nothing it shows — which is most polls.
public struct SyncPaneState: Sendable, Hashable {
    public struct Banner: Sendable, Hashable {
        public let tone: SyncNotice.Tone
        public let message: String
        public let detail: String?
        public let isDismissible: Bool
    }

    public struct PairingSwitch: Sendable, Hashable {
        public let isOn: Bool
        public let isEnabled: Bool
        public let subtitle: String
    }

    public let banner: Banner?
    public let deviceName: String
    public let deviceCode: String
    public let pairingSwitch: PairingSwitch
    public let rows: [PeerRowState]
    /// What the list says when it has no rows; nil when it has some.
    public let emptyMessage: String?
    public let showsSyncNow: Bool
    public let isSyncNowEnabled: Bool

    public init(_ model: SyncModel, now: Date, timeZone: TimeZone) {
        let canAct = model.isSyncAvailable
        let peers = model.peers?.peers ?? []
        banner = Self.banner(model)
        deviceName = model.peers?.localName ?? "…"
        deviceCode = model.peers?.localFingerprint ?? ""
        pairingSwitch = Self.pairingSwitch(model, now: now, timeZone: timeZone)
        rows = peers.map { PeerRowState($0, model: model, canAct: canAct && model.prompt == nil, now: now) }
        emptyMessage = rows.isEmpty ? Self.emptyMessage(model) : nil
        showsSyncNow = peers.contains(where: \.isPaired)
        isSyncNowEnabled = canAct && !model.isInFlight(.syncNow)
    }

    /// The daemon's failure first, because while it stands nothing else on the
    /// screen can be trusted; then a daemon with sync turned off, which no
    /// control here can fix; then whatever the last action had to say.
    static func banner(_ model: SyncModel) -> Banner? {
        if let failure = model.failure {
            return Banner(
                tone: .problem, message: failure.message, detail: failure.remedy, isDismissible: false)
        }
        if let peers = model.peers, peers.localFingerprint.isEmpty {
            return Banner(
                tone: .info,
                message: "Sync is turned off on this device, so it cannot pair or share history.",
                detail: "skrepkad was started with --no-sync. Restart it without that flag.",
                isDismissible: false
            )
        }
        guard let notice = model.notice else { return nil }
        return Banner(tone: notice.tone, message: notice.message, detail: notice.detail, isDismissible: true)
    }

    /// Open or closed as the daemon says, except while a flip the user just
    /// made is on its way — then as the user put it.
    static func pairingSwitch(_ model: SyncModel, now: Date, timeZone: TimeZone) -> PairingSwitch {
        let opening = model.isInFlight(.openPairingWindow)
        let closing = model.isInFlight(.closePairingWindow)
        let isOpen = model.peers?.pairingPort != nil
        let isOn = opening || (isOpen && !closing)
        let subtitle: String
        if isOn, let endsAt = model.pairingWindowEndsAt, endsAt > now {
            subtitle = """
                Open until \(SyncText.clock(endsAt, in: timeZone)). Another device on this \
                network can ask to pair.
                """
        } else if isOn {
            subtitle = "Open. Another device on this network can ask to pair."
        } else {
            subtitle = """
                Turn this on, then choose Pair… for this device on the other one. \
                It turns itself off after a few minutes.
                """
        }
        return PairingSwitch(
            isOn: isOn,
            isEnabled: model.isSyncAvailable && !opening && !closing,
            subtitle: subtitle
        )
    }

    private static func emptyMessage(_ model: SyncModel) -> String {
        guard model.peers != nil else {
            return model.failure == nil ? "Connecting to Skrepka…" : "No devices to show."
        }
        return """
            No devices yet. Open Skrepka on your other machine and allow new devices \
            to pair there — on a Mac, in Settings → Sync. It appears here once it is \
            on this network.
            """
    }
}
