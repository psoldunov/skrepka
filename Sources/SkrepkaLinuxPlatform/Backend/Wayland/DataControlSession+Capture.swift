import CWaylandClient
import Foundation
import SkrepkaCore

#if canImport(Glibc)
    import Glibc
#endif

extension DataControlSession {
    /// Records that a capture should start, without starting it.
    ///
    /// Deliberately no I/O: this runs inside a libwayland dispatch callback,
    /// and the `receive` requests it implies carry file descriptors that
    /// libwayland does **not** duplicate — verified against `connection.c` in
    /// libwayland 1.22, where `copy_fds_to_connection` puts the raw descriptor
    /// number into a ring buffer that is not drained until the connection is
    /// flushed. So the write ends have to outlive a flush, and the only place
    /// that can sequence a request, a flush and a close is the loop.
    func beginCapture(from offer: OpaquePointer, targets: [String]) {
        pendingCapture = PendingCapture(offer: offer, targets: targets)
    }

    /// Drops an in-flight capture and everything it was reading.
    ///
    /// Called when a newer selection arrives: the protocol says the previous
    /// selection is ignored regardless of what the client was doing with it, so
    /// finishing the read would publish bytes the clipboard no longer holds
    /// under a change count that claims they are current.
    func abandonCapture() {
        for transfer in inbound { transfer.cancel() }
        inbound.removeAll()
        captureTargets = []
        isCapturing = false
        pendingCapture = nil
    }

    /// Issues the `receive` requests a pending capture asked for.
    ///
    /// Runs on the loop, between draining the event queue and flushing, so the
    /// descriptors it hands over are still open when libwayland sends them.
    func startPendingCapture() {
        guard let pending = pendingCapture else { return }
        pendingCapture = nil

        // Ranked rather than in the order the owner advertised, so the pipes
        // are opened richest-first and a clipboard offering more targets than
        // Skrepka reads costs nothing for the ones it does not want.
        var wanted = LinuxRepresentationMap.interestingTargets.filter(pending.targets.contains)
        // The privacy hint is not a representation and is not in that list, but
        // it decides whether any of the others may be stored — so it is asked
        // for whenever it is offered.
        if pending.targets.contains(PrivacyMarkers.kdePasswordManagerHint) {
            wanted.insert(PrivacyMarkers.kdePasswordManagerHint, at: 0)
        }

        guard !wanted.isEmpty else {
            // Nothing Skrepka can read. Published as an empty snapshot carrying
            // the targets that were on offer, which is what lets
            // `CaptureRules.emptyReason(declaredTypes:)` call it empty rather
            // than unreadable.
            publish(
                .contents(
                    LinuxSnapshotBuilder.snapshot(
                        offeredTargets: pending.targets,
                        payloads: [:],
                        concealedHintSecret: false
                    )
                )
            )
            return
        }

        captureTargets = pending.targets
        isCapturing = true
        for target in wanted {
            guard let readEnd = openTransferPipe(offer: pending.offer, target: target) else {
                continue
            }
            inbound.append(InboundTransfer(target: target, fileDescriptor: readEnd))
        }
        // Every pipe failed to open — a file-descriptor exhaustion, not an
        // empty clipboard. Reported as unreadable so it does not read as a user
        // with nothing on their clipboard.
        if inbound.isEmpty {
            isCapturing = false
            publish(.unreadable)
        }
    }

    /// One pipe, with the write end handed to the compositor.
    ///
    /// Returns the read end, already non-blocking, or nil when the pipe could
    /// not be set up — in which case both ends are closed rather than leaked.
    private func openTransferPipe(offer: OpaquePointer, target: String) -> Int32? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        // Neither end should survive into a child process. Skrepka spawns none
        // today; the Phase 6 daemon may, and a leaked clipboard pipe there is a
        // transfer that never reaches EOF.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        guard makeNonBlocking(ends[0]) else {
            close(ends[0])
            close(ends[1])
            return nil
        }
        binding.receive(offer: offer, mimeType: target, fileDescriptor: ends[1])
        // Closed only after the loop's next successful flush — see the note on
        // `beginCapture(from:targets:)`. Held here until then.
        queuedWriteEnds.append(ends[1])
        return ends[0]
    }

    /// Releases the write ends now that libwayland has actually sent them.
    ///
    /// Until this runs, Skrepka is itself a writer on each of those pipes, so
    /// the owner closing its end does not produce EOF and every transfer would
    /// sit until it timed out.
    func closeQueuedWriteEnds() {
        for end in queuedWriteEnds { close(end) }
        queuedWriteEnds.removeAll()
    }

    /// Publishes the capture once every transfer has settled.
    func finishCaptureIfComplete() {
        guard isCapturing, inbound.allSatisfy(\.isFinished) else { return }
        isCapturing = false

        var payloads: [String: Data] = [:]
        for transfer in inbound where transfer.outcome == .complete {
            payloads[transfer.target] = transfer.bytes
        }
        let concealed = LinuxRepresentationMap.isConcealed(
            hint: payloads[PrivacyMarkers.kdePasswordManagerHint]
        )
        inbound.removeAll()

        // A read that produced nothing at all, from a clipboard that advertised
        // something Skrepka reads, is the Linux shape of `.unreadable`: the
        // pipes were opened and closed with no bytes, or every one of them
        // timed out. `CaptureRules` turns that into the decision that says so
        // rather than into an empty clipboard.
        publish(
            .contents(
                LinuxSnapshotBuilder.snapshot(
                    offeredTargets: captureTargets,
                    payloads: payloads,
                    concealedHintSecret: concealed
                )
            )
        )
        captureTargets = []
    }

}

/// A selection whose contents have been asked for but not yet read.
struct PendingCapture {
    let offer: OpaquePointer
    let targets: [String]
}
