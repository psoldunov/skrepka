import Testing

@testable import SkrepkaLinuxPlatform

@Suite(
    "Wayland virtual keyboard",
    .serialized,
    .enabled(if: HeadlessSession.isAvailable(.sway))
)
struct VirtualKeyboardIntegrationTests {
    @Test("headless Sway accepts the virtual keyboard and Ctrl+V events")
    func sendsPasteChord() throws {
        let session = try HeadlessSession(.sway, label: "virtual-keyboard")
        try session.start()
        defer { session.stop() }

        let mechanism = PasteMechanism.probe(environment: session.probeEnvironment)
        #expect(mechanism == .virtualKeyboard)
        try VirtualKeyboardPaster().paste(displayName: session.waylandSocketPath)
    }
}
