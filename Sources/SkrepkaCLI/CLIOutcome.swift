import Foundation
import SkrepkaIPC

/// What the CLI does with an ``ActionDocument``.
///
/// The daemon answers `ok: false` for an outcome it attempted and could not
/// produce — an entry with nothing this session can write, a fingerprint that
/// names nothing. That is a failure the daemon reported rather than a fault, so
/// it is exit code 1 with the daemon's own sentence on stderr, and never a
/// stack of D-Bus jargon.
public enum CLIOutcome {
    /// Prints the outcome and answers with the process's exit code.
    ///
    /// `whenSilent` covers the dull success, where ``ActionDocument/detail`` is
    /// empty because there was nothing to say — the CLI still says something,
    /// because a command that prints nothing looks like one that did nothing.
    public static func report(_ document: ActionDocument, whenSilent: String) -> Int32 {
        let detail = document.detail.isEmpty ? whenSilent : document.detail
        if document.ok {
            CLIConsole.say(detail)
            return 0
        }
        CLIConsole.fail(detail)
        return 1
    }
}
