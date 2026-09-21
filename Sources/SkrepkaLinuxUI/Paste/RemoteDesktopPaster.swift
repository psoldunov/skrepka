import Foundation

final class RemoteDesktopPaster {
    typealias Completion = (Result<Void, any Error>) -> Void
    typealias Requester = (String, [DBusValue], @escaping PortalRequest.Completion) -> Void
    typealias Injector = (String, @escaping Completion) -> Void

    static let interface = "org.freedesktop.portal.RemoteDesktop"
    let connection: () -> DBusConnection?
    let tokenStore: RestoreTokenStore
    let requester: Requester?
    let injector: Injector?
    var requests: [String: PortalRequest] = [:]
    var session: String?
    var sessionClosed: DBusSignalSubscription?
    var closeTimer: LoopTimer?

    private var pending: Completion?
    private var isStarting = false
    private var refusedThisRun = false
    private var isAutomaticPasteEnabled = true

    init(
        connection: @escaping () -> DBusConnection?,
        tokenStore: RestoreTokenStore = RestoreTokenStore(),
        requester: Requester? = nil,
        injector: Injector? = nil
    ) {
        self.connection = connection
        self.tokenStore = tokenStore
        self.requester = requester
        self.injector = injector
    }

    func paste(completion: @escaping Completion) {
        guard !refusedThisRun else {
            completion(.failure(PasteFailure.consentRefused))
            return
        }
        if let session {
            inject(session: session, closeAfter: false, completion: completion)
            return
        }
        pending?(.failure(PasteFailure.superseded))
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
        guard !enabled, let pending else { return }
        self.pending = nil
        pending(.failure(PasteFailure.superseded))
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
        request(
            method: "SelectDevices",
            values: [
                .objectPath(session),
                RemoteDesktopPortalPayload.selectOptions(
                    request: token("request"), restoreToken: tokenStore.load()),
            ]
        ) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result, response.code == 0 else {
                self.close(session)
                return self.fail("SelectDevices", result)
            }
            self.start(session: session)
        }
    }

    private func start(session: String) {
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
            self.started(session: session, restoreToken: start.restoreToken)
        }
    }

    private func started(session: String, restoreToken: String?) {
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
        guard let completion = takePending() else {
            if restoreToken != nil { close(session) }
            return
        }
        inject(session: session, closeAfter: restoreToken != nil, completion: completion)
    }

    private func fail(_ step: String, _ result: Result<PortalResponse, DBusError>) {
        isStarting = false
        let error: PasteFailure
        if case .success(let response) = result, response.code == 1 || response.code == 2 {
            refusedThisRun = true
            error = .consentRefused
        } else {
            error = Self.error(step, result)
        }
        takePending()?(.failure(error))
    }

    private func takePending() -> Completion? {
        defer { pending = nil }
        return pending
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
