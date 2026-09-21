import Foundation

/// The names a TXT record browser is spelled with.
///
/// Confirmed against `avahi-daemon/org.freedesktop.Avahi.RecordBrowser.xml`,
/// the `RecordBrowserNew` entry in `org.freedesktop.Avahi.Server.xml`, and
/// `avahi-daemon/dbus-record-browser.c` — which sends every one of these
/// signals with `dbus_message_set_destination(m, i->client->name)`, so, like
/// the service browser's, they need no match rule.
extension AvahiNames {
    enum RecordBrowser {
        static let interface = "org.freedesktop.Avahi.RecordBrowser"
        /// `(i interface, i protocol, s name, q clazz, q type, ay rdata, u flags)`.
        ///
        /// `rdata` is the record's wire-format RDATA —
        /// `avahi_rdata_serialize` — so a TXT record arrives as RFC 6763 §6.1
        /// length-prefixed strings, not as the `aay` a resolver hands back.
        ///
        /// A new browser replays what avahi already has cached before anything
        /// live, and a cache-flush update arrives as `ItemNew` for the new rdata
        /// followed, about a second later, by `ItemRemove` for the old one
        /// (`avahi-core/cache.c`, `expire_in_one_second`).
        static let itemNew = "ItemNew"
        /// The same signature as ``itemNew``.
        static let itemRemove = "ItemRemove"
        /// `(s error)`
        static let failure = "Failure"
        /// `()`
        static let free = "Free"
    }

    /// `(i interface, i protocol, s name, q clazz, q type, u flags) -> o`.
    ///
    /// Each browser is one of the client's objects, so each counts against
    /// `objects-per-client-max` (1024 by default, `dbus-protocol.c`): one per
    /// sighted peer is far inside that.
    static let recordBrowserNew = "RecordBrowserNew"

    /// What avahi answers a publish with when its configuration forbids
    /// publishing. See `AvahiDiscovery+SelfPublishing.swift`.
    static let notPermittedError = "org.freedesktop.Avahi.NotPermittedError"

    /// `AVAHI_DNS_CLASS_IN` and `AVAHI_DNS_TYPE_TXT`, the DNS values RFC 1035
    /// §3.2.4 and §3.2.2 define.
    static let dnsClassInternet: UInt16 = 1
    static let dnsTypeTXT: UInt16 = 16

    /// The full DNS name of a service instance, in the escaped text form avahi
    /// parses: `Philipp\039s\032Mac._skrepka._tcp.local`.
    ///
    /// The escaping is `avahi_escape_label` in `avahi-common/domain.c`, byte for
    /// byte: a `.` or `\` gets a backslash in front of it, letters, digits, `_`
    /// and `-` pass through, and every other byte — a space, an apostrophe, each
    /// byte of a non-ASCII character — becomes `\` and three decimal digits.
    /// `RecordBrowserNew` refuses a name that does not unescape into valid
    /// labels, so the instance label has to go through this rather than being
    /// pasted in; `avahi_service_name_join` does the same for avahi's own
    /// clients.
    static func serviceRecordName(instance: String, serviceType: String, domain: String) -> String {
        let suffix = domain.isEmpty ? "local" : domain
        return "\(escapedLabel(instance)).\(serviceType).\(suffix)"
    }

    static func escapedLabel(_ label: String) -> String {
        var escaped = ""
        for byte in label.utf8 {
            switch byte {
            case UInt8(ascii: "."), UInt8(ascii: "\\"):
                escaped += "\\" + String(UnicodeScalar(byte))
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                escaped += String(UnicodeScalar(byte))
            default:
                let digits = String(byte)
                escaped += "\\" + String(repeating: "0", count: 3 - digits.count) + digits
            }
        }
        return escaped
    }
}
