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
    ///
    /// - 1: the Phase 6 surface.
    /// - 2: ``Member/setLivePush``, and the live-push choice and default on
    ///   ``PeerDocument`` that a client needs to draw the switch it sets.
    /// - 3: the picker's members — ``Member/search``, ``Member/copyAs``,
    ///   ``Member/setPinned``, ``Member/delete``, ``Member/clear`` and
    ///   ``Member/preview`` — and the row fields on ``ClipDocument`` a picker
    ///   draws its subtitle from.
    /// - 4: ``Member/settings`` and ``Member/setSettings`` — retention and the
    ///   sync switch, settable from the Settings window and `skrepka config`.
    public static let version: UInt32 = 4

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

        /// `(s device, s choice) -> s`. Records whether what is copied here
        /// goes straight to one paired device's clipboard. `device` names it
        /// the way ``unpair`` does — a fingerprint, or a prefix of the device
        /// ID that matches exactly one paired device. `choice` is one of
        /// ``PeerDocument/LivePushChoiceName``; anything else is refused as an
        /// invalid argument. Answers ``ActionDocument``. Since version 2.
        public static let setLivePush = "SetLivePush"

        /// `() -> s`. Exchanges indexes with every live peer now rather than on
        /// the timer. ``ActionDocument``.
        public static let syncNow = "SyncNow"

        /// `(s query, u limit) -> s`. ``HistoryDocument`` holding the entries
        /// that match `query`, best match first — `Matcher`'s ranking, run over
        /// the full text the daemon holds rather than the one-line previews a
        /// client has. `total` counts every match; `limit` of 0 means all of
        /// them. A blank query answers what ``history`` answers. Since
        /// version 3.
        public static let search = "Search"

        /// `(s selector, s style) -> s`. ``copy``, in a chosen style: `style`
        /// is a ``CopyStyle`` wire name, and `plain` writes the entry's text
        /// alone so the app it lands in cannot pick up its formatting. Anything
        /// else is refused as an invalid argument. ``ActionDocument``. Since
        /// version 3.
        public static let copyAs = "CopyAs"

        /// `(s selector, b pinned) -> s`. Pins or unpins one entry, and the
        /// change reaches paired devices the way a pin made on a Mac does.
        /// Idempotent: pinning a pinned entry succeeds and changes nothing.
        /// ``ActionDocument``. Since version 3.
        public static let setPinned = "SetPinned"

        /// `(s selector) -> s`. Deletes one entry, and records the deletion so
        /// a paired device does not bring it back. ``ActionDocument``. Since
        /// version 3.
        public static let delete = "Delete"

        /// `(b keepPinned) -> s`. Deletes every entry — every unpinned one when
        /// `keepPinned` is true. Recorded for peers like ``delete``.
        /// ``ActionDocument``. Since version 3.
        public static let clear = "Clear"

        /// `(s selector, u maxBytes) -> s`. The picture an entry holds, for a
        /// client to draw a thumbnail from. ``PreviewDocument`` as JSON, the
        /// bytes base64-encoded. `maxBytes` is capped at
        /// ``PreviewDocument/defaultByteLimit``: 0 uses that cap, and a larger
        /// value is clamped to it. An entry over the resulting limit or holding no
        /// picture answers a document with no data and a sentence saying why.
        /// Since version 3.
        public static let preview = "Preview"

        /// `() -> s`. ``SettingsDocument`` as JSON: retention, the sync switch,
        /// the history's figures and the markers that are always protected.
        /// Since version 4.
        public static let settings = "Settings"

        /// `(s patch) -> s`. Takes ``SettingsPatch`` as JSON and changes only
        /// what it names. A lower retention limit applies at once, not at the
        /// next copy; turning sync off withdraws this device from the network.
        /// Answers ``ActionDocument``; a limit out of range is `ok: false`,
        /// JSON that is not a patch is an invalid-argument error. Since
        /// version 4.
        public static let setSettings = "SetSettings"
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
