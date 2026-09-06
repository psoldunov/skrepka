import Foundation
import SkrepkaSync

/// How the probe was invoked.
///
/// Hand-parsed rather than through `ArgumentParser`. The probe must build on
/// Linux with nothing but what `SkrepkaSync` already pulls in, and adding a
/// dependency to the package so a test tool can have `--help` is a poor trade —
/// especially one the app itself would then resolve on every build.
public struct ProbeOptions: Sendable {
    public static let usage = """
        skrepka-sync-probe — a headless Skrepka peer, for exercising sync by hand.

        USAGE
          skrepka-sync-probe run   [options]     listen, advertise, and take commands on stdin
          skrepka-sync-probe list  [--dir PATH]  print the stored history and exit
          skrepka-sync-probe dump  [--dir PATH]  print everything, concealed items included

        OPTIONS
          --dir PATH        where the store and identity live (default ./.skrepka-probe)
          --name NAME       what this peer calls itself (default "skrepka-probe")
          --platform NAME   macos | linux (default linux)
          --port N          sync listener port (default: any free port)
          --pair            also open the pairing listener, and advertise its port
          --confirm-pairing wait for `accept` or `reject` instead of accepting

        COMMANDS, once running
          add TEXT             record a clipping, and push it to every live peer
          list                 the syncable index, as a peer would be offered it
          dump                 everything held, concealed items included
          pin HASH             pin, stamping the register that carries it
          unpin HASH           the reverse
          delete HASH          delete, writing the tombstone that makes it stick
          peers                paired devices and what each link is doing
          connect HOST PAIR SYNC   pair with a peer by address, where there is no mDNS
          address FP HOST PORT     point a paired peer at an address
          sync                     exchange indexes now rather than on the timer
          pair FINGERPRINT     pair with a device seen on the network
          unpair FINGERPRINT   forget a device
          accept | reject      answer a pairing that is waiting
          status               identity, ports, and what is advertised
          quit
        """

    public enum Command: Sendable {
        case run
        case list
        case dump
        case help
    }

    public var command: Command = .run
    public var directory = URL(fileURLWithPath: ".skrepka-probe")
    public var name = "skrepka-probe"
    /// Defaults to `linux`, because that is the whole point of the probe: two
    /// Mac desktop sessions would re-introduce the Universal Clipboard
    /// collision this design exists to avoid, so the stand-in peer advertises
    /// the platform live push is meant for.
    public var platform: PeerPlatform = .linux
    public var port = 0
    public var opensPairingListener = false
    /// Whether an incoming pairing waits for the operator.
    ///
    /// Off by default so a scripted run is not blocked; the runbook turns it on,
    /// because "both show the same code and both confirm" is the step, and a
    /// peer that confirms before a human has looked has not performed it.
    public var confirmsPairing = false

    public init() {}

    /// Parses `CommandLine.arguments`, minus the executable name.
    ///
    /// An unknown flag is an error rather than something ignored: a probe that
    /// silently dropped `--platform macos` would have runbook step 11 pass while
    /// testing nothing.
    public static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        var rest = arguments[...]

        switch rest.first {
        case "run", nil: options.command = .run
        case "list": options.command = .list
        case "dump": options.command = .dump
        case "help", "--help", "-h": return help()
        case let other?: throw ProbeError.unknownCommand(other)
        }
        if !rest.isEmpty { rest = rest.dropFirst() }

        while let flag = rest.first {
            rest = rest.dropFirst()
            try options.apply(flag, from: &rest)
        }
        return options
    }

    /// One flag, and the value it takes if it takes one.
    private mutating func apply(_ flag: String, from rest: inout ArraySlice<String>) throws {
        switch flag {
        case "--pair": opensPairingListener = true
        case "--confirm-pairing": confirmsPairing = true
        case "--dir": directory = URL(fileURLWithPath: try Self.value(&rest, for: flag))
        case "--name": name = try Self.value(&rest, for: flag)
        case "--platform": platform = PeerPlatform(wireValue: try Self.value(&rest, for: flag))
        case "--port": port = Int(try Self.value(&rest, for: flag)) ?? 0
        default: throw ProbeError.unknownCommand(flag)
        }
    }

    private static func help() -> ProbeOptions {
        var options = ProbeOptions()
        options.command = .help
        return options
    }

    private static func value(_ rest: inout ArraySlice<String>, for flag: String) throws -> String {
        guard let value = rest.first else {
            throw ProbeError.missingArgument(command: flag, expected: "a value")
        }
        rest = rest.dropFirst()
        return value
    }

    public var storeURL: URL { directory.appending(path: "history.json") }
    public var identityURL: URL { directory.appending(path: "device.key") }
}
