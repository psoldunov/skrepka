import CWaylandClient
import CWaylandProtocols
import Foundation

#if canImport(Glibc)
    import Glibc
#endif

extension DataControlSession {
    /// Connects, runs until told to stop, and tears everything down.
    ///
    /// The whole life of the connection is this one call, on one thread. It
    /// returns only after every proxy is destroyed and the display is
    /// disconnected, so a caller that joins the thread knows the session is
    /// gone rather than merely asked to go.
    func run(commands: CommandQueue<Command>, wakeup: WakePipe) {
        // Writing into a pipe whose reader has gone raises SIGPIPE, whose
        // default disposition kills the process — and a clipboard requestor
        // closing early is ordinary, not exceptional. Ignoring it turns that
        // into the `EPIPE` that `OutboundTransfer` already handles.
        //
        // Process-global, which is a real cost and worth stating: a library
        // target is changing a signal disposition for whatever links it. It is
        // what every program that writes to pipes does, `swift-nio` included,
        // and the alternative — blocking SIGPIPE per thread — leaves the signal
        // pending and needs draining, which is worse.
        signal(SIGPIPE, SIG_IGN)

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

    /// Opens the display, binds the manager and a seat, and creates the device.
    private func connect() -> Bool {
        guard let display = wl_display_connect(displayName) else {
            failure = "No Wayland display could be opened."
            return false
        }
        self.display = display

        guard let registry = wl_display_get_registry(display) else {
            failure = "The Wayland display refused a registry."
            return false
        }
        self.registry = registry

        let listener = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
        listener.initialize(
            to: wl_registry_listener(
                global: { data, _, name, interface, version in
                    guard let interface else { return }
                    waylandSession(data)?
                        .bindGlobal(name: name, interface: String(cString: interface), version: version)
                },
                // A data-control manager or a seat withdrawn mid-session ends
                // the device, and the compositor says so with `finished` — which
                // is the event that stops the loop. Nothing useful to do here.
                global_remove: { _, _, _ in }
            )
        )
        registryListener = listener
        wl_registry_add_listener(registry, listener, opaqueSelf)
        wl_display_roundtrip(display)

        guard let manager else {
            failure = "This compositor does not offer \(binding.globalInterfaceName)."
            return false
        }
        guard let seat else {
            failure = "This compositor advertises no seat, so it has no selection to watch."
            return false
        }
        guard let device = binding.makeDevice(manager: manager, seat: seat) else {
            failure = "The compositor refused a data device."
            return false
        }
        self.device = device
        binding.attachDeviceListener(device, session: opaqueSelf)

        // Both protocols send a `selection` event on binding the device, so
        // this round trip is what puts the clipboard's current contents in
        // front of the loop rather than leaving them to the next copy.
        wl_display_roundtrip(display)
        return true
    }

    /// Binds a global the registry announced, if it is one of the two wanted.
    func bindGlobal(name: UInt32, interface: String, version: UInt32) {
        guard let registry else { return }
        if interface == binding.globalInterfaceName, manager == nil {
            manager = binding.bind(registry: registry, name: name, advertisedVersion: version)
        } else if interface == "wl_seat", seat == nil, let seatInterface = skrepka_wl_seat_interface() {
            // The first seat, and only the first. A multi-seat machine has one
            // clipboard per seat and Skrepka is a single-user desktop app; the
            // seat the session was started on is the one announced first.
            seat = wl_registry_bind(registry, name, seatInterface, min(version, 1)).map(OpaquePointer.init)
        }
    }

    /// The poll loop.
    ///
    /// Structured around libwayland's documented `prepare_read` sequence,
    /// quoted from `wl_display_prepare_read_queue`'s own documentation in
    /// libwayland 1.22:
    ///
    /// ```
    /// while (wl_display_prepare_read_queue(display, queue) != 0)
    ///         wl_display_dispatch_queue_pending(display, queue);
    /// wl_display_flush(display);
    /// ret = poll(fds, nfds, -1);
    /// if (has_error(ret)) wl_display_cancel_read(display);
    /// else                wl_display_read_events(display);
    /// wl_display_dispatch_queue_pending(display, queue);
    /// ```
    ///
    /// One adaptation, because that example polls the display fd alone: with
    /// other descriptors in the set, `poll` returning successfully does not
    /// mean the display is readable, so the read is cancelled whenever the
    /// display's own `revents` is clear. Calling `wl_display_read_events` there
    /// would block on a socket with nothing in it and stall every pipe
    /// transfer beside it.
    private func loop(commands: CommandQueue<Command>, wakeup: WakePipe) {
        while !shouldStop {
            process(commands: commands.drain())
            guard !shouldStop, let display else { break }

            while wl_display_prepare_read(display) != 0 {
                wl_display_dispatch_pending(display)
            }
            // Between the prepare and the poll is the only safe place to issue
            // the requests those callbacks asked for: the queue is empty, and
            // the flush below is what actually sends the file descriptors.
            startPendingCapture()
            if wl_display_flush(display) >= 0 { closeQueuedWriteEnds() }

            guard pollOnce(display: display, wakeup: wakeup) else { break }

            expireOverdueTransfers()
            finishCaptureIfComplete()
        }
    }

    /// One trip through `poll`, from the prepared read to the dispatched
    /// events. Returns false when the connection has failed and the loop
    /// should stop.
    ///
    /// Split out of ``loop(commands:wakeup:)`` to keep either function inside
    /// the repository's complexity budget; the seam is a real one, in that
    /// everything here is paired with the `wl_display_prepare_read` above it
    /// and must run exactly once per preparation.
    private func pollOnce(display: OpaquePointer, wakeup: WakePipe) -> Bool {
        var descriptors = pollDescriptors(display: display, wakeup: wakeup)
        let ready = poll(&descriptors, nfds_t(descriptors.count), pollTimeoutMilliseconds())
        // Taken here because it belongs to `poll` and to nothing else. Both
        // `wl_display_read_events` and `wl_display_cancel_read` run before the
        // check below, and either can set `errno` on its own path — so reading
        // it there can turn a benign `EINTR` into "the Wayland connection
        // failed" and end a session that was never in trouble.
        let pollErrno = errno
        // Snapshotted here, before anything can dispatch. `service` runs after
        // `wl_display_dispatch_pending`, and a callback firing in between can
        // both empty `inbound` — a newer selection abandons the capture in
        // flight — and grow `outbound`, because a `send` event is what asks
        // Skrepka to serve a paste.
        let readiness = Dictionary(
            descriptors.dropFirst(2).map { ($0.fd, $0.revents) },
            uniquingKeysWith: { first, _ in first }
        )

        if ready >= 0, descriptors[0].revents & Int16(POLLIN) != 0 {
            wl_display_read_events(display)
        } else {
            wl_display_cancel_read(display)
        }
        guard ready >= 0 || pollErrno == EINTR else {
            failure = "The Wayland connection failed: \(String(cString: strerror(pollErrno)))."
            return false
        }
        wl_display_dispatch_pending(display)

        guard wl_display_get_error(display) == 0 else {
            failure = "The compositor closed Skrepka's Wayland connection."
            return false
        }

        if descriptors[1].revents & Int16(POLLIN) != 0 { wakeup.drain() }
        service(readiness: readiness)
        return true
    }

    /// The descriptor set: the display, the wakeup pipe, then one entry per
    /// transfer.
    private func pollDescriptors(display: OpaquePointer, wakeup: WakePipe) -> [pollfd] {
        var descriptors = [
            pollfd(fd: wl_display_get_fd(display), events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeup.readEnd, events: Int16(POLLIN), revents: 0),
        ]
        // Finished inbound transfers are skipped, not merely uninteresting.
        // `InboundTransfer.finish` closes the descriptor, but the transfer
        // stays in `inbound` until every one of them is done, because
        // `finishCaptureIfComplete` reads the captured bytes back out of it.
        // Polling a closed descriptor is not just a wasted `POLLNVAL`: the
        // number is free for the kernel to hand to the next pipe, and an
        // outbound transfer given it would appear twice in this set — where
        // the readiness dictionary keeps the first entry, which is the stale
        // inbound one. `service` would then never see `POLLOUT` for a live
        // paste, and the requesting application would get whatever the
        // five-second deadline had truncated it to.
        descriptors += inbound.filter { !$0.isFinished }.map {
            pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        descriptors += outbound.map {
            pollfd(fd: $0.fileDescriptor, events: Int16(POLLOUT), revents: 0)
        }
        return descriptors
    }

    /// Blocks indefinitely when nothing is in flight, because every wakeup then
    /// arrives on a descriptor. A bounded wait only when a transfer could time
    /// out, since a deadline is the one thing no descriptor reports.
    private func pollTimeoutMilliseconds() -> Int32 {
        inbound.isEmpty && outbound.isEmpty ? -1 : 100
    }

    /// Advances every transfer `poll` said was ready.
    ///
    /// Keyed by descriptor rather than by position, because the transfer lists
    /// are not the ones the descriptor set was built from: dispatching the
    /// events read since then can abandon a capture or add an outbound
    /// transfer, and a positional read of the array walks off the end when it
    /// does. That is not hypothetical — it is what the headless-compositor test
    /// crashed on, on the pass where serving a paste added an outbound transfer
    /// between the poll and the service.
    ///
    /// A descriptor closed during dispatch and immediately reused by a new
    /// transfer would carry stale readiness for one pass. Harmless: every
    /// descriptor here is non-blocking, so the worst case is one `read` or
    /// `write` that returns `EAGAIN`.
    private func service(readiness: [Int32: Int16]) {
        // POLLHUP and POLLERR arrive whether or not they were asked for, and
        // both mean the same thing here: read what is left and take the EOF.
        let interesting = Int16(POLLIN | POLLOUT | POLLHUP | POLLERR)
        for transfer in inbound {
            guard let revents = readiness[transfer.fileDescriptor], revents & interesting != 0
            else { continue }
            transfer.readAvailable()
        }
        for transfer in outbound {
            guard let revents = readiness[transfer.fileDescriptor], revents & interesting != 0
            else { continue }
            transfer.writeAvailable()
        }
        outbound.removeAll { $0.isFinished }
    }

    private func expireOverdueTransfers() {
        let now = ContinuousClock.now
        for transfer in inbound { transfer.expireIfOverdue(now: now) }
        for transfer in outbound { transfer.expireIfOverdue(now: now) }
        outbound.removeAll { $0.isFinished }
    }
}

/// Recovers the session from a core-protocol listener's `data` pointer.
///
/// Separate from ``dataControlSession(from:)`` because the registry listener
/// needs the concrete type — binding a global is not one of the seven protocol
/// events, and hoisting it into `DataControlSessionEvents` would put a Wayland
/// detail into a protocol the X11 side has no use for.
private func waylandSession(_ data: UnsafeMutableRawPointer?) -> DataControlSession? {
    data.map { Unmanaged<DataControlSession>.fromOpaque($0).takeUnretainedValue() }
}
