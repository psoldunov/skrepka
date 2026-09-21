import DBUS
import Foundation
import SkrepkaIPC

extension DaemonService {
    /// The version-4 settings surface. Each handler checks the whole body
    /// because DBusObjectServer passes through surplus arguments instead of
    /// rejecting them.
    func settingsMethods() -> [DBusObjectServer.Method] {
        [settingsMethod(), setSettingsMethod()]
    }

    private func settingsMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.settings,
            outputArgs: [DBusObjectServer.MethodArg(name: "settings", type: "s")]
        ) { context in
            guard context.arguments.isEmpty else {
                throw ServiceError.badArguments(SkrepkaInterface.Member.settings)
            }
            return [.string(try SkrepkaDocumentCoding.encode(await daemon.settingsDocument()))]
        }
    }

    /// A patch that is not JSON, or not a patch, is a malformed call rather
    /// than a refusal — nothing a user did produces one, only a client that
    /// built the message wrong. An out-of-range limit is the daemon's
    /// `ok: false`, because a person typed that.
    private func setSettingsMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.setSettings,
            inputArgs: [DBusObjectServer.MethodArg(name: "patch", type: "s")],
            outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
        ) { context in
            // `try?` because every way the decode fails is the same answer to
            // the caller — InvalidArgs — and its reason names the JSON's
            // insides, which is not the bus error's business.
            guard context.arguments.count == 1, let json = Self.string(context.arguments.first),
                let patch = try? SkrepkaDocumentCoding.decode(SettingsPatch.self, from: json)
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.setSettings) }
            return [.string(try SkrepkaDocumentCoding.encode(await daemon.applySettings(patch)))]
        }
    }
}
