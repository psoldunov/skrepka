import SkrepkaSync
import SwiftUI

/// One device in the Sync pane: what it is, what it is doing, and the two
/// decisions the user can take about it.
struct PeerRowView: View {
    let peer: SyncPeerRow
    let pair: () -> Void
    let unpair: () -> Void
    let setLivePush: (LivePushChoice) -> Void

    @State private var isConfirmingUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: peer.name, subtitle: subtitle, symbol: symbol) {
                trailing
            }
            if peer.isPaired {
                SettingsRowSeparator()
                livePushRow
            }
        }
    }

    // MARK: - The device itself

    private var symbol: String {
        switch peer.platform {
        case .macos: "macbook"
        case .linux: "pc"
        case .unknown: "desktopcomputer"
        }
    }

    /// One line under the name, chosen by what the user most needs to know now.
    ///
    /// A failure outranks a timestamp, a timestamp outranks a fingerprint. Only
    /// one of the three is shown, because a row that stacks all of them is a row
    /// nobody reads.
    private var subtitle: String {
        switch peer.link {
        case .failed(let reason): reason
        case .connecting: "Connecting…"
        case .connected, .idle: settledSubtitle
        }
    }

    private var settledSubtitle: String {
        guard peer.isPaired else {
            if case .seen(let isAcceptingPairing) = peer.trust, !isAcceptingPairing {
                return "Not accepting new pairings — \(peer.fingerprint)"
            }
            return "On this network — \(peer.fingerprint)"
        }
        guard let lastSyncedAt = peer.lastSyncedAt else { return peer.fingerprint }
        return "\(Self.exchangeSummary(peer)) · \(Self.relative(lastSyncedAt))"
    }

    private static func exchangeSummary(_ peer: SyncPeerRow) -> String {
        let received = peer.received == 1 ? "1 item received" : "\(peer.received) items received"
        guard peer.pushed > 0 else { return received }
        return "\(received), \(peer.pushed) pushed"
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private var trailing: some View {
        if peer.isPaired {
            HStack(spacing: 10) {
                StatusIndicator(state: indicator)
                Button("Unpair") { isConfirmingUnpair = true }
                    .font(SettingsMetrics.controlFont)
                    .buttonStyle(.borderless)
            }
            .confirmationDialog(
                "Forget \(peer.name)?",
                isPresented: $isConfirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive, action: unpair)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    Skrepka will stop trusting this device and will forget its \
                    certificate. Nothing already synced is deleted.
                    """
                )
            }
        } else {
            Button("Pair…", action: pair)
                .font(SettingsMetrics.controlFont)
                .buttonStyle(.bordered)
                .disabled(!isAcceptingPairing)
        }
    }

    private var isAcceptingPairing: Bool {
        guard case .seen(let accepting) = peer.trust else { return false }
        return accepting
    }

    private var indicator: StatusIndicator.State {
        switch peer.link {
        case .connected: .good
        case .connecting: .neutral
        case .failed: .warning
        case .idle: .neutral
        }
    }

    // MARK: - Live push

    /// The switch, and — when it is off by default — the sentence design §11
    /// requires beside it.
    ///
    /// "Universal Clipboard already does this" is something the user can act on;
    /// a switch that is simply off, or worse disabled, is a bug report waiting
    /// to be filed.
    private var livePushRow: some View {
        SettingsRow(
            title: "Live clipboard",
            subtitle: livePushExplanation,
            symbol: "arrow.left.arrow.right"
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { peer.livePush.isOn },
                    set: { setLivePush($0 ? .on : .off) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Live clipboard with \(peer.name)")
        }
    }

    private var livePushExplanation: String {
        guard !peer.livePush.isOverridden else {
            return peer.livePush.isOn
                ? "What you copy here goes straight to this device's clipboard."
                : "Only history is shared with this device."
        }
        switch peer.livePush.reason {
        case .on:
            return "What you copy here goes straight to this device's clipboard."
        case .offBetweenAppleDevices:
            return """
                Off by default — Universal Clipboard already does this between \
                two Apple devices. History is still shared.
                """
        case .offForUnrecognisedPlatform:
            return """
                Off by default — Skrepka does not recognise this device's \
                system. History is still shared.
                """
        }
    }
}
