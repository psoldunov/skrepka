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
            case .setSelection(let payload, let write):
                takeSelection(payload, as: write)
            }
        }
    }

    /// Puts a payload on the clipboard, or clears it.
    ///
    /// A fresh source every time: the protocol says a source that has been
    /// passed to `set_selection` may not be passed to another, and reusing one
    /// is a `used_source` protocol error that kills the connection.
    ///
    /// `write` is queued in ``pendingEchoes``, because the compositor's echo of
    /// this selection arrives on a later pass of the loop — possibly after
    /// another write — and is judged by the write it answers; see
    /// ``didReceiveSelection(_:)``. A clear, or a source that could not be
    /// made, will never be reported, and empties the queue instead.
    ///
    /// Destroying the source this write replaces clears the selection before
    /// the write is reported, so the write is queued as expecting that clear.
    func takeSelection(_ payload: [String: Data]?, as write: SelectionWrite) {
        guard let device, let manager else { return }
        let replacesOwnSource = ownedSource != nil
        releaseOwnedSource()

        guard let payload, !payload.isEmpty else {
            pendingEchoes.removeAll()
            binding.setSelection(device: device, source: nil)
            return
        }
        guard let source = binding.makeSource(manager: manager) else {
            pendingEchoes.removeAll()
            return
        }
        binding.attachSourceListener(source, session: opaqueSelf)
        // Sorted so the advertised order is the same on every run, which is
        // what makes `isOwnOffer(targets:)` and the tests deterministic.
        for target in payload.keys.sorted() {
            binding.offer(source: source, mimeType: target)
        }
        ownedSource = source
        ownedPayload = payload
        pendingEchoes.took(write, offering: payload.keys, afterClearing: replacesOwnSource)
        binding.setSelection(device: device, source: source)
    }

    /// Destroys the source Skrepka is serving from, if any.
    ///
    /// In-flight writes are deliberately not cancelled here: a requestor that
    /// asked before the handover is still waiting on its pipe, and dropping it
    /// would leave that application with a truncated paste.
    ///
    /// ``pendingEchoes`` is left alone: this runs at the start of every
    /// write, and the reports of earlier writes are still on their way.
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

        // Both selections' offers live in `offeredTargets`, so destroying its
        // keys covers the primary one too; the two handles are cleared so
        // neither is left pointing at a proxy this loop has just freed.
        for offer in offeredTargets.keys { binding.destroyOffer(offer) }
        offeredTargets.removeAll()
        currentOffer = nil
        currentPrimaryOffer = nil

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
