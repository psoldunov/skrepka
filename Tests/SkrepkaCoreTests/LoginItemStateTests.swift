import Testing

@testable import SkrepkaCore

@Suite("Login item state")
struct LoginItemStateTests {
    @Test("A registered service reads as registered")
    func enabledIsRegistered() {
        #expect(DiagnosticsSnapshot.LoginItemState.enabled.isRegistered)
    }

    @Test("Waiting for approval is still a registration")
    func requiresApprovalIsRegistered() {
        // `SMAppService.h`: the service "has been successfully registered, but
        // the user needs to take action in System Settings". Drawing it as
        // absent would read as a failure and invite a second request for
        // something that already happened.
        #expect(DiagnosticsSnapshot.LoginItemState.requiresApproval.isRegistered)
    }

    @Test("An unregistered service is not registered")
    func notRegisteredIsNotRegistered() {
        #expect(!DiagnosticsSnapshot.LoginItemState.notRegistered.isRegistered)
    }

    @Test("A service launchd could not find is not registered")
    func notFoundIsNotRegistered() {
        // launchd refuses an app in a temporary location, so nothing was
        // recorded — this is the "move Skrepka to Applications" case, not a
        // half-finished registration like `.requiresApproval`.
        #expect(!DiagnosticsSnapshot.LoginItemState.notFound.isRegistered)
    }

    @Test("Exactly the two registered states count")
    func onlyTwoStatesAreRegistered() {
        // Over `allCases` rather than a hand-written list, so a state added
        // later has to decide which side it falls on instead of being omitted
        // here and defaulting to false unnoticed.
        let registered = DiagnosticsSnapshot.LoginItemState.allCases.filter(\.isRegistered)
        #expect(Set(registered) == [.enabled, .requiresApproval])
    }
}
