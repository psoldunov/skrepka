import CGtk4
import Foundation

/// The one Settings window this process shows.
final class SettingsHost {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let link: DaemonLink
    private let inbox: MainLoopInbox<SyncEvent>
    private var window: SettingsWindow?
    /// Set when the window has closed. An `activate` arriving after that —
    /// the launcher clicked while the process winds down — must not touch it.
    private var hasClosed = false

    init(
        application: UnsafeMutablePointer<GtkApplication>,
        link: DaemonLink,
        inbox: MainLoopInbox<SyncEvent>
    ) {
        self.application = application
        self.link = link
        self.inbox = inbox
    }

    func activate() {
        guard !hasClosed else { return }
        if let window {
            window.present()
            return
        }
        do {
            let onClosed: () -> Void = { [weak self] in self?.hasClosed = true }
            let window = try SettingsWindow(
                application: application, link: link, inbox: inbox, onClosed: onClosed)
            self.window = window
            window.present()
            let link = link
            Task { await link.start() }
        } catch {
            FileHandle.standardError.write(Data("skrepka-settings: \(error)\n".utf8))
        }
    }
}
