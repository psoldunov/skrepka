import Foundation

/// The pairing dialog, as the widgets draw it.
///
/// **This dialog is the whole man-in-the-middle defence**, as the macOS sheet
/// is. TLS at first contact proves the two ends share a tunnel and nothing
/// about which machine is on the far end; a person comparing two strings on two
/// screens is what closes that. So the code is the largest thing in the dialog,
/// the confirm button says what it confirms, and nothing is pre-selected — the
/// dialog puts focus on Cancel, so Return declines.
public struct PairingPromptText: Sendable, Hashable {
    public let title: String
    public let device: String
    /// Nil while dialling, when there is no code yet.
    public let code: String?
    public let status: String
    /// Whether the status carries a spinner: something is on its way.
    public let isWorking: Bool
    public let cancelLabel: String
    /// Nil once the pairing is over and there is nothing left to confirm.
    public let confirmLabel: String?
    public let isConfirmEnabled: Bool

    static let confirm = "Codes Match — Pair"

    public init(_ prompt: PairingPrompt, now: Date) {
        title =
            prompt.direction == .outgoing
            ? "Pair with \(prompt.name)" : "\(prompt.name) wants to pair"
        device = "Device \(prompt.fingerprint)"
        code = prompt.code
        switch prompt.stage {
        case .dialling:
            status = "Connecting to \(prompt.name)…"
            isWorking = true
            cancelLabel = "Cancel"
            confirmLabel = Self.confirm
            isConfirmEnabled = false
        case .comparing:
            status = Self.instruction(prompt, now: now)
            isWorking = false
            cancelLabel = "Cancel"
            confirmLabel = Self.confirm
            isConfirmEnabled = true
        case .answering(let accept):
            status = accept ? "Pairing…" : "Declining…"
            isWorking = true
            cancelLabel = "Cancel"
            confirmLabel = Self.confirm
            isConfirmEnabled = false
        case .ended(let reason):
            status = reason
            isWorking = false
            cancelLabel = "Close"
            confirmLabel = nil
            isConfirmEnabled = false
        }
    }

    /// The instruction, and how long is left to follow it.
    ///
    /// The countdown is there because the daemon refuses on the person's
    /// behalf when it runs out, and a code that silently stops working reads
    /// as the other machine being wrong.
    static func instruction(_ prompt: PairingPrompt, now: Date) -> String {
        let check = "Check that \(prompt.name) is showing exactly this code. If it is not, do not pair."
        guard let expiresAt = prompt.expiresAt else { return check }
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        let left = seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) s"
        return "\(check)\nThis code is good for \(left) more."
    }
}
