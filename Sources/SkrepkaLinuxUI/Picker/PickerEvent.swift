import Foundation
import SkrepkaIPC

/// What ``PickerLink`` tells the controller, on the concurrency pool, for the
/// controller to apply on GTK's loop thread through a ``MainLoopInbox``.
public enum PickerEvent: Sendable {
    /// The full history, newest first — a prefetch, or a re-fetch after the
    /// history changed. Painted straight away only when the query is blank.
    case history([ClipDocument])
    /// A search reply, tagged with the query that asked for it so the
    /// controller can drop one that a later keystroke has already outraced.
    case results(query: String, rows: [ClipDocument])
    /// The picture one entry holds, for the row to draw.
    case preview(hash: String, document: PreviewDocument)
    /// A copy landed on the clipboard; the picker closes.
    case copied
    /// An action was attempted and refused, with a sentence for the footer.
    case failed(String)
    /// The daemon could not be reached, with a headline and a remedy for the
    /// empty state.
    case unreachable(headline: String, detail: String)
}

extension PickerEvent {
    /// The unreachable event for `error`, phrased for the picker's empty state.
    ///
    /// The app auto-starts the daemon, so a "not running" reads as a transient
    /// "trying to start it" rather than an instruction to run a command — the
    /// picker cannot type it for the user anyway.
    static func unreachable(for error: any Error) -> PickerEvent {
        guard let ipc = error as? IPCError else {
            return .unreachable(headline: "Can't reach Skrepka", detail: String(describing: error))
        }
        if ipc.isDaemonNotRunning {
            return .unreachable(
                headline: "Skrepka's background service isn't running",
                detail: "Trying to start it…"
            )
        }
        return .unreachable(headline: "Can't reach Skrepka", detail: ipc.remedy ?? ipc.description)
    }
}
