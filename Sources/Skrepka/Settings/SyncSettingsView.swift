import SkrepkaSync
import SwiftUI

/// The Sync pane: this device, the devices it trusts, and the ones it can see.
struct SyncSettingsView: View {
    let coordinator: AppCoordinator

    private var sync: SyncCoordinator { coordinator.sync }

    var body: some View {
        @Bindable var sync = coordinator.sync

        if let message = sync.errorMessage {
            SettingsNotice(tone: .warning, message: message)
        }

        SettingsCard(
            title: "This device",
            footer: """
                Skrepka shares history with devices you pair with, over the local \
                network only. Nothing is sent to a server.
                """
        ) {
            SettingsRow(
                title: "Share clipboard history",
                subtitle: sync.displayName,
                symbol: "arrow.trianglehead.2.clockwise.rotate.90"
            ) {
                Toggle("", isOn: $sync.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Share clipboard history")
            }

            if sync.isEnabled {
                SettingsRowSeparator()
                pairingWindowRow
                if let deviceID = sync.localDeviceID {
                    SettingsRowSeparator()
                    SettingsRow(
                        title: "This device's code",
                        subtitle: "Shown on the other machine when you pair.",
                        symbol: "number"
                    ) {
                        Text(deviceID.fingerprint)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        if sync.isEnabled {
            devicesCard
        }
    }

    /// The switch that opens the second listener.
    ///
    /// Its own row rather than something implied by opening this pane, because
    /// what it does is accept TLS connections from machines this one has never
    /// met. That is a thing to turn on deliberately and turn off again.
    private var pairingWindowRow: some View {
        SettingsRow(
            title: "Allow new devices to pair",
            subtitle: """
                While this is on, another device on this network can ask to pair. \
                Turn it off when you are done.
                """,
            symbol: "antenna.radiowaves.left.and.right"
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { sync.isAcceptingPairing },
                    set: { accepting in Task { await sync.setAcceptingPairing(accepting) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Allow new devices to pair")
        }
    }

    private var devicesCard: some View {
        SettingsCard(title: "Devices", footer: syncFooter) {
            if sync.peers.isEmpty {
                emptyState
            } else {
                ForEach(Array(sync.peers.enumerated()), id: \.element.id) { index, peer in
                    if index > 0 {
                        SettingsRowSeparator()
                    }
                    PeerRowView(
                        peer: peer,
                        pair: { Task { await sync.pair(with: peer.deviceID) } },
                        unpair: { Task { await sync.unpair(peer.deviceID) } },
                        setLivePush: { choice in
                            Task { await sync.setLivePush(choice, for: peer.deviceID) }
                        }
                    )
                }
            }

            if hasPairedDevice {
                SettingsRowSeparator()
                HStack(spacing: 8) {
                    Button("Sync Now") { sync.syncNow() }
                        .buttonStyle(.bordered)
                        .font(SettingsMetrics.controlFont)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
                .padding(.vertical, 10)
            }
        }
    }

    private var hasPairedDevice: Bool { sync.peers.contains(where: \.isPaired) }

    /// Says what happens without a button press, so "Sync Now" reads as
    /// impatience rather than as the only thing that syncs.
    private var syncFooter: String? {
        guard hasPairedDevice else { return nil }
        return """
            Devices exchange history every half minute, and what you copy crosses \
            immediately where live clipboard is on.
            """
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text("No devices yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(
                """
                Open Skrepka on another machine, turn on sharing there, and \
                allow new devices to pair on both.
                """
            )
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
    }
}
