import Testing

@testable import SkrepkaLinuxUI

@Suite("Remote Desktop paste requests")
struct RemoteDesktopPasterTests {
    @Test("refusing keyboard control prevents another portal prompt until automatic paste is reset")
    func refusalIsRemembered() throws {
        let portal = FakeRemoteDesktopPortal()
        let paster = RemoteDesktopPaster(
            connection: { nil }, requester: portal.request, injector: portal.inject)
        var results: [Result<Void, any Error>] = []

        paster.paste { results.append($0) }
        portal.succeedCreation()
        portal.respond(code: 1)

        #expect(results.count == 1)
        let refusal = try #require(results[0].failure as? PasteFailure)
        #expect(refusal.shouldNotify)
        #expect(refusal.description.contains("Paste automatically"))
        paster.paste { results.append($0) }
        #expect(portal.methods == ["CreateSession", "SelectDevices"])
        #expect(results.count == 2)

        paster.setAutomaticPasteEnabled(false)
        paster.setAutomaticPasteEnabled(true)
        paster.paste { results.append($0) }
        #expect(portal.methods.last == "CreateSession")
    }

    @Test("a portal Closed signal invalidates the cached session")
    func closedSessionIsDropped() {
        let portal = FakeRemoteDesktopPortal()
        let paster = RemoteDesktopPaster(
            connection: { nil }, requester: portal.request, injector: portal.inject)

        paster.paste { _ in }
        portal.succeedCreation()
        portal.respond(code: 0)
        portal.succeedStart()
        paster.sessionDidClose("/session/skrepka")
        paster.paste { _ in }

        #expect(portal.methods.last == "CreateSession")
    }

    @Test("a newer paste supersedes the pending paste and injects only once")
    func pendingPasteIsCoalesced() throws {
        let portal = FakeRemoteDesktopPortal()
        let paster = RemoteDesktopPaster(
            connection: { nil }, requester: portal.request, injector: portal.inject)
        var first: Result<Void, any Error>?
        var second: Result<Void, any Error>?

        paster.paste { first = $0 }
        paster.paste { second = $0 }

        let firstFailure = try #require(first?.failure as? PasteFailure)
        #expect(!firstFailure.shouldNotify)
        portal.succeedCreation()
        portal.respond(code: 0)
        portal.succeedStart()

        #expect(portal.injectedSessions == ["/session/skrepka"])
        #expect(second?.isSuccess == true)
    }
}

private final class FakeRemoteDesktopPortal {
    typealias Reply = PortalRequest.Completion

    private var replies: [Reply] = []
    private(set) var methods: [String] = []
    private(set) var injectedSessions: [String] = []

    func request(method: String, values _: [DBusValue], completion: @escaping Reply) {
        methods.append(method)
        replies.append(completion)
    }

    func inject(session: String, completion: @escaping RemoteDesktopPaster.Completion) {
        injectedSessions.append(session)
        completion(.success(()))
    }

    func succeedCreation() {
        respond(code: 0, results: ["session_handle": .string("/session/skrepka")])
    }

    func succeedStart() {
        respond(code: 0, results: ["devices": .uint32(RemoteDesktopPortalPayload.keyboard)])
    }

    func respond(code: UInt32, results: [String: DBusValue] = [:]) {
        replies.removeFirst()(.success(PortalResponse(code: code, results: results)))
    }
}

extension Result {
    fileprivate var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }

    fileprivate var isSuccess: Bool {
        guard case .success = self else { return false }
        return true
    }
}
