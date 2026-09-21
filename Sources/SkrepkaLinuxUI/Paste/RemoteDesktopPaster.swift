import Foundation

final class RemoteDesktopPaster {
    typealias Completion = (Result<Void, any Error>) -> Void
    typealias Requester = (String, [DBusValue], @escaping PortalRequest.Completion) -> Void
    typealias Injector = (String, @escaping Completion) -> Void
    typealias Closer = (String) -> Void

    static let interface = "org.freedesktop.portal.RemoteDesktop"
    /// Lets focus return to the target after GNOME dismisses its consent dialog.
    static let firstGrantInjectionDelay: UInt32 = 500
    let connection: () -> DBusConnection?
    let tokenStore: RestoreTokenStore
    let requester: Requester?
    let injector: Injector?
    let closer: Closer?
    var requests: [String: PortalRequest] = [:]
    var session: String?
    var sessionClosed: DBusSignalSubscription?
    var closeTimer: LoopTimer?
    var pendingCloseSession: String?
    var pendingInjectionTimer: LoopTimer?
    var pendingInjectionSession: String?

    private var pending: Completion?
    private var isStarting = false
    private var refusedThisRun = false
    private var isAutomaticPasteEnabled = true

    init(
        connection: @escaping () -> DBusConnection?,
        tokenStore: RestoreTokenStore = RestoreTokenStore(),
        requester: Requester? = nil,
        injector: Injector? = nil,
        closer: Closer? = nil
    ) {
        self.connection = connection
        self.tokenStore = tokenStore
        self.requester = requester
        self.injector = injector
        self.closer = closer
    }

    func paste(completion: @escaping Completion) {
        guard !refusedThisRun else {
            completion(.failure(PasteFailure.consentRefused))
            return
        }
        if let session {
            cancelPendingPaste()
            inject(session: session, closeAfter: false, completion: completion)
            return
        }
        cancelPendingPaste()
        pending = completion
        guard !isStarting else { return }
        isStarting = true
        createSession()
    }

    /// Turning the setting off and on is the explicit way to ask the desktop
    /// again after its consent prompt was refused.
    func setAutomaticPasteEnabled(_ enabled: Bool) {
        if enabled, !isAutomaticPasteEnabled { refusedThisRun = false }
        isAutomaticPasteEnabled = enabled
        guard !enabled else { return }
        cancelPendingPaste()
    }

    private func createSession() {
        let sessionToken = token("session")
        request(
            method: "CreateSession",
            values: [
                RemoteDesktopPortalPayload.createOptions(
                    request: token("request"), session: sessionToken)
            ]
        ) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result,
                let session = RemoteDesktopPortalPayload.sessionHandle(from: response)
            else { return self.fail("CreateSession", result) }
            self.selectDevices(session: session)
        }
    }

    private func selectDevices(session: String) {
        let restoreToken = tokenStore.load()
        request(
            method: "SelectDevices",
            values: [
                .objectPath(session),
                RemoteDesktopPortalPayload.selectOptions(
                    request: token("request"), restoreToken: restoreToken),
            ]
        ) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result, response.code == 0 else {
                self.close(session)
                return self.fail("SelectDevices", result)
            }
            self.start(session: session, usedRestoreToken: restoreToken != nil)
        }
    }

    private func start(session: String, usedRestoreToken: Bool) {
        request(
            method: "Start",
            values: [
                .objectPath(session), .string(""),
                RemoteDesktopPortalPayload.startOptions(request: token("request")),
            ]
        ) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result,
                let start = RemoteDesktopPortalPayload.startResult(from: response)
            else {
                self.close(session)
                return self.fail("Start", result)
            }
            self.started(
                session: session,
                restoreToken: start.restoreToken,
                needsFocusDelay: !usedRestoreToken
            )
        }
    }

    private func started(session: String, restoreToken: String?, needsFocusDelay: Bool) {
        isStarting = false
        if let restoreToken {
            do {
                try tokenStore.save(restoreToken)
            } catch {
                AppLog.note("paste: could not store RemoteDesktop restore token: \(error)")
            }
        } else {
            self.session = session
            subscribeToSessionClosed(session)
        }
        AppLog.note("paste: RemoteDesktop session granted keyboard input")
        let closeAfter = restoreToken != nil
        guard pending != nil else {
            if closeAfter { close(session) }
            return
        }
        if needsFocusDelay {
            scheduleInjection(session: session, closeAfter: closeAfter)
        } else if let completion = takePending() {
            inject(session: session, closeAfter: closeAfter, completion: completion)
        }
    }

    private func fail(_ step: String, _ result: Result<PortalResponse, DBusError>) {
        isStarting = false
        let error: PasteFailure
        if case .success(let response) = result, response.code == 1 {
            refusedThisRun = true
            error = .consentRefused
        } else {
            error = Self.error(step, result)
        }
        takePending()?(.failure(error))
    }

    func takePending() -> Completion? {
        defer { pending = nil }
        return pending
    }

    private func cancelPendingPaste() {
        pendingInjectionTimer?.cancel()
        pendingInjectionTimer = nil
        let delayedSession = pendingInjectionSession
        pendingInjectionSession = nil
        takePending()?(.failure(PasteFailure.superseded))
        if let delayedSession, delayedSession != session { close(delayedSession) }
    }

    private func token(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func error(
        _ step: String, _ result: Result<PortalResponse, DBusError>
    ) -> PasteFailure {
        switch result {
        case .failure(let error): PasteFailure("\(step): \(error)")
        case .success(let response): PasteFailure("\(step): \(PortalResponse.describe(code: response.code))")
        }
    }
}

struct PasteFailure: Error, CustomStringConvertible {
    let description: String
    let userDetail: String?
    let shouldNotify: Bool

    init(_ description: String, userDetail: String? = nil, shouldNotify: Bool = true) {
        self.description = description
        self.userDetail = userDetail
        self.shouldNotify = shouldNotify
    }

    static let superseded = PasteFailure("a newer paste replaced this one", shouldNotify: false)
    static let consentRefused = PasteFailure(
        "keyboard-control consent was refused; turn Paste automatically off and on to ask again",
        userDetail: "Press Ctrl+V manually. Turn Paste automatically off and on in Settings to ask again."
    )
}
