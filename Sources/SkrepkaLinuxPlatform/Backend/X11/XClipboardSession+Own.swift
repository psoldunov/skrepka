import CX11
import Foundation

extension XClipboardSession {
    /// Takes ownership of `CLIPBOARD`, or gives it up.
    ///
    /// ICCCM §2.1 makes the read-back mandatory: the request must succeed, "not
    /// merely appear to succeed". A `SetSelectionOwner` against a timestamp the
    /// server considers stale is ignored silently, and an owner that did not
    /// check would serve a clipboard nobody was asking it about.
    func takeSelection(_ payload: [String: Data]?) {
        guard let display, let atoms else { return }

        guard let payload, !payload.isEmpty else {
            XSetSelectionOwner(display, atoms.clipboard, X11.none, lastServerTime)
            ownedPayload = [:]
            ownedByAtom = [:]
            ownedSince = 0
            return
        }

        ownedPayload = payload
        ownedByAtom = [:]
        for (name, bytes) in payload {
            ownedByAtom[XInternAtom(display, name, 0)] = bytes
        }

        let time = lastServerTime
        XSetSelectionOwner(display, atoms.clipboard, window, time)
        guard XGetSelectionOwner(display, atoms.clipboard) == window else {
            ownedPayload = [:]
            ownedByAtom = [:]
            ownedSince = 0
            return
        }
        ownedSince = time
    }

    /// Another client took `CLIPBOARD`.
    ///
    /// In-flight `INCR` sends are deliberately left running. ICCCM §2.3: "if an
    /// owner loses ownership while it has a transfer in progress ... it must
    /// continue to service the ongoing transfer until it is complete." Dropping
    /// them would leave the other application with a truncated paste.
    func handleSelectionClear() {
        ownedPayload = [:]
        ownedByAtom = [:]
        ownedSince = 0
    }

    /// Serves one request against the selection Skrepka owns.
    func handle(selectionRequest event: XSelectionRequestEvent) {
        note(time: event.time)
        guard let atoms, event.selection == atoms.clipboard else { return }

        // ICCCM §2.2: "the owner should compare the timestamp with the period
        // it has owned the selection and, if the time is outside, refuse".
        // `CurrentTime` is always in range by definition.
        guard ownedSince != 0, event.time == CurrentTime || event.time >= ownedSince else {
            reply(to: event, property: X11.none)
            return
        }

        // ICCCM §2.2: "if the specified property is None, the requestor is an
        // obsolete client. Owners are encouraged to support these clients by
        // using the specified target atom as the property name."
        let property = event.property == X11.none ? event.target : event.property

        if event.target == atoms.multiple {
            // A `MULTIPLE` with no property is refused outright, per ICCCM —
            // there is nowhere to read the pairs from.
            guard event.property != X11.none else {
                reply(to: event, property: X11.none)
                return
            }
            handleMultiple(event, property: property)
            return
        }

        let served = serve(target: event.target, property: property, requestor: event.requestor)
        reply(to: event, property: served ? property : X11.none)
    }

    /// Converts one target onto the requestor's window.
    ///
    /// Returns false when the target cannot be produced, which the caller turns
    /// into the `property = None` refusal — the only one the protocol has.
    private func serve(target: Atom, property: Atom, requestor: Window) -> Bool {
        guard let display, let atoms else { return false }

        if target == atoms.targets {
            // ICCCM §2.6.2 requires TARGETS, MULTIPLE and TIMESTAMP of every
            // owner; everything else is optional. Type `ATOM`, format 32.
            let advertised =
                [atoms.targets, atoms.multiple, atoms.timestamp]
                + ownedByAtom.keys.sorted()
            XProperty.write(
                atoms: advertised,
                display: display,
                window: requestor,
                property: property,
                type: XA_ATOM
            )
            return true
        }

        if target == atoms.timestamp {
            // "Selection owners must support conversion to TIMESTAMP, returning
            // the timestamp they used to obtain the selection." Type INTEGER,
            // format 32, one element.
            XProperty.write(
                atoms: [Atom(ownedSince)],
                display: display,
                window: requestor,
                property: property,
                type: XA_INTEGER
            )
            return true
        }

        guard let bytes = ownedByAtom[target] else { return false }

        let chunk = XProperty.maximumChunkBytes(display: display)
        guard bytes.count > chunk else {
            XProperty.write(
                bytes: bytes,
                display: display,
                window: requestor,
                property: property,
                type: target
            )
            return true
        }

        beginIncrementalSend(bytes: bytes, to: requestor, property: property, type: target)
        return true
    }

    /// Starts an `INCR` reply. ICCCM §2.7.2, owner side.
    private func beginIncrementalSend(bytes: Data, to requestor: Window, property: Atom, type: Atom) {
        guard let display, let atoms else { return }

        // Selected before the initial reply, because the requestor may delete
        // the INCR property the instant it sees it and the deletion is what
        // paces the whole transfer. Event masks are per-client, so this does
        // not disturb the requestor's own.
        XSelectInput(display, requestor, PropertyChangeMask)

        // Type INCR, format 32, one element: a lower bound on the byte count.
        // `xclip` writes zero elements here, which is out of spec and tolerated
        // because the value is only a hint; writing the real number costs
        // nothing and is what the specification asks for.
        XProperty.write(
            atoms: [Atom(bytes.count)],
            display: display,
            window: requestor,
            property: property,
            type: atoms.incr
        )
        incomingTransfers.append(
            XIncrementalSend(
                requestor: requestor,
                property: property,
                type: type,
                bytes: bytes,
                chunkBytes: XProperty.maximumChunkBytes(display: display)
            )
        )
    }

    /// The requestor deleted a property, so the next chunk may go.
    func advanceIncrementalSend(for event: XPropertyEvent) {
        guard let display, event.state == PropertyDelete else { return }
        for transfer in incomingTransfers
        where transfer.requestor == event.window && transfer.property == event.atom {
            transfer.sendNextChunk(display: display)
        }
        incomingTransfers.removeAll(where: \.isFinished)
    }

    func expireOverdueSends(now: ContinuousClock.Instant = .now) {
        guard let display else { return }
        for transfer in incomingTransfers { transfer.expireIfOverdue(display: display, now: now) }
        incomingTransfers.removeAll(where: \.isFinished)
    }

    func cancelIncrementalSends() {
        guard let display else { return }
        for transfer in incomingTransfers { transfer.finish(display: display) }
        incomingTransfers.removeAll()
    }

    /// `MULTIPLE`: a list of (target, property) atom pairs on the requestor's
    /// window, each converted in turn.
    ///
    /// ICCCM: "if the owner fails to convert the target named by an atom in the
    /// MULTIPLE property, it should replace that atom in the property with
    /// None", and "the owner should reply with a SelectionNotify only when all
    /// the requested conversions have been performed". Processed in order,
    /// because §2.6.3 makes the order meaningful for side-effect targets.
    private func handleMultiple(_ event: XSelectionRequestEvent, property: Atom) {
        guard let display,
            let value = XProperty.read(
                display: display, window: event.requestor, property: property, delete: false
            )
        else {
            reply(to: event, property: X11.none)
            return
        }

        var pairs = XProperty.atoms(in: value)
        guard pairs.count >= 2 else {
            reply(to: event, property: X11.none)
            return
        }
        for index in stride(from: 0, to: pairs.count - 1, by: 2) {
            let target = pairs[index]
            let destination = pairs[index + 1]
            guard destination != X11.none,
                serve(target: target, property: destination, requestor: event.requestor)
            else {
                pairs[index + 1] = X11.none
                continue
            }
        }

        guard let atoms else { return }
        XProperty.write(
            atoms: pairs,
            display: display,
            window: event.requestor,
            property: property,
            type: atoms.atomPair
        )
        reply(to: event, property: property)
    }

    /// The `SelectionNotify` an owner owes every request.
    ///
    /// Sent with an empty event mask and `propagate` false, as ICCCM §2.2
    /// specifies. The receiver sees `send_event` set to true, which is expected
    /// and must not be filtered out at the other end.
    private func reply(to event: XSelectionRequestEvent, property: Atom) {
        guard let display else { return }
        var notification = XEvent()
        notification.type = SelectionNotify
        notification.xselection.serial = 0
        notification.xselection.send_event = 1
        notification.xselection.display = display
        notification.xselection.requestor = event.requestor
        notification.xselection.selection = event.selection
        notification.xselection.target = event.target
        notification.xselection.property = property
        notification.xselection.time = event.time
        XSendEvent(display, event.requestor, 0, 0, &notification)
    }
}
