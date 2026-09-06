import Foundation
import SkrepkaProbe
import SkrepkaSync

/// The probe's entry point, and nothing else.
///
/// Everything it does is in `SkrepkaProbe`, because an executable target cannot
/// be imported by a test target and `HistoryStoringContractTests` runs the same
/// suite against `ProbeStore` that it runs against every other conformance. A
/// store nothing tests would be a poor second implementation to have extracted a
/// protocol against.

let options: ProbeOptions
do {
    options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    ProbeOutput.fail(String(describing: error))
    ProbeOutput.say(ProbeOptions.usage)
    exit(2)
}

switch options.command {
case .help:
    ProbeOutput.say(ProbeOptions.usage)

case .list, .dump:
    // Offline, against a store nothing is serving from. Safe because it only
    // reads; every command that writes is inside the running peer, where one
    // process owns the file.
    do {
        let store = try ProbeStore(url: options.storeURL)
        let items =
            options.command == .dump
            ? await store.everything()
            : await store.syncIndex(since: nil)
        for meta in items {
            ProbeOutput.say(
                "\(meta.contentHash.prefix(12))  \(meta.isPinned.value ? "pinned" : "      ")  "
                    + meta.preview.split(whereSeparator: \.isNewline).joined(separator: " ")
            )
        }
    } catch {
        ProbeOutput.fail(String(describing: error))
        exit(1)
    }

case .run:
    do {
        let peer = try ProbePeer(options: options)
        try await peer.start()
        await ProbeCommands(peer: peer, store: peer.historyStore).run()
        await peer.stop()
    } catch {
        ProbeOutput.fail(String(describing: error))
        exit(1)
    }
}
