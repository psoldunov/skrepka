import Foundation

/// The names on the session bus, in one place, so the daemon that exports them
/// and the clients that call them cannot drift.
///
/// ## Why the interface is versioned in its own name
///
/// The Phase 8 GNOME Shell extension ships through a review queue and will lag
/// the daemon by weeks. `dev.soldunov.Skrepka1` is a contract this project
/// promises not to break: a member is added, never removed or re-signatured. A
/// change that cannot be made additively becomes `…Skrepka2` exported alongside
/// it, and the old one keeps working until nothing calls it.
///
/// The trailing digit is the freedesktop convention — `org.freedesktop.DBus`
/// spells its own second interface `org.freedesktop.DBus.Properties`, and
/// `org.freedesktop.PolicyKit1` and `org.freedesktop.login1` both carry the
/// version in the name for exactly this reason.
///
/// ## Why the payloads are JSON strings
///
/// Every structured answer here is a `s` carrying a JSON document rather than a
/// D-Bus container type, and that is a deliberate trade rather than laziness.
///
/// - **A lagging client keeps working.** Adding a field to `a(sssbt)` changes
///   the signature, which is a breaking change to every client compiled against
///   it; adding a key to a JSON object is one a client that has never heard of
///   it ignores. Given that the extension is *expected* to lag, the wire format
///   has to tolerate it.
/// - **The other client is JavaScript.** A GNOME Shell extension calls
///   `JSON.parse` in one line; unpacking a nested `GVariant` of tuples is a
///   loop over `deep_unpack` per shape.
/// - **The CLI needs it anyway.** `skrepka list --json` and `skrepka doctor
///   --json` are Phase 6 deliverables, so a JSON rendering of every document
///   exists whatever the bus carries. Two renderings would be two things to
///   keep in step.
///
/// The cost is that D-Bus introspection describes the *shape of the call* and
/// not the shape of the answer. ``SkrepkaDocument/version`` is what replaces
/// it: every document carries one, so a client can say which daemon wrote what
/// it is holding. It does not gate the decode — refusing a newer document would
/// reintroduce exactly the lagging-client breakage this format was chosen to
/// avoid, since additive-only members mean a newer document still decodes.
public enum SkrepkaInterface {
    /// The well-known name the daemon owns on the session bus.
    ///
    /// Session, not system. The daemon needs `$WAYLAND_DISPLAY` or `$DISPLAY`
    /// and the user's own session bus, neither of which a system service has —
    /// which is the same reason the systemd unit is a user unit.
    public static let busName = "dev.soldunov.Skrepka"

    /// The single object the daemon exports.
    ///
    /// One object rather than one per clip: a clip is identified by its content
    /// hash, which is not a valid object-path element, and minting a path per
    /// history entry would put an unbounded set of objects on the bus.
    public static let objectPath = "/dev/soldunov/Skrepka"

    /// The versioned interface. See the type's discussion.
    public static let name = "dev.soldunov.Skrepka1"

    /// What ``Member/interfaceVersion`` answers.
    ///
    /// Bumped when a member is added, so a client can require a minimum without
    /// calling a method it is not sure exists — a `Method call … unknown method`
    /// error is indistinguishable from a daemon that is not running.
    public static let version: UInt32 = 1

    /// Every member this build exports, spelled once.
    public enum Member {
        /// `() -> u`. The only member whose signature is guaranteed for the
        /// life of the bus name, because it is what a client calls to find out
        /// what else it may call.
        public static let interfaceVersion = "InterfaceVersion"

        /// `(u limit) -> s`. ``HistoryDocument`` as JSON, newest first with
        /// pinned entries hoisted. `limit` of 0 means every entry.
        public static let history = "History"

        /// `(s selector) -> s`. Puts one entry on the clipboard.
        /// ``ActionDocument`` as JSON. See ``ClipSelector``.
        public static let copy = "Copy"

        /// `(s json) -> s`. Records a clip this daemon could not observe —
        /// the GNOME path, where Mutter implements no data-control protocol and
        /// the Shell extension is the only thing that can see a copy happen.
        /// Takes ``SubmitRequest``, answers ``ActionDocument``.
        public static let submit = "Submit"

        /// `() -> s`. ``PeersDocument`` as JSON.
        public static let peers = "Peers"

        /// `() -> s`. ``DiagnosticsDocument`` as JSON — what `skrepka doctor`
        /// prints and what the Phase 7 status pane will read.
        public static let diagnostics = "Diagnostics"

        /// `(u seconds) -> s`. Opens the pairing listener for `seconds`, and
        /// advertises its port. Answers ``PairingWindowDocument``.
        public static let openPairing = "OpenPairing"

        /// `() -> s`. Closes it early. Idempotent.
        public static let closePairing = "ClosePairing"

        /// `(s fingerprint) -> s`. Dials a discovered peer and runs pairing up
        /// to the point a human has to compare words. Answers
        /// ``PairingProposalDocument``; the caller then calls
        /// ``confirmPairing``.
        public static let pairWith = "PairWith"

        /// `(s deviceID, b accept) -> s`. Answers a proposal — either one
        /// ``pairWith`` returned, or one that arrived on the
        /// ``Signal/pairingRequested`` signal.
        public static let confirmPairing = "ConfirmPairing"

        /// `(s fingerprint) -> s`. Forgets a paired device.
        public static let unpair = "Unpair"

        /// `() -> s`. Exchanges indexes with every live peer now rather than on
        /// the timer. ``ActionDocument``.
        public static let syncNow = "SyncNow"
    }

    /// Signals a client may subscribe to.
    public enum Signal {
        /// `()`. The history changed — captured, learned from a peer, or
        /// evicted. Deliberately carries no payload: a client that cares reads
        /// ``Member/history`` afterwards, and a signal carrying the new item
        /// would put every clipboard entry on the bus for subscribers that only
        /// wanted to redraw a menu.
        public static let historyChanged = "HistoryChanged"

        /// `(s json)`. A peer dialled this device to pair and is waiting for an
        /// answer. Carries ``PairingProposalDocument``.
        ///
        /// **A client is not required to exist.** The daemon answers `false`
        /// when nothing confirms within its own window — see
        /// ``PairingProposalDocument/expiresAt``. A pairing that parked forever
        /// waiting for a CLI nobody ran is a suspended task on a machine with
        /// nobody watching.
        public static let pairingRequested = "PairingRequested"
    }
}
