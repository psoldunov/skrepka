extension RemoteDesktopPaster {
    func inject(session: String, closeAfter: Bool, completion: @escaping Completion) {
        let finished: Completion = { [weak self] result in
            guard let self else { return }
            if closeAfter, case .success = result {
                scheduleClose(session)
            } else if case .failure = result {
                close(session)
            }
            completion(result)
        }
        if let injector {
            injector(session, finished)
            return
        }
        let events: [(Int32, UInt32)] = [(29, 1), (47, 1), (47, 0), (29, 0)]
        send(events: events[...], session: session, completion: finished)
    }

    private func send(
        events: ArraySlice<(Int32, UInt32)>,
        session: String,
        completion: @escaping Completion
    ) {
        guard let event = events.first, let connection = connection() else {
            completion(events.isEmpty ? .success(()) : .failure(PasteFailure("no portal connection")))
            return
        }
        connection.call(
            destination: GlobalShortcuts.portalName,
            path: GlobalShortcuts.portalPath,
            interface: Self.interface,
            method: "NotifyKeyboardKeycode",
            parameters: .tuple([
                .objectPath(session), .dictionary([:]), .int32(event.0), .uint32(event.1),
            ])
        ) { [weak self] result in
            switch result {
            case .success:
                self?.send(events: events.dropFirst(), session: session, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func request(
        method: String,
        values: [DBusValue],
        completion: @escaping PortalRequest.Completion
    ) {
        if let requester {
            requester(method, values, completion)
            return
        }
        guard let connection = connection() else {
            completion(.failure(DBusError(name: nil, message: "no desktop portal connection")))
            return
        }
        let requestToken =
            values.reversed().compactMap(\.dictionaryValue)
            .first?["handle_token"]?.stringValue ?? "request_\(requests.count)"
        let path = PortalRequestPath.make(uniqueName: connection.uniqueName, token: requestToken)
        let request = PortalRequest(
            connection: connection,
            token: requestToken,
            requestPath: path,
            interface: Self.interface,
            method: method,
            parameters: .tuple(values),
            completion: completion,
            remove: { [weak self] token in self?.requests[token] = nil }
        )
        requests[requestToken] = request
    }

    func subscribeToSessionClosed(_ session: String) {
        guard let connection = connection() else { return }
        sessionClosed = DBusSignalSubscription(
            connection: connection,
            sender: GlobalShortcuts.portalName,
            interface: "org.freedesktop.portal.Session",
            member: "Closed",
            path: session
        ) { [weak self] _, _ in self?.sessionDidClose(session) }
    }

    func sessionDidClose(_ closedSession: String) {
        guard session == closedSession else { return }
        session = nil
        sessionClosed?.cancel()
        sessionClosed = nil
        AppLog.note("paste: RemoteDesktop session closed by the desktop")
    }

    private func scheduleClose(_ session: String) {
        if let pendingCloseSession { close(pendingCloseSession) }
        pendingCloseSession = session
        closeTimer = LoopTimer(milliseconds: 50) { [weak self] in
            guard let self else { return }
            closeTimer = nil
            pendingCloseSession = nil
            close(session)
        }
    }

    func close(_ session: String) {
        if let closer {
            closer(session)
        } else {
            connection()?.call(
                destination: GlobalShortcuts.portalName,
                path: session,
                interface: "org.freedesktop.portal.Session",
                method: "Close"
            ) { _ in }
        }
        if pendingCloseSession == session {
            closeTimer?.cancel()
            closeTimer = nil
            pendingCloseSession = nil
        }
        guard self.session == session else { return }
        self.session = nil
        sessionClosed?.cancel()
        sessionClosed = nil
    }
}
