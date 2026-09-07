import CWaylandClient
import CWaylandProtocols
import Foundation

/// `zwlr-data-control-unstable-v1`, the wlroots protocol.
///
/// Deprecated by its own authors — the XML vendored beside this file says so —
/// and that is not the same as unexercised. It is the only data-control
/// protocol Wayfire and river advertise, the only one every wlroots older than
/// 0.19 advertises, and one of the two Plasma 6.4 advertises. This project's
/// own test rig runs a headless Sway 1.9, which advertises
/// `zwlr_data_control_manager_v1` version 2 and nothing newer, so this is the
/// binding the integration tests actually drive.
///
/// Packaged by no distribution: the XML lives in the `wlr-protocols`
/// repository, which is why it is vendored rather than read from
/// `wayland-protocols`.
///
/// Byte for byte ``ExtDataControlBinding`` with the other prefix, and that is
/// checked rather than asserted: the two vendored XML files normalise to 37
/// identical interface, request, event and argument entries. If one of them
/// ever gains something the other has not, this file and that one stop being
/// substitutable and the generated headers say so at compile time.
final class WlrDataControlBinding: DataControlProtocolBinding {
    let globalInterfaceName = SessionProbe.wlrGlobal
    let managerInterface: UnsafePointer<wl_interface>
    let supportedVersion: UInt32 = 1

    /// The three listeners, heap-allocated for the binding's lifetime.
    ///
    /// libwayland keeps the pointer it is handed rather than copying the
    /// struct, so a listener built on the stack and passed to `add_listener`
    /// is a dangling pointer the moment the call returns — and one that keeps
    /// working until the first event arrives, which is the worst kind.
    /// Named once each, because the generated type names are long enough that
    /// a signature carrying one wraps — and a wrapped return type puts the
    /// opening brace on its own line, which the lint refuses.
    private typealias DeviceListener = UnsafeMutablePointer<zwlr_data_control_device_v1_listener>
    private typealias OfferListener = UnsafeMutablePointer<zwlr_data_control_offer_v1_listener>
    private typealias SourceListener = UnsafeMutablePointer<zwlr_data_control_source_v1_listener>

    private let deviceListener: DeviceListener
    private let offerListener: OfferListener
    private let sourceListener: SourceListener

    init() {
        // Not `withUnsafePointer(to:)` on the imported global: that yields the
        // real symbol address in practice but promises a copy, and libwayland
        // stores this pointer inside every proxy bound with it. See the comment
        // on the accessor in Sources/CWaylandProtocols/include/.
        guard let interface = skrepka_wlr_data_control_manager_interface() else {
            // The symbol is linked into this binary; it cannot be absent. The
            // accessor is only nullable because Swift imports every C pointer
            // return that way.
            preconditionFailure("zwlr_data_control_manager_v1_interface is not linked")
        }
        managerInterface = interface

        deviceListener = Self.makeDeviceListener()
        offerListener = Self.makeOfferListener()
        sourceListener = Self.makeSourceListener()
    }

    /// Heap-allocated because libwayland keeps the pointer rather than copying
    /// the struct; freed in `deinit`. Split out of `init` so the initializer
    /// stays inside the repository's function-length budget.
    private static func makeDeviceListener() -> DeviceListener {
        let listener = DeviceListener.allocate(capacity: 1)
        listener.initialize(
            to: zwlr_data_control_device_v1_listener(
                data_offer: { data, _, offer in
                    guard let offer else { return }
                    dataControlSession(from: data)?.didIntroduceOffer(offer)
                },
                selection: { data, _, offer in
                    dataControlSession(from: data)?.didReceiveSelection(offer)
                },
                finished: { data, _ in
                    dataControlSession(from: data)?.didFinish()
                },
                // Skrepka has no primary-selection history: the middle-click
                // selection changes on every drag through a text field, and
                // recording it would fill history with fragments the user never
                // asked to keep. The callback is required by the struct and
                // deliberately does nothing.
                primary_selection: { _, _, _ in }
            )
        )
        return listener
    }

    private static func makeOfferListener() -> OfferListener {
        let listener = OfferListener.allocate(capacity: 1)
        listener.initialize(
            to: zwlr_data_control_offer_v1_listener(
                offer: { data, offer, mimeType in
                    guard let offer, let mimeType else { return }
                    dataControlSession(from: data)?.offer(offer, advertises: String(cString: mimeType))
                }
            )
        )
        return listener
    }

    private static func makeSourceListener() -> SourceListener {
        let listener = SourceListener.allocate(capacity: 1)
        listener.initialize(
            to: zwlr_data_control_source_v1_listener(
                send: { data, _, mimeType, fileDescriptor in
                    guard let mimeType else { return }
                    dataControlSession(from: data)?
                        .sourceWasAskedToSend(
                            mimeType: String(cString: mimeType),
                            fileDescriptor: fileDescriptor
                        )
                },
                cancelled: { data, _ in
                    dataControlSession(from: data)?.sourceWasCancelled()
                }
            )
        )
        return listener
    }

    deinit {
        deviceListener.deinitialize(count: 1)
        deviceListener.deallocate()
        offerListener.deinitialize(count: 1)
        offerListener.deallocate()
        sourceListener.deinitialize(count: 1)
        sourceListener.deallocate()
    }

    func makeDevice(manager: OpaquePointer, seat: OpaquePointer) -> OpaquePointer? {
        zwlr_data_control_manager_v1_get_data_device(manager, seat)
    }

    func makeSource(manager: OpaquePointer) -> OpaquePointer? {
        zwlr_data_control_manager_v1_create_data_source(manager)
    }

    func attachDeviceListener(_ device: OpaquePointer, session: UnsafeMutableRawPointer) {
        zwlr_data_control_device_v1_add_listener(device, deviceListener, session)
    }

    func attachOfferListener(_ offer: OpaquePointer, session: UnsafeMutableRawPointer) {
        zwlr_data_control_offer_v1_add_listener(offer, offerListener, session)
    }

    func attachSourceListener(_ source: OpaquePointer, session: UnsafeMutableRawPointer) {
        zwlr_data_control_source_v1_add_listener(source, sourceListener, session)
    }

    func receive(offer: OpaquePointer, mimeType: String, fileDescriptor: Int32) {
        zwlr_data_control_offer_v1_receive(offer, mimeType, fileDescriptor)
    }

    func offer(source: OpaquePointer, mimeType: String) {
        zwlr_data_control_source_v1_offer(source, mimeType)
    }

    func setSelection(device: OpaquePointer, source: OpaquePointer?) {
        zwlr_data_control_device_v1_set_selection(device, source)
    }

    func destroyManager(_ manager: OpaquePointer) {
        zwlr_data_control_manager_v1_destroy(manager)
    }

    func destroyDevice(_ device: OpaquePointer) {
        zwlr_data_control_device_v1_destroy(device)
    }

    func destroyOffer(_ offer: OpaquePointer) {
        zwlr_data_control_offer_v1_destroy(offer)
    }

    func destroySource(_ source: OpaquePointer) {
        zwlr_data_control_source_v1_destroy(source)
    }
}
