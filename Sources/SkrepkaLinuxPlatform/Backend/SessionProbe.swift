import Foundation
import SkrepkaCore

/// What the session actually offers, and which backend that implies.
///
/// ## Probe, do not read environment variables
///
/// The obvious implementation reads `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE`
/// and picks a backend from them. That is wrong often enough to matter: an
/// XWayland client sees `DISPLAY` set under a Wayland session, and a Wayland
/// session may advertise neither data-control global while still setting
/// `WAYLAND_DISPLAY`. The environment says what kind of session this is; only
/// the registry says what it can do.
///
/// So the decision is made from the advertised global list, and the environment
/// contributes exactly one thing — the desktop's name — which is used to write
/// a better message and never to choose a backend.
public struct SessionProbe: Sendable {
    /// Everything the probe found, whether or not it found a backend.
    public struct Report: Sendable, Hashable {
        public let backend: LinuxClipboardBackendKind?
        /// Every global the compositor advertised, in the order it did.
        /// Recorded rather than reduced to a decision, because "which globals
        /// were there" is the first question any report of this going wrong has
        /// to answer.
        public let waylandGlobals: [String]
        public let waylandDisplay: String?
        public let x11Display: String?
        /// `XDG_CURRENT_DESKTOP`, verbatim and unparsed.
        public let desktop: String?
        public let problem: LinuxCaptureProblem?

        /// Whether the X11 backend was chosen while a Wayland session was
        /// running — the lossy path, per the phase plan, because XWayland only
        /// sees what XWayland clients put on the clipboard.
        public var isXWaylandFallback: Bool {
            backend == .xFixes && waylandDisplay != nil
        }
    }

    public static let extGlobal = "ext_data_control_manager_v1"
    public static let wlrGlobal = "zwlr_data_control_manager_v1"

    public init() {}

    /// The decision table, as a pure function of what was found.
    ///
    /// Separated from ``run()`` so it can be tested over synthetic global lists
    /// — every branch below is a compositor this project has no hardware for.
    ///
    /// Order matters and is the plan's, with one amendment. `ext` outranks
    /// `wlr` **when both are present**, which is not a hypothetical: KWin's
    /// port to `ext-data-control-v1` (merge request !6606) landed in Plasma
    /// **6.4**, and that release advertises both globals from one
    /// implementation — verified 2026-09-07 against
    /// `src/wayland/datacontroldevicemanager_v1.cpp` on the `Plasma/6.4`
    /// branch, which creates the legacy global by hand alongside the new one.
    /// Plasma 6.5 dropped it. A backend chooser that took the first global it
    /// recognised would bind both on 6.4 and record every copy twice.
    public static func decide(
        waylandGlobals: [String],
        waylandDisplay: String?,
        x11Display: String?,
        desktop: String?
    ) -> Report {
        let backend: LinuxClipboardBackendKind?
        let problem: LinuxCaptureProblem?

        if waylandGlobals.contains(extGlobal) {
            backend = .extDataControl
            problem = nil
        } else if waylandGlobals.contains(wlrGlobal) {
            backend = .wlrDataControl
            problem = .deprecatedProtocolOnly
        } else if x11Display != nil {
            backend = .xFixes
            // Not a problem even under Wayland. XWayland is a real X server and
            // capture through it works; what it cannot see is native Wayland
            // clients, which `Report.isXWaylandFallback` is what tells the
            // report to say.
            problem = nil
        } else {
            backend = nil
            problem = isGNOME(desktop) ? .gnomeWithoutShellExtension : .noDataControlProtocol
        }

        return Report(
            backend: backend,
            waylandGlobals: waylandGlobals,
            waylandDisplay: waylandDisplay,
            x11Display: x11Display,
            desktop: desktop,
            problem: problem
        )
    }

    /// Whether `XDG_CURRENT_DESKTOP` names GNOME.
    ///
    /// The variable is a colon-separated list — `ubuntu:GNOME` is what Ubuntu
    /// sets — so it is split rather than compared, and matched case
    /// insensitively because the spelling is not guaranteed.
    ///
    /// Used only to pick between two messages once the backend decision has
    /// already been made and come out empty. Getting it wrong costs a less
    /// specific remedy, never a wrong backend.
    static func isGNOME(_ desktop: String?) -> Bool {
        guard let desktop else { return false }
        return
            desktop
            .split(separator: ":")
            .contains { $0.compare("GNOME", options: .caseInsensitive) == .orderedSame }
    }

    /// Probes the live session.
    ///
    /// Connects to the Wayland display if there is one, enumerates its globals
    /// and disconnects; then, if nothing there can watch a clipboard, checks
    /// whether an X11 display will accept a connection. Both connections are
    /// opened and closed here rather than handed on: the backend that gets
    /// chosen opens its own, and a probe that leaked a display connection into
    /// the chosen backend would make the two impossible to test apart.
    public func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Report {
        let waylandDisplay = environment["WAYLAND_DISPLAY"]
        // The name from `environment`, not from the process's own — otherwise
        // `run(environment:)` would only appear to take an argument.
        let globals = waylandDisplay.map { WaylandGlobals.enumerate(displayName: $0) } ?? []
        let x11Display = environment["DISPLAY"]

        return Self.decide(
            waylandGlobals: globals,
            waylandDisplay: waylandDisplay,
            // A `DISPLAY` that nothing answers is worse than no `DISPLAY` at
            // all: it would send the chooser down the X11 path to fail there
            // instead of reporting an unwatchable session. So the variable is
            // only believed once a connection has actually opened.
            x11Display: x11Display.flatMap { XDisplayProbe.canConnect($0) ? $0 : nil },
            desktop: environment["XDG_CURRENT_DESKTOP"]
        )
    }
}
