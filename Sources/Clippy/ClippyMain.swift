import AppKit

/// Clippy's entry point.
///
/// Plain AppKit rather than a SwiftUI `App`: the only windows are a menu bar
/// item, an `NSPanel` and a settings window, all of which Clippy manages
/// itself. A SwiftUI `Settings` scene would add a scene graph whose window can
/// only be opened through an undocumented responder-chain action, which an
/// accessory app with no key window does not reliably answer.
@main
@MainActor
enum ClippyMain {
    /// `NSApplication` holds its delegate weakly, so something must own it for
    /// the life of the process.
    private static let delegate = ClippyAppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}

/// Starts the coordinator once AppKit is ready — `NSStatusItem` and hotkey
/// registration both need a live app.
final class ClippyAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
