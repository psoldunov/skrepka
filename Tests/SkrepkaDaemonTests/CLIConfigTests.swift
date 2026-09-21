import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaCLI

/// `skrepka config` and `skrepka config set`.
@Suite("CLI config")
struct CLIConfigTests {
    @Test("`config` and `config --json` print the settings")
    func configReads() throws {
        #expect(try CLIOptions.parse(["config"]).command == .config)
        let json = try CLIOptions.parse(["config", "--json"])
        #expect(json.command == .config)
        #expect(json.isJSON)
    }

    @Test(
        "each key and value becomes the patch that changes it and nothing else",
        arguments: [
            (["retention.items", "100"], SettingsPatch(maximumItems: 100)),
            (["retention.items", "unlimited"], SettingsPatch(maximumItems: 0)),
            (["retention.days", "7"], SettingsPatch(maximumAgeDays: 7)),
            (["retention.days", "unlimited"], SettingsPatch(maximumAgeDays: 0)),
            (["sync.enabled", "on"], SettingsPatch(syncEnabled: true)),
            (["sync.enabled", "off"], SettingsPatch(syncEnabled: false)),
        ]
    )
    func setBuildsAPatch(_ arguments: [String], _ expected: SettingsPatch) throws {
        #expect(try CLIOptions.parse(["config", "set"] + arguments).command == .configure(expected))
    }

    @Test("an unknown key is a usage error that lists the keys")
    func unknownKey() {
        #expect {
            try CLIOptions.parse(["config", "set", "retention.size", "5"])
        } throws: { error in
            guard case .invalidArgument(_, _, let reason) = error as? CLIError else { return false }
            return reason.contains("retention.items") && reason.contains("sync.enabled")
        }
    }

    @Test(
        "a value the key cannot take is a usage error",
        arguments: [
            ["retention.items", "lots"],
            ["retention.items", "-5"],
            ["retention.days", "36501"],
            ["sync.enabled", "yes"],
            ["sync.enabled", "unlimited"],
        ]
    )
    func badValue(_ arguments: [String]) {
        #expect {
            try CLIOptions.parse(["config", "set"] + arguments)
        } throws: { error in
            guard case .invalidArgument = error as? CLIError else { return false }
            return true
        }
    }

    @Test("missing, surplus and misplaced arguments are refused")
    func shapeErrors() {
        #expect(throws: CLIError.missingArgument(command: "config set", expected: "a key and a value")) {
            try CLIOptions.parse(["config", "set"])
        }
        #expect(throws: CLIError.missingArgument(command: "config set retention.days", expected: "a value")) {
            try CLIOptions.parse(["config", "set", "retention.days"])
        }
        #expect(throws: CLIError.unexpectedArgument("extra", command: "config set")) {
            try CLIOptions.parse(["config", "set", "retention.days", "7", "extra"])
        }
        #expect(throws: CLIError.unexpectedArgument("get", command: "config")) {
            try CLIOptions.parse(["config", "get"])
        }
        #expect(throws: CLIError.unknownFlag("--json", command: "config set")) {
            try CLIOptions.parse(["config", "set", "sync.enabled", "on", "--json"])
        }
    }

    @Test("the usage text documents the command and every key")
    func usageDocumentsConfig() {
        for key in ConfigArguments.Key.allCases {
            #expect(CLIOptions.usage.contains(key.rawValue))
        }
        #expect(CLIOptions.usage.contains("skrepka config set <key> <value>"))
    }

    @Test("the report names each setting by the key that changes it")
    func reportText() {
        let document = SettingsDocument(
            retention: .init(maximumItems: 0, maximumAgeDays: 30),
            sync: .init(isEnabled: false, isLockedOff: true),
            history: .init(entries: 12, pinned: 3, images: 2),
            protectedMarkers: ["x-kde-passwordManagerHint = secret", "org.nspasteboard.TransientType"]
        )
        #expect(
            SettingsReport.text(document) == """
                RETENTION
                  retention.items  unlimited — every unpinned entry is kept
                  retention.days   30 days

                SYNC
                  sync.enabled     off — skrepkad was started with --no-sync

                HISTORY
                  entries          12
                  pinned           3
                  pictures         2

                ALWAYS PROTECTED
                  x-kde-passwordManagerHint = secret
                  org.nspasteboard.TransientType

                Change one with `skrepka config set <key> <value>`.
                """)
    }

    @Test("sync reads on and off when nothing locks it")
    func syncWording() {
        #expect(SettingsReport.sync(.init(isEnabled: true, isLockedOff: false)) == "on")
        #expect(SettingsReport.sync(.init(isEnabled: false, isLockedOff: false)) == "off")
        #expect(SettingsReport.items(1) == "1 unpinned entry")
        #expect(SettingsReport.days(0).hasPrefix("unlimited"))
    }
}
