import SwiftUI

/// The eight characters both devices show, and the question the user answers
/// about them.
///
/// **This sheet is the whole man-in-the-middle defence.** TLS at first contact
/// proves the two ends share a tunnel and nothing about which machine is on the
/// far end; a person comparing two strings on two screens is what closes that.
/// So everything here is in service of the comparison being made rather than
/// clicked through: the code is the largest thing on screen, the confirm button
/// says what it confirms, and nothing is pre-selected.
struct PairingSheet: View {
    let pairing: PendingPairing
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            header
            code
            status
            buttons
        }
        .padding(24)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text("Device \(pairing.fingerprint)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
    }

    /// Which way the request went, because the two are different questions.
    ///
    /// A pairing this Mac started is one the user is completing; a pairing
    /// another machine started is one they are being *asked* for, and a sheet
    /// that appeared unbidden should say who it appeared for.
    private var title: String {
        switch pairing.direction {
        case .outgoing: "Pair with \(pairing.peerName)"
        case .incoming: "\(pairing.peerName) wants to pair"
        }
    }

    /// The code, set in a face where `0` and `O`, `1` and `l` differ.
    ///
    /// `.monospaced` is not decoration here: the whole defence is a human
    /// comparing two strings in about three seconds, and a proportional face
    /// that renders those pairs alike is what makes a wrong comparison read as a
    /// right one. Grouped `A3F2-91BC-D4E7-0182` by `ShortAuthString` for the
    /// same reason.
    ///
    /// Sized to fit nineteen characters on **one line**, which is what the
    /// widening to 64 bits made a constraint. SF Mono advances 0.6em, so at 24pt
    /// the code is 19 × 14.4 + 19 × 1.5 tracking ≈ 302pt inside the 332pt this
    /// sheet leaves between its padding. `minimumScaleFactor` is the backstop
    /// rather than the plan: it keeps a future width change from truncating the
    /// thing the user is here to read, and truncation is the failure that
    /// matters, because two codes agreeing on their first sixteen characters is
    /// exactly what an attacker is trying to produce.
    ///
    /// One line rather than two groups over two: a user comparing a stacked code
    /// reads the top line and assumes the rest.
    private var code: some View {
        Text(pairing.code)
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .textSelection(.enabled)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .glassSurface()
            .accessibilityLabel(Self.spelled(pairing.code))
    }

    /// Read one character at a time, so VoiceOver does not turn `A3F2` into a
    /// word and leave two users comparing different things.
    private static func spelled(_ code: String) -> String {
        code.map { $0 == "-" ? "dash" : String($0) }.joined(separator: " ")
    }

    @ViewBuilder
    private var status: some View {
        switch pairing.stage {
        case .waitingForPeer:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(pairing.peerName) to show the same code…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .awaitingConfirmation:
            Text(
                """
                Check that \(pairing.peerName) is showing exactly this code. \
                If it is not, do not pair.
                """
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        case .ended(let reason):
            SettingsNotice(tone: .warning, message: reason)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .ended = pairing.stage {
            Button("Close", action: cancel)
                .keyboardShortcut(.defaultAction)
        } else {
            HStack(spacing: 10) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match — Pair", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairing.canConfirm)
            }
        }
    }
}
