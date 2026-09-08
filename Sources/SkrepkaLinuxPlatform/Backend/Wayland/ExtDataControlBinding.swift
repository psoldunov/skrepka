import CWaylandClient
import CWaylandProtocols
import Foundation

/// `ext-data-control-v1`, the current protocol.
///
/// Staging rather than stable in `wayland-protocols` — verified 2026-09-07
/// against the repository's `main`, where it still sits under `staging/` and
/// every interface is at version 1. First shipped in `wayland-protocols` 1.39,
/// which is why the XML is vendored rather than read from the distribution: the
/// oldest LTS this could plausibly build on does not carry it.
///
/// Every member here is a one-line forward to a generated `static inline`
/// wrapper. The file is mechanical on purpose: it is the *only* place the
/// spelling of this protocol appears, and ``WlrDataControlBinding`` is the same
/// file with the other prefix.
final class ExtDataControlBinding: DataControlProtocolBinding {
    let globalInterfaceName = SessionProbe.extGlobal
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
    private typealias DeviceListener = UnsafeMutablePointer<ext_data_control_device_v1_listener>
    private typealias OfferListener = UnsafeMutablePointer<ext_data_control_offer_v1_listener>
    private typealias SourceListener = UnsafeMutablePointer<ext_data_control_source_v1_listener>

    private let deviceListener: DeviceListener
    private let offerListener: OfferListener
    private let sourceListener: SourceListener

    init() {
        // Not `withUnsafePointer(to:)` on the imported global: that yields the
        // real symbol address in practice but promises a copy, and libwayland
        // stores this pointer inside every proxy bound with it. See the comment
        // on the accessor in Sources/CWaylandProtocols/include/.
        guard let interface = skrepka_ext_data_control_manager_interface() else {
            // The symbol is linked into this binary; it cannot be absent. The
            // accessor is only nullable because Swift imports every C pointer
            // return that way.
            preconditionFailure("ext_data_control_manager_v1_interface is not linked")
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
            to: ext_data_control_device_v1_listener(
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
                // asked to keep. The session still has to destroy the offer —
                // this event carries no `since`, so every ext compositor sends
                // it, and `data_offer` has already introduced a proxy by now.
                primary_selection: { data, _, offer in
                    dataControlSession(from: data)?.didReceivePrimarySelection(offer)
                }
            )
        )
        return listener
    }

    private static func makeOfferListener() -> OfferListener {
        let listener = OfferListener.allocate(capacity: 1)
        listener.initialize(
            to: ext_data_control_offer_v1_listener(
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
            to: ext_data_control_source_v1_listener(
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
        ext_data_control_manager_v1_get_data_device(manager, seat)
    }

    func makeSource(manager: OpaquePointer) -> OpaquePointer? {
        ext_data_control_manager_v1_create_data_source(manager)
    }

    func attachDeviceListener(_ device: OpaquePointer, session: UnsafeMutableRawPointer) {
        ext_data_control_device_v1_add_listener(device, deviceListener, session)
    }

    func attachOfferListener(_ offer: OpaquePointer, session: UnsafeMutableRawPointer) {
        ext_data_control_offer_v1_add_listener(offer, offerListener, session)
    }

    func attachSourceListener(_ source: OpaquePointer, session: UnsafeMutableRawPointer) {
        ext_data_control_source_v1_add_listener(source, sourceListener, session)
    }

    func receive(offer: OpaquePointer, mimeType: String, fileDescriptor: Int32) {
        ext_data_control_offer_v1_receive(offer, mimeType, fileDescriptor)
    }

    func offer(source: OpaquePointer, mimeType: String) {
        ext_data_control_source_v1_offer(source, mimeType)
    }

    func setSelection(device: OpaquePointer, source: OpaquePointer?) {
        ext_data_control_device_v1_set_selection(device, source)
    }

    func destroyManager(_ manager: OpaquePointer) {
        ext_data_control_manager_v1_destroy(manager)
    }

    func destroyDevice(_ device: OpaquePointer) {
        ext_data_control_device_v1_destroy(device)
    }

    func destroyOffer(_ offer: OpaquePointer) {
        ext_data_control_offer_v1_destroy(offer)
    }

    func destroySource(_ source: OpaquePointer) {
        ext_data_control_source_v1_destroy(source)
    }
}
