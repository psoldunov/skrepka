import Foundation

/// One line on standard error, prefixed with the program's name.
///
/// Standard error is where the app's log goes: the desktop starts it from the
/// autostart and launcher entries as a systemd unit, which files the stream in
/// the journal — `journalctl --user -t skrepka-gui`, or under the
/// `app-dev.soldunov.Skrepka.App@….service` unit. Written for the outcomes
/// nothing on screen reports — whether the tray icon was accepted, whether
/// the shortcut was bound — because those are the ones a user cannot see fail.
enum AppLog {
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("skrepka-gui: \(message)\n".utf8))
    }
}
