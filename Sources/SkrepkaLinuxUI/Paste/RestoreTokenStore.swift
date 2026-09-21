import Foundation

struct RestoreTokenStore {
    private let file: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let state = environment["XDG_STATE_HOME"] ?? "\(home)/.local/state"
        file = URL(fileURLWithPath: state)
            .appendingPathComponent("skrepka", isDirectory: true)
            .appendingPathComponent("remote-desktop-token")
    }

    func load() -> String? {
        // A missing or unreadable token only means the portal asks again.
        guard
            let token = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return nil }
        return token
    }

    func save(_ token: String) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
