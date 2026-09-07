import Foundation
import SkrepkaCore

/// What is wrong — or merely worth saying — about this session's ability to
/// watch the clipboard.
///
/// Three findings, and only two of them are problems. `DiagnosticsProblem`
/// answers "what should the user be told to fix"; this answers "what did the
/// probe find", which is a wider question and the one a pasted bug report needs.
/// A session on the deprecated protocol is captured perfectly well and has
/// nothing for the user to do, so it lives here and never reaches
/// ``SkrepkaCore/DiagnosticsProblem/ranked(storage:clipboardStatus:pasteBack:session:)``.
///
/// The words for the two real problems are not restated here. They belong to
/// `DiagnosticsProblem`, which is documented as the single owner of that
/// vocabulary, and a second copy is how the picker and the report end up
/// disagreeing about what to tell the user.
public enum LinuxCaptureProblem: Sendable, Hashable, CaseIterable {
    /// No data-control global, and no X11 server to fall back to. Capture
    /// cannot work in this session.
    case noDataControlProtocol
    /// GNOME Wayland with no Shell extension. Mutter implements no data-control
    /// protocol, so this is the expected finding there rather than a fault.
    case gnomeWithoutShellExtension
    /// Only `zwlr_data_control_manager_v1` is advertised. Capture works; the
    /// protocol is deprecated by its own authors.
    case deprecatedProtocolOnly

    /// Whether this finding stops capture working.
    ///
    /// The distinction the type exists for. `false` means "report it, do not
    /// act on it" — the deprecated protocol captures every clipboard change the
    /// current one does.
    public var isBlocking: Bool { asDiagnosticsProblem != nil }

    /// The user-facing problem, or nil when the finding is informational.
    public var asDiagnosticsProblem: DiagnosticsProblem.SessionProblem? {
        switch self {
        case .noDataControlProtocol: .noDataControlProtocol
        case .gnomeWithoutShellExtension: .gnomeWithoutShellExtension
        case .deprecatedProtocolOnly: nil
        }
    }

    /// One line for the pasted diagnostics report.
    ///
    /// The blocking cases defer to `DiagnosticsProblem` so the wording is
    /// written once; only the informational case, which has no counterpart
    /// there, spells itself out.
    public var reportLine: String {
        switch self {
        case .noDataControlProtocol, .gnomeWithoutShellExtension:
            asDiagnosticsProblem?.problem.summary ?? ""
        case .deprecatedProtocolOnly:
            """
            Capturing through wlr-data-control, which its authors have deprecated. \
            Nothing is lost; a newer compositor will offer ext-data-control-v1 instead.
            """
        }
    }
}
