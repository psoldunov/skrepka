import CXFixesShim
import Foundation
import SkrepkaCore

extension XClipboardSession {
    /// Starts reading whatever now owns `CLIPBOARD`.
    ///
    /// ICCCM asks the requestor to delete the property before converting, so
    /// the reply lands on a clean one and a stale body cannot be mistaken for
    /// a fresh reply.
    func beginRead(at time: Time) {
        guard let display, let atoms else { return }
        abandonRead()
        payloads = [:]
        advertisedNames = []
        remainingTargets = []
        readDeadline = ContinuousClock.now.advanced(by: LinuxClipboardLimits.transferTimeout)
        phase = .targets
        XDeleteProperty(display, window, atoms.transferProperty)
        XConvertSelection(
            display, atoms.clipboard, atoms.targets, atoms.transferProperty, window, time
        )
    }

    func abandonRead() {
        phase = .idle
        remainingTargets = []
        incrementalBytes = Data()
        readDeadline = nil
    }

    /// A reply to one of our own conversions.
    func handle(selectionNotify event: XSelectionEvent) {
        note(time: event.time)
        guard let display, let atoms, event.selection == atoms.clipboard else { return }

        // ICCCM §2.2: a property of `None` is the only refusal signal the
        // protocol has. There is no error code to read.
        guard event.property != 0 else {
            refusedConversion()
            return
        }

        switch phase {
        case .targets:
            guard
                let value = XProperty.read(
                    display: display, window: window, property: atoms.transferProperty, delete: true
                )
            else {
                finishRead()
                return
            }
            planTargets(from: value)
        case .data(let target):
            readOneTarget(target)
        case .idle, .incremental:
            // A reply to a conversion that has already been abandoned — a
            // newer selection arrived while this one was in flight. Dropped
            // rather than merged: its bytes belong to a clipboard that is gone.
            XDeleteProperty(display, window, atoms.transferProperty)
        }
    }

    /// Turns the owner's `TARGETS` reply into a fetch list.
    private func planTargets(from value: XProperty.Value) {
        guard let display else { return }
        let atomList = XProperty.atoms(in: value)
        var namesByAtom: [Atom: String] = [:]
        for atom in atomList where namesByAtom[atom] == nil {
            namesByAtom[atom] = XAtoms.name(of: atom, display: display)
        }
        advertisedNames = atomList.compactMap { namesByAtom[$0] }

        // Ranked richest-first by the identifier each maps to, so the order the
        // owner happened to list them in does not decide which representation
        // the entry is identified by.
        var ranked: [Atom] = []
        var seen: Set<Atom> = []
        for target in LinuxRepresentationMap.interestingTargets {
            for atom in atomList where namesByAtom[atom] == target {
                if seen.insert(atom).inserted { ranked.append(atom) }
            }
        }
        // The privacy hint is not a representation and is not in that list, but
        // it decides whether the others may be stored at all.
        let hintName = PrivacyMarkers.kdePasswordManagerHint
        for atom in atomList where namesByAtom[atom] == hintName {
            if seen.insert(atom).inserted { ranked.insert(atom, at: 0) }
        }

        remainingTargets = ranked
        fetchNextTarget()
    }

    /// Converts the next target, or finishes when there are none left.
    func fetchNextTarget() {
        guard let display, let atoms else { return }
        guard let target = remainingTargets.first else {
            finishRead()
            return
        }
        remainingTargets.removeFirst()
        incrementalBytes = Data()
        phase = .data(target)
        XDeleteProperty(display, window, atoms.transferProperty)
        XConvertSelection(
            display, atoms.clipboard, target, atoms.transferProperty, window, lastServerTime
        )
    }

    /// Reads the reply for one target, or starts draining it incrementally.
    private func readOneTarget(_ target: Atom) {
        guard let display, let atoms else { return }
        guard
            let value = XProperty.read(
                display: display, window: window, property: atoms.transferProperty, delete: true
            )
        else {
            fetchNextTarget()
            return
        }

        guard value.type != atoms.incr else {
            // ICCCM §2.7.2: deleting the INCR property is what starts the
            // transfer. `PropertyChangeMask` is already selected on our window
            // — set at connect rather than here, because the owner may begin
            // appending the moment the delete lands and selecting late races
            // it.
            phase = .incremental(target)
            incrementalBytes = Data()
            XDeleteProperty(display, window, atoms.transferProperty)
            return
        }

        store(bytes: value.bytes, for: target)
        fetchNextTarget()
    }

    /// One chunk of an `INCR` transfer, or its zero-length terminator.
    func handle(propertyNotify event: XPropertyEvent) {
        note(time: event.time)
        guard let display, let atoms else { return }
        guard case .incremental(let target) = phase,
            event.window == window,
            event.atom == atoms.transferProperty,
            event.state == PropertyNewValue
        else { return }

        guard
            let value = XProperty.read(
                display: display, window: window, property: atoms.transferProperty, delete: true
            )
        else {
            fetchNextTarget()
            return
        }

        // ICCCM: "waits until the property named by the PropertyNotify event is
        // zero-length" — that, not a count, is how the owner says it is done.
        guard !value.bytes.isEmpty else {
            store(bytes: incrementalBytes, for: target)
            incrementalBytes = Data()
            fetchNextTarget()
            return
        }

        incrementalBytes.append(value.bytes)
        guard incrementalBytes.count <= LinuxClipboardLimits.maximumRepresentationBytes else {
            // Over the ceiling. The partial bytes go rather than being stored
            // truncated — half an image is not a smaller image — and the rest
            // of the targets are still worth fetching.
            incrementalBytes = Data()
            fetchNextTarget()
            return
        }
    }

    private func store(bytes: Data, for target: Atom) {
        guard let display, !bytes.isEmpty,
            bytes.count <= LinuxClipboardLimits.maximumRepresentationBytes,
            let name = XAtoms.name(of: target, display: display)
        else { return }
        payloads[name] = bytes
    }

    /// The owner refused a conversion outright.
    ///
    /// For `TARGETS` that ends the read — an owner that will not say what it
    /// has cannot be asked for any of it. For one target it is ordinary: the
    /// owner advertised something it turned out not to be able to produce, and
    /// the next target may still work.
    private func refusedConversion() {
        switch phase {
        case .targets, .idle:
            finishRead()
        case .data, .incremental:
            fetchNextTarget()
        }
    }

    /// Publishes whatever the read gathered.
    func finishRead() {
        guard phase != .idle else { return }
        abandonRead()

        let concealed = LinuxRepresentationMap.isConcealed(
            hint: payloads[PrivacyMarkers.kdePasswordManagerHint]
        )

        publish(
            .contents(
                LinuxSnapshotBuilder.snapshot(
                    offeredTargets: advertisedNames,
                    payloads: payloads,
                    concealedHintSecret: concealed
                )
            )
        )
        payloads = [:]
        advertisedNames = []
    }

    /// Gives up on a read that has run out of time and publishes what arrived.
    ///
    /// An owner that stops replying mid-transfer would otherwise hold the read
    /// state machine open forever, and with it every later clipboard change.
    func expireOverdueRead(now: ContinuousClock.Instant = .now) {
        guard let deadline = readDeadline, now >= deadline else { return }
        finishRead()
    }
}
