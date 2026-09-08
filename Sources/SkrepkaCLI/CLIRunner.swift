import Foundation
import SkrepkaIPC

/// `skrepka`, from arguments to exit code.
///
/// Everything the executable target does, so that the entry point is three
/// lines and the whole command can be reached from a test — an executable
/// target cannot be imported, and the parsing and the rendering are exactly
/// what is worth asserting on.
///
/// Exit codes, and they are a contract the Phase 8 packaging tests script
/// against: `0` it happened, `1` the daemon reported it did not, `2` the
/// command line was wrong.
public enum CLIRunner {
    public static func run(_ arguments: [String]) async -> Int32 {
        let options: CLIOptions
        do {
            options = try CLIOptions.parse(arguments)
        } catch let error as CLIError {
            CLIConsole.fail(error.description)
            CLIConsole.advise(CLIOptions.usage)
            return 2
        } catch {
            CLIConsole.fail("the command line could not be read")
            CLIConsole.advise(CLIOptions.usage)
            return 2
        }

        if case .help = options.command {
            CLIConsole.say(CLIOptions.usage)
            return 0
        }
        return await connect(options)
    }

    /// One command, one connection, exit — which is the shape
    /// ``SkrepkaBus/withDaemon(logger:_:)`` offers and the right one for a CLI.
    private static func connect(_ options: CLIOptions) async -> Int32 {
        do {
            return try await SkrepkaBus.withDaemon { proxy in
                try await perform(options, with: proxy)
            }
        } catch let error as IPCError {
            CLIConsole.fail(daemonMessage(error))
            if let remedy = error.remedy { CLIConsole.advise(remedy) }
            return 1
        } catch let error as SkrepkaDocumentCoding.Failure {
            CLIConsole.fail(error.description)
            return 1
        } catch {
            CLIConsole.fail(String(describing: error))
            return 1
        }
    }

    /// Written for a person rather than dumped: "the daemon is not running" is
    /// the common case and reads nothing like the bus error it arrives as.
    private static func daemonMessage(_ error: IPCError) -> String {
        error.isDaemonNotRunning ? "the Skrepka daemon is not running" : error.description
    }

    private static func perform(_ options: CLIOptions, with proxy: DaemonProxy) async throws -> Int32 {
        switch options.command {
        case .help:
            CLIConsole.say(CLIOptions.usage)
            return 0
        case .list(let limit):
            return try await list(limit: limit, isJSON: options.isJSON, proxy: proxy)
        case .peers:
            let document = try await proxy.peers()
            CLIConsole.say(try render(document, isJSON: options.isJSON, text: { PeersReport.text($0) }))
            return 0
        case .doctor:
            return try await doctor(isJSON: options.isJSON, proxy: proxy)
        case .copy(let selector):
            return CLIOutcome.report(try await proxy.copy(selector), whenSilent: "Copied.")
        case .sync:
            return CLIOutcome.report(try await proxy.syncNow(), whenSilent: "Synced.")
        case .unpair(let fingerprint):
            let result = try await proxy.unpair(fingerprint: fingerprint)
            return CLIOutcome.report(result, whenSilent: "Forgotten.")
        case .pair(let peer, let seconds):
            return try await PairingSession(proxy: proxy).run(peer: peer, seconds: seconds)
        }
    }

    private static func list(limit: UInt32, isJSON: Bool, proxy: DaemonProxy) async throws -> Int32 {
        let document = try await proxy.history(limit: limit)
        CLIConsole.say(try render(document, isJSON: isJSON, text: { HistoryReport.text($0) }))
        return 0
    }

    /// A machine with something wrong with it exits nonzero.
    ///
    /// `doctor` is the one read-only command whose answer is a verdict rather
    /// than data, and a check that always succeeds is one nothing can be
    /// scripted against — the Phase 8 packaging tests want to run it and branch.
    /// The daemon decides what counts as a problem; this only reports its list.
    private static func doctor(isJSON: Bool, proxy: DaemonProxy) async throws -> Int32 {
        let document = try await proxy.diagnostics()
        CLIConsole.say(try render(document, isJSON: isJSON, text: { DiagnosticsReport.text($0) }))
        return document.problems.isEmpty ? 0 : 1
    }

    /// `--json` prints the daemon's document unchanged, so a script reads the
    /// same bytes the bus carried rather than a second rendering of them.
    private static func render<Document: SkrepkaDocument>(
        _ document: Document,
        isJSON: Bool,
        text: (Document) -> String
    ) throws -> String {
        isJSON ? try SkrepkaDocumentCoding.encode(document) : text(document)
    }
}
