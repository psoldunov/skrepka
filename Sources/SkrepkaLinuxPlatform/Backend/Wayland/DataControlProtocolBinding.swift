import CWaylandClient
import Foundation

/// The half of a data-control protocol that differs between its two spellings.
///
/// ## Why there is one engine and two of these
///
/// `ext-data-control-v1` and `zwlr-data-control-unstable-v1` are the same
/// protocol under two names. Verified 2026-09-07 by normalising the
/// `ext_data_control_` and `zwlr_data_control_` prefixes off both vendored XML
/// files and comparing every interface, request, event, entry and argument:
/// **37 entries each, identical**. `wayland-scanner` generates 665 lines of
/// header from either.
///
/// So the protocol state machine — offer accumulation, pipe transfers, the
/// selection lifecycle — is written once in ``DataControlSession``, and this is
/// the seam it reaches the wire through. Two full implementations would mean a
/// bug fixed in one sitting unfixed in the other, and the deprecated spelling
/// is the one with hardware behind it: SteamOS 3.8's Plasma 6.4.3 advertises
/// both globals, and every wlroots older than 0.19 advertises only `wlr`.
///
/// Everything below is an instance member rather than a static one because a
/// conformer owns heap-allocated `wl_*_listener` structs whose lifetime must
/// outlast every proxy they are attached to. Instance storage gives them an
/// owner and a `deinit`; a global would need to be `Sendable`, and the honest
/// spellings of that for a raw pointer are all ones this repository forbids.
protocol DataControlProtocolBinding: AnyObject {
    /// The registry global to bind, e.g. `ext_data_control_manager_v1`.
    var globalInterfaceName: String { get }
    /// The interface `wl_registry_bind` needs to construct the manager proxy.
    var managerInterface: UnsafePointer<wl_interface> { get }
    /// Highest version of the global this client knows how to drive.
    ///
    /// Both protocols are at version 2 today and version 1 carries everything
    /// used here, so the bind takes `min(advertised, this)` and never refuses a
    /// compositor for being older than expected.
    var supportedVersion: UInt32 { get }

    func makeDevice(manager: OpaquePointer, seat: OpaquePointer) -> OpaquePointer?
    func makeSource(manager: OpaquePointer) -> OpaquePointer?

    /// Attaches the listener that delivers `data_offer`, `selection`,
    /// `finished` and `primary_selection`, trampolining each into `session`.
    func attachDeviceListener(_ device: OpaquePointer, session: UnsafeMutableRawPointer)
    /// Attaches the listener that delivers one `offer` per advertised MIME type.
    func attachOfferListener(_ offer: OpaquePointer, session: UnsafeMutableRawPointer)
    /// Attaches the listener that delivers `send` and `cancelled`.
    func attachSourceListener(_ source: OpaquePointer, session: UnsafeMutableRawPointer)

    func receive(offer: OpaquePointer, mimeType: String, fileDescriptor: Int32)
    func offer(source: OpaquePointer, mimeType: String)
    func setSelection(device: OpaquePointer, source: OpaquePointer?)

    func destroyManager(_ manager: OpaquePointer)
    func destroyDevice(_ device: OpaquePointer)
    func destroyOffer(_ offer: OpaquePointer)
    func destroySource(_ source: OpaquePointer)
}

extension DataControlProtocolBinding {
    /// The manager proxy for this protocol, bound out of the registry.
    ///
    /// Returns nil when the compositor does not advertise the global, which is
    /// the ordinary answer rather than a failure: ``SessionProbe`` has already
    /// decided which binding to use, and this is where that decision is proved
    /// against the live connection instead of a snapshot of it.
    func bind(registry: OpaquePointer, name: UInt32, advertisedVersion: UInt32) -> OpaquePointer? {
        wl_registry_bind(registry, name, managerInterface, min(advertisedVersion, supportedVersion))
            .map(OpaquePointer.init)
    }
}

/// What a binding's C callbacks call back into.
///
/// Free `@convention(c)` functions capture nothing, so each callback recovers
/// the session from the listener's `data` pointer and calls one of these. The
/// protocol exists so the two binding files can be written without importing
/// the session's internals, and so the compiler checks that both deliver the
/// same seven events.
protocol DataControlSessionEvents: AnyObject {
    func didIntroduceOffer(_ offer: OpaquePointer)
    func offer(_ offer: OpaquePointer, advertises mimeType: String)
    func didReceiveSelection(_ offer: OpaquePointer?)
    func didFinish()
    func sourceWasAskedToSend(mimeType: String, fileDescriptor: Int32)
    func sourceWasCancelled()
}

/// Recovers the session a listener was attached with.
///
/// Unretained on purpose: the session owns every proxy these listeners are
/// attached to and destroys them in its own teardown, so a listener can never
/// outlive it. Retaining here would make that ownership a cycle instead.
func dataControlSession(from data: UnsafeMutableRawPointer?) -> (any DataControlSessionEvents)? {
    guard let data else { return nil }
    return Unmanaged<DataControlSession>.fromOpaque(data).takeUnretainedValue()
}
