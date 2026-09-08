import Foundation

/// Everything `org.freedesktop.Avahi` is spelled as, and the constants its
/// arguments take.
///
/// Confirmed against avahi 0.8's own interface definitions —
/// `avahi-daemon/org.freedesktop.Avahi.{Server,EntryGroup,ServiceBrowser,ServiceResolver}.xml`
/// and `avahi-common/defs.h` — rather than written from memory. Every signature
/// in the doc comments below is copied from that XML.
///
/// The daemon installs the same files at
/// `/usr/share/dbus-1/interfaces/org.freedesktop.Avahi.*.xml` on a machine that
/// has it, which is where to check them against a specific installation.
enum AvahiNames {
    static let busName = "org.freedesktop.Avahi"

    /// The server object. A single `/`, which is unusual and is what avahi
    /// uses.
    static let serverPath = "/"

    enum Interface {
        static let server = "org.freedesktop.Avahi.Server"
        static let entryGroup = "org.freedesktop.Avahi.EntryGroup"
        static let serviceBrowser = "org.freedesktop.Avahi.ServiceBrowser"
        static let serviceResolver = "org.freedesktop.Avahi.ServiceResolver"
    }

    enum Server {
        /// `() -> s`
        static let versionString = "GetVersionString"
        /// `(s name) -> s`
        ///
        /// What the *next* name after `name` would be — avahi's own
        /// `avahi_alternative_service_name`, which turns `steamdeck` into
        /// `steamdeck #2` and `steamdeck #2` into `steamdeck #3`. It grants
        /// nothing by itself: the answer is a name to try, and a `Commit` is
        /// what settles whether it was free.
        static let alternativeServiceName = "GetAlternativeServiceName"
        /// `() -> i`, answering an ``ServerState``.
        ///
        /// What ``Server/stateChanged`` reports, asked for rather than waited
        /// on. Needed exactly once: a bus connection that was replaced says
        /// nothing about whether `avahi-daemon` was replaced with it, and a
        /// `RUNNING` emitted before the new subscription was in place never
        /// arrives. See `AvahiDiscovery+Reconnect.swift`.
        static let getState = "GetState"
        /// `() -> o`
        static let entryGroupNew = "EntryGroupNew"
        /// `(i interface, i protocol, s type, s domain, u flags) -> o`.
        ///
        /// `…New` rather than `…Prepare`: the browser this creates starts by
        /// itself, where a prepared one waits for an explicit `Start`. Nothing
        /// here needs the gap between the two.
        static let serviceBrowserNew = "ServiceBrowserNew"
        /// `(i interface, i protocol, s name, s type, s domain, i aprotocol, u flags) -> o`
        static let serviceResolverNew = "ServiceResolverNew"
        /// `(i state, s error)`
        ///
        /// **The one avahi signal that is broadcast rather than directed.** The
        /// browser, resolver and entry-group signals all go out with
        /// `dbus_message_set_destination(m, i->client->name)` on them, so they
        /// arrive without a match rule; `dbus-protocol.c` emits this one with no
        /// destination at all, so it arrives only for a client that asked
        /// `org.freedesktop.DBus` for it. See ``BusDaemon/serverStateRule``.
        static let stateChanged = "StateChanged"
    }

    /// The bus daemon's own object — needed for two things here: the match rule
    /// that makes ``Server/stateChanged`` reachable, and the owner check that
    /// says whether a `StateChanged` really came from avahi.
    ///
    /// Both signatures are from version 0.43 of the D-Bus specification's
    /// `org.freedesktop.DBus` interface, not from the Swift client, which wraps
    /// neither.
    enum BusDaemon {
        static let name = "org.freedesktop.DBus"
        static let path = "/org/freedesktop/DBus"
        static let interface = "org.freedesktop.DBus"
        /// `(s rule)`. Errors by reply rather than by throwing, so the reply has
        /// to be read: a rejected rule leaves a client silently deaf.
        static let addMatch = "AddMatch"
        /// `STRING GetNameOwner (in STRING name)` — the *unique* connection name
        /// of whoever owns a well-known one, `:1.42` rather than
        /// `org.freedesktop.Avahi`, and `org.freedesktop.DBus.Error.NameHasNoOwner`
        /// when nothing owns it.
        ///
        /// A signal's sender field carries the unique name, so this is what a
        /// `Server.StateChanged` has to be checked against — a match rule cannot
        /// do it, because a directed signal is delivered regardless of match
        /// rules.
        static let getNameOwner = "GetNameOwner"
        /// Every signal avahi's server object emits, and nothing else. Narrower
        /// than `sender=` alone, because the daemon also broadcasts on the
        /// browser and resolver interfaces to clients that asked for those.
        static let serverStateRule =
            "type='signal',sender='\(AvahiNames.busName)',"
            + "interface='\(AvahiNames.Interface.server)'"
    }

    enum EntryGroup {
        /// `(i interface, i protocol, u flags, s name, s type, s domain, s host, q port, aay txt)`
        ///
        /// `txt` is `aay` — an array of raw `key=value` byte arrays with no
        /// length prefixes, and no promise the bytes are text. That is why
        /// `TXTRecord` is ordered byte pairs rather than a `[String: String]`,
        /// and `TXTRecord.Entry.rawBytes` is exactly one element of it.
        static let addService = "AddService"
        /// `(i interface, i protocol, u flags, s name, s type, s domain, aay txt)`
        ///
        /// The in-place TXT update — avahi's answer to
        /// `DNSServiceUpdateRecord`, and what makes `AdvertisementChange.record`
        /// possible here rather than a withdraw-and-republish that blinks the
        /// device off every peer's list.
        static let updateServiceTxt = "UpdateServiceTxt"
        /// `()`
        static let commit = "Commit"
        /// `()`
        static let reset = "Reset"
        /// `()`
        static let free = "Free"
        /// `(i state, s error)`
        static let stateChanged = "StateChanged"
    }

    enum Browser {
        /// `(i interface, i protocol, s name, s type, s domain, u flags)`
        static let itemNew = "ItemNew"
        /// The same signature.
        static let itemRemove = "ItemRemove"
        /// `()`. Every answer the cache and the first round of queries had.
        /// Not the end of anything — more may arrive later.
        static let allForNow = "AllForNow"
        /// `(s error)`
        static let failure = "Failure"
        /// `()`
        static let free = "Free"
    }

    enum Resolver {
        /// `(i interface, i protocol, s name, s type, s domain, s host,
        ///   i aprotocol, s address, q port, aay txt, u flags)`
        static let found = "Found"
        /// `(s error)`
        static let failure = "Failure"
        /// `()`
        static let free = "Free"
    }

    /// `AVAHI_IF_UNSPEC` and `AVAHI_PROTO_UNSPEC`, from `avahi-common/defs.h`
    /// and `address.h`. Both are `-1`, which is why
    /// ``SkrepkaSync/DiscoveredPeer/interfaceIndex`` is optional rather than
    /// carrying a magic number: dns_sd spells the same idea `0`.
    static let unspecifiedInterface: Int32 = -1
    static let unspecifiedProtocol: Int32 = -1

    /// `AVAHI_PROTO_INET`. Only used to say "resolve to whatever address family
    /// you have"; Skrepka connects by host name, not by address.
    static let protocolInet: Int32 = 0

    /// The state an entry group reports on `StateChanged`, from
    /// `avahi-common/defs.h`.
    enum EntryGroupState: Int32 {
        case uncommitted = 0
        case registering = 1
        case established = 2
        /// The name is taken and avahi could not rename around it.
        case collision = 3
        case failure = 4
    }

    /// The state the daemon itself reports on `Server.StateChanged`, from
    /// `AvahiServerState` in `avahi-common/defs.h`.
    ///
    /// Numbered separately from ``EntryGroupState`` even though the first three
    /// look alike — they are two enumerations in that header and nothing
    /// promises they stay in step.
    enum ServerState: Int32 {
        case invalid = 0
        case registering = 1
        /// Every host record is established. Also what arrives after the daemon
        /// has been restarted, at which point every browser and entry group it
        /// owned is gone and has to be created again.
        case running = 2
        case collision = 3
        case failure = 4
    }

    /// `AVAHI_LOOKUP_RESULT_LOCAL`, set on a browse result this host announced
    /// itself.
    ///
    /// Not used to filter — the device identifier in the TXT record is the
    /// authority on "is this me", and it works across two Skrepka processes on
    /// one machine where this flag does not. Recorded so nobody re-derives what
    /// bit 8 means.
    static let lookupResultLocal: UInt32 = 8
}
