import CWaylandClient
import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// Owning the selection, acting on the actor's requests, and shutting down.
///
/// Split from the loop because that file crossed 300 lines, and this is the
/// half that has nothing to do with polling: everything here is either a
/// request arriving from the actor or the unwinding that follows one.
extension DataControlSession {
    func process(commands: [Command]) {
        for command in commands {
            switch command {
            case .stop:
                shouldStop = true
            case .setSelection(let payload):
                takeSelection(payload)
            }
        }
    }

    /// Puts a payload on the clipboard, or clears it.
    ///
    /// A fresh source every time: the protocol says a source that has been
    /// passed to `set_selection` may not be passed to another, and reusing one
    /// is a `used_source` protocol error that kills the connection.
    func takeSelection(_ payload: [String: Data]?) {
        guard let device, let manager else { return }
        releaseOwnedSource()

        guard let payload, !payload.isEmpty else {
            binding.setSelection(device: device, source: nil)
            return
        }
        guard let source = binding.makeSource(manager: manager) else { return }
        binding.attachSourceListener(source, session: opaqueSelf)
        // Sorted so the advertised order is the same on every run, which is
        // what makes `isOwnOffer(targets:)` and the tests deterministic.
        for target in payload.keys.sorted() {
            binding.offer(source: source, mimeType: target)
        }
        ownedSource = source
        ownedPayload = payload
        binding.setSelection(device: device, source: source)
    }

    /// Destroys the source Skrepka is serving from, if any.
    ///
    /// In-flight writes are deliberately not cancelled here: a requestor that
    /// asked before the handover is still waiting on its pipe, and dropping it
    /// would leave that application with a truncated paste.
    func releaseOwnedSource() {
        guard let source = ownedSource else { return }
        binding.destroySource(source)
        ownedSource = nil
        ownedPayload = [:]
    }

    func teardown() {
        abandonCapture()
        for transfer in outbound { transfer.cancel() }
        outbound.removeAll()
        closeQueuedWriteEnds()

        for offer in offeredTargets.keys { binding.destroyOffer(offer) }
        offeredTargets.removeAll()
        currentOffer = nil

        releaseOwnedSource()
        if let device { binding.destroyDevice(device) }
        device = nil
        if let manager { binding.destroyManager(manager) }
        manager = nil
        if let seat { wl_seat_destroy(seat) }
        seat = nil
        if let registry { wl_registry_destroy(registry) }
        registry = nil
        if let registryListener {
            registryListener.deinitialize(count: 1)
            registryListener.deallocate()
        }
        registryListener = nil
        if let display { wl_display_disconnect(display) }
        display = nil
        notify.finish()
    }
}
