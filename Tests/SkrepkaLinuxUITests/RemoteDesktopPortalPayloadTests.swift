import Testing

@testable import SkrepkaLinuxUI

@Suite("Remote Desktop portal payloads")
struct RemoteDesktopPortalPayloadTests {
    @Test("keyboard selection persists and restores")
    func selectOptions() throws {
        let options = RemoteDesktopPortalPayload.selectOptions(
            request: "request_1", restoreToken: "saved-token")
        let values = try #require(options.dictionaryValue)
        #expect(values["types"]?.uint32Value == 1)
        #expect(values["persist_mode"]?.uint32Value == 2)
        #expect(values["restore_token"]?.stringValue == "saved-token")
    }

    @Test("a Start response must grant keyboard access")
    func startResponse() {
        let granted = PortalResponse(
            code: 0,
            results: ["devices": .uint32(1), "restore_token": .string("next-token")]
        )
        let denied = PortalResponse(code: 0, results: ["devices": .uint32(2)])
        #expect(RemoteDesktopPortalPayload.startResult(from: granted)?.restoreToken == "next-token")
        #expect(RemoteDesktopPortalPayload.startResult(from: denied) == nil)
    }

    @Test("CreateSession extracts only a successful session handle")
    func sessionResponse() {
        let success = PortalResponse(
            code: 0,
            results: ["session_handle": .string("/org/freedesktop/portal/session/1")]
        )
        let cancelled = PortalResponse(
            code: 1,
            results: ["session_handle": .string("/org/freedesktop/portal/session/1")]
        )
        #expect(RemoteDesktopPortalPayload.sessionHandle(from: success) != nil)
        #expect(RemoteDesktopPortalPayload.sessionHandle(from: cancelled) == nil)
    }
}
