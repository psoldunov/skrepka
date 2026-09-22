import SkrepkaIPC
import SkrepkaLinuxPlatform
import Testing

@testable import SkrepkaDaemon

@Suite("GNOME Shell extension liveness")
struct ShellExtensionLivenessTests {
    @Test("heartbeats register, refresh, expire, and explicitly unregister the extension")
    func lifecycle() async throws {
        let daemon = try SubmitLimitTests.daemon()
        let start = ContinuousClock.now

        #expect(await daemon.isShellExtensionLive(at: start) == false)
        _ = await daemon.setShellExtensionActive(true, at: start)
        #expect(await daemon.isShellExtensionLive(at: start + Daemon.shellExtensionTimeout))

        let refreshed = start + .seconds(20)
        _ = await daemon.setShellExtensionActive(true, at: refreshed)
        #expect(await daemon.isShellExtensionLive(at: refreshed + Daemon.shellExtensionTimeout))
        #expect(
            await daemon.isShellExtensionLive(
                at: refreshed + Daemon.shellExtensionTimeout + .nanoseconds(1)) == false)

        _ = await daemon.setShellExtensionActive(true, at: refreshed)
        _ = await daemon.setShellExtensionActive(false, at: refreshed)
        #expect(await daemon.isShellExtensionLive(at: refreshed) == false)
    }

    @Test("diagnostics report extension coverage only while its registration is live")
    func diagnosticsFollowLiveness() async throws {
        let daemon = try SubmitLimitTests.daemon()
        let start = ContinuousClock.now
        let report = SessionProbe.decide(
            waylandGlobals: [],
            waylandDisplay: "wayland-0",
            x11Display: ":0",
            desktop: "GNOME"
        )

        _ = await daemon.setShellExtensionActive(true, at: start)
        #expect(
            await daemon.sessionSection(report: report, at: start).nativeWaylandCapture
                == .shellExtension)
        #expect(
            await daemon.sessionSection(
                report: report,
                at: start + Daemon.shellExtensionTimeout + .nanoseconds(1)
            ).nativeWaylandCapture == nil)
    }
}
