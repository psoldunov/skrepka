import DBUS
import Foundation

// The Settings window's and `skrepka config`'s members, since interface
// version 4. Same shape as every other member: arguments in, a JSON document
// out, through the shared `document` helper.
extension DaemonProxy {
    /// The daemon's settings and the history figures that go with them.
    public func settings() async throws -> SettingsDocument {
        try await document(SettingsDocument.self, SkrepkaInterface.Member.settings)
    }

    /// Changes the settings `patch` names and leaves the rest alone. An
    /// `ok: false` answer says in a sentence what was refused.
    public func setSettings(_ patch: SettingsPatch) async throws -> ActionDocument {
        let json = try SkrepkaDocumentCoding.encode(patch)
        return try await document(ActionDocument.self, SkrepkaInterface.Member.setSettings, .string(json))
    }
}
