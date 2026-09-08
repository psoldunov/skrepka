import Foundation

/// What `skrepka doctor` reports, and what the Phase 7 status pane will read.
///
/// One document for both, so the CLI and the GUI cannot disagree about whether
/// this machine is working — which is the whole reason the phase plan asks for
/// a shared shape rather than a `doctor` that formats its own findings.
///
/// **Everything here is a fact the daemon measured, not a value invented to
/// fill a field.** A question that does not arise on Linux is absent rather
/// than answered `false`: there is no accessibility permission and no
/// login-item approval state, so neither appears. What replaces them is the set
/// below, which is what the phase plan asks `doctor` to report plainly — which
/// backend was chosen, whether the GNOME extension is needed and missing, and
/// whether a responder is running.
public struct DiagnosticsDocument: SkrepkaDocument, Hashable {
    /// The clipboard half: what the session probe found.
    public struct Session: Codable, Sendable, Hashable {
        /// `extDataControl`, `wlrDataControl`, `xFixes`, or nil where the
        /// session offers nothing to watch.
        public let backend: String?

        /// The human spelling of the same, for a report someone pastes into an
        /// issue.
        public let backendName: String

        /// Every global the compositor advertised, in the order it did.
        /// Recorded rather than reduced, because "which globals were there" is
        /// the first question about a session that will not capture.
        public let waylandGlobals: [String]

        public let waylandDisplay: String?
        public let x11Display: String?

        /// `XDG_CURRENT_DESKTOP`, verbatim.
        public let desktop: String?

        /// Whether X11 was chosen while a Wayland session was running — the
        /// lossy path, since XWayland sees only what XWayland clients copy.
        public let isXWaylandFallback: Bool

        /// The probe's finding, or nil where it found nothing to say.
        public let problem: String?

        /// Whether that finding stops capture working. A session on the
        /// deprecated protocol reports a problem and captures perfectly well.
        public let isBlocking: Bool

        /// How many times the backend has been rebuilt because the session went
        /// away — a compositor restart, a log out and back in. Nonzero is not a
        /// fault; it is what point 9 of the phase's "done when" asks to be
        /// visible rather than silent.
        public let restarts: Int

        public init(
            backend: String?,
            backendName: String,
            waylandGlobals: [String],
            waylandDisplay: String?,
            x11Display: String?,
            desktop: String?,
            isXWaylandFallback: Bool,
            problem: String?,
            isBlocking: Bool,
            restarts: Int
        ) {
            self.backend = backend
            self.backendName = backendName
            self.waylandGlobals = waylandGlobals
            self.waylandDisplay = waylandDisplay
            self.x11Display = x11Display
            self.desktop = desktop
            self.isXWaylandFallback = isXWaylandFallback
            self.problem = problem
            self.isBlocking = isBlocking
            self.restarts = restarts
        }
    }

    /// The network half.
    public struct Network: Codable, Sendable, Hashable {
        /// `avahi`, or `none` where no responder could be reached.
        public let responder: String

        /// What the responder said when it could not be used. Nil when it
        /// could.
        public let responderProblem: String?

        /// Whether this device's own record is published right now.
        public let isPublished: Bool

        /// The port the pinned sync listener bound, or nil when sync is off.
        public let syncPort: UInt16?

        /// Paired peers, and how many of those are visible on the network. The
        /// gap is the interesting number.
        public let pairedCount: Int
        public let sightedCount: Int

        public init(
            responder: String,
            responderProblem: String?,
            isPublished: Bool,
            syncPort: UInt16?,
            pairedCount: Int,
            sightedCount: Int
        ) {
            self.responder = responder
            self.responderProblem = responderProblem
            self.isPublished = isPublished
            self.syncPort = syncPort
            self.pairedCount = pairedCount
            self.sightedCount = sightedCount
        }
    }

    /// The storage half.
    public struct Storage: Codable, Sendable, Hashable {
        public let path: String
        public let itemCount: Int
        public let lastCapturedAt: Date?

        /// Octal, as four characters — `0600`. Reported because the store holds
        /// the plainest copy of everything the user has ever copied, and a
        /// mode that drifted is not something anyone checks by hand.
        public let mode: String

        public init(path: String, itemCount: Int, lastCapturedAt: Date?, mode: String) {
            self.path = path
            self.itemCount = itemCount
            self.lastCapturedAt = lastCapturedAt
            self.mode = mode
        }
    }

    public let version: UInt32
    public let daemonVersion: String
    public let deviceFingerprint: String
    public let session: Session
    public let network: Network
    public let storage: Storage

    /// The problems worth putting in front of the user, most serious first.
    /// Empty when there are none, which is what makes `doctor` worth running:
    /// an empty list is an answer.
    public let problems: [String]

    public init(
        daemonVersion: String,
        deviceFingerprint: String,
        session: Session,
        network: Network,
        storage: Storage,
        problems: [String],
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.daemonVersion = daemonVersion
        self.deviceFingerprint = deviceFingerprint
        self.session = session
        self.network = network
        self.storage = storage
        self.problems = problems
    }
}
