import CXFixesShim
import Foundation
import SkrepkaCore

#if canImport(Glibc)
    import Glibc
#endif

extension XClipboardSession {
    /// Connects, runs until told to stop, and tears everything down.
    func run(commands: CommandQueue<Command>, wakeup: WakePipe) {
        // Xlib's default error handler calls `exit()`. A requestor window
        // disappearing mid-transfer is ordinary rather than exceptional, and
        // the default handler turns that into the death of the whole daemon.
        //
        // Process-global, like the SIGPIPE disposition the Wayland loop sets,
        // and for the same reason: Xlib offers no per-connection alternative.
        //
        // Returning without recording anything is not swallowing the error: an
        // X protocol error has no per-request return value, this handler *is*
        // the error channel, and every failure it can report — a dead requestor,
        // a refused property — is already a state the read and write machines
        // handle by giving up on that one transfer. What is deliberately not
        // done is ICCCM §2.5's `BadAlloc` confirmation after each
        // `XChangeProperty`, which would need a mutable global to carry the
        // flag back; `xclip` documents skipping it for the same reason.
        XSetErrorHandler { _, _ in 0 }

        guard connect() else {
            state.update {
                $0.isRunning = false
                $0.failure = failure
            }
            teardown()
            return
        }
        state.update {
            $0.isRunning = true
            $0.failure = nil
        }

        loop(commands: commands, wakeup: wakeup)

        teardown()
        state.update {
            $0.isRunning = false
            $0.failure = failure
        }
    }

    private func connect() -> Bool {
        guard let display = XOpenDisplay(displayName) else {
            failure = "No X11 display could be opened."
            return false
        }
        self.display = display

        var eventBase: Int32 = 0
        var errorBase: Int32 = 0
        guard XFixesQueryExtension(display, &eventBase, &errorBase) != 0 else {
            failure = "This X server has no XFIXES extension, so selection changes cannot be seen."
            return false
        }
        xfixesEventBase = eventBase

        let atoms = XAtoms(display: display)
        self.atoms = atoms

        // An unmapped 1×1 window on the root. It is never drawn; it exists to
        // own the selection, to carry the properties replies land on, and to be
        // the window XFIXES reports changes to.
        window = XCreateSimpleWindow(display, XDefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0)
        guard window != 0 else {
            failure = "The X server refused Skrepka a window."
            return false
        }
        // Selected once, here, rather than when an INCR transfer starts: the
        // owner may begin appending the moment we delete the INCR property, and
        // selecting after that races the first chunk.
        XSelectInput(display, window, PropertyChangeMask)

        seedServerTime()

        // All three subtypes. `SetSelectionOwnerNotify` is the copy; the other
        // two are the owner going away, which leaves the clipboard unowned and
        // is worth knowing about.
        let subtypes = UInt(
            XFixesSetSelectionOwnerNotifyMask
                | XFixesSelectionWindowDestroyNotifyMask
                | XFixesSelectionClientCloseNotifyMask
        )
        XFixesSelectSelectionInput(display, window, atoms.clipboard, subtypes)
        XFlush(display)

        // XFIXES only reports changes from here on, so whatever is already on
        // the clipboard has to be asked for explicitly — otherwise the first
        // copy after launch would be the first thing Skrepka ever saw.
        if XGetSelectionOwner(display, atoms.clipboard) != X11.none {
            beginRead(at: lastServerTime)
        } else {
            publish(.contents(PasteboardSnapshot(representations: [:], declaredTypes: [])))
        }
        return true
    }

    /// Reads a valid server timestamp off a `PropertyNotify` we provoke.
    ///
    /// ICCCM forbids `CurrentTime` in `ConvertSelection` and wants a real one
    /// for `SetSelectionOwner`. A zero-length append to a property of our own
    /// window generates a `PropertyNotify` carrying the server's clock, which
    /// is the standard way to obtain one without waiting for the user to do
    /// something. Safe to block on here and nowhere else: it runs at connect,
    /// before any transfer exists whose `PropertyNotify` this could swallow.
    private func seedServerTime() {
        guard let display, let atoms else { return }
        XChangeProperty(display, window, atoms.timeProperty, XA_STRING, 8, PropModeAppend, nil, 0)
        var event = XEvent()
        XWindowEvent(display, window, PropertyChangeMask, &event)
        note(time: event.xproperty.time)
        XDeleteProperty(display, window, atoms.timeProperty)
    }

    /// The event loop.
    ///
    /// Never blocks in `XNextEvent`, because Xlib publishes no way to interrupt
    /// one — the manual documents no wakeup call, and a thread parked there
    /// could not be told to stop. Instead the queue is drained with
    /// `XEventsQueued(QueuedAlready)`, which the manual guarantees "never
    /// performs a system call", and only then does the thread block in `poll`
    /// on the connection and the wakeup pipe.
    ///
    /// Draining first is load-bearing rather than tidy: Xlib reads whole
    /// buffers off the socket, so events routinely sit in the client-side queue
    /// while the descriptor reports nothing to read. A loop that polled first
    /// would sleep with a full queue.
    private func loop(commands: CommandQueue<Command>, wakeup: WakePipe) {
        guard let display else { return }
        // `ConnectionNumber` is a function-like macro, which Swift does not
        // import. `XConnectionNumber` is the function form of the same thing,
        // and the Xlib manual defines it as the file descriptor of the
        // connection on a POSIX-conformant system.
        let connection = XConnectionNumber(display)

        while !shouldStop {
            process(commands: commands.drain())
            guard !shouldStop else { break }

            XFlush(display)
            while XEventsQueued(display, QueuedAlready) > 0 {
                var event = XEvent()
                XNextEvent(display, &event)
                dispatch(event)
            }
            // Draining may have produced requests of its own — a conversion,
            // a reply, an INCR chunk — and none of them reaches the server
            // until the connection is flushed.
            XFlush(display)
            guard !shouldStop else { break }

            var descriptors = [
                pollfd(fd: connection, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeup.readEnd, events: Int16(POLLIN), revents: 0),
            ]
            let timeout: Int32 =
                (phase == .idle && incomingTransfers.isEmpty) ? -1 : 100
            let ready = poll(&descriptors, nfds_t(descriptors.count), timeout)
            if ready < 0 && errno != EINTR {
                failure = "The X11 connection failed: \(String(cString: strerror(errno)))."
                break
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 { wakeup.drain() }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                // Moves whatever arrived from the socket into the client-side
                // queue; the drain at the top of the next pass dispatches it.
                _ = XEventsQueued(display, QueuedAfterReading)
            }

            expireOverdueRead()
            expireOverdueSends()
        }
    }

    private func dispatch(_ event: XEvent) {
        guard let atoms else { return }

        // XFIXES was assigned one base event number and defines two events, so
        // a selection change arrives as exactly the base.
        if event.type == xfixesEventBase {
            handleSelectionOwnerChange(event)
            return
        }

        switch event.type {
        case SelectionNotify:
            handle(selectionNotify: event.xselection)
        case SelectionRequest:
            handle(selectionRequest: event.xselectionrequest)
        case SelectionClear:
            note(time: event.xselectionclear.time)
            handleSelectionClear()
        case PropertyNotify:
            if event.xproperty.window == window, event.xproperty.atom == atoms.transferProperty {
                handle(propertyNotify: event.xproperty)
            } else {
                advanceIncrementalSend(for: event.xproperty)
            }
            note(time: event.xproperty.time)
        default:
            break
        }
    }

    /// A selection change, from XFIXES.
    private func handleSelectionOwnerChange(_ event: XEvent) {
        let notification = withUnsafePointer(to: event) {
            $0.withMemoryRebound(to: XFixesSelectionNotifyEvent.self, capacity: 1) { $0.pointee }
        }
        guard let atoms, notification.selection == atoms.clipboard else { return }
        note(time: notification.timestamp)

        // Skrepka's own writes come back as these too, and recording them would
        // put every paste-back into history as a fresh copy. The freedesktop
        // clipboard-manager convention makes this unavoidable rather than
        // incidental: an owner is asked to reacquire the selection whenever its
        // content changes, precisely so XFIXES watchers notice — and Skrepka is
        // both the owner doing that and a watcher noticing.
        guard notification.owner != window else {
            publish(
                .contents(
                    LinuxSnapshotBuilder.snapshot(
                        offeredTargets: Array(ownedPayload.keys),
                        payloads: ownedPayload,
                        concealedHintSecret: false
                    )
                )
            )
            return
        }

        guard notification.owner != X11.none else {
            abandonRead()
            publish(.contents(PasteboardSnapshot(representations: [:], declaredTypes: [])))
            return
        }
        beginRead(at: notification.timestamp)
    }

    private func process(commands: [Command]) {
        for command in commands {
            switch command {
            case .stop: shouldStop = true
            case .setSelection(let payload): takeSelection(payload)
            }
        }
    }

    private func teardown() {
        abandonRead()
        cancelIncrementalSends()
        guard let display else { return }
        if let atoms, ownedSince != 0 {
            XSetSelectionOwner(display, atoms.clipboard, X11.none, lastServerTime)
        }
        if window != 0 { XDestroyWindow(display, window) }
        window = 0
        XCloseDisplay(display)
        self.display = nil
        notify.finish()
    }
}
