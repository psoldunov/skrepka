import Foundation
import SkrepkaSync

// swift-crypto re-exports CryptoKit on Apple platforms, so `SHA256` is the same
// algorithm producing the same bytes either way. Spelled conditionally to match
// `SkrepkaCore.ClipItem`, whose digests this has to reproduce exactly.
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// The commands a running probe takes on standard input.
///
/// One process holding the store rather than a command per invocation, and that
/// is a correctness choice rather than a convenience: the store is one JSON file
/// with no locking, so a second process writing it while the peer serves from it
/// would lose whichever write landed second. A running peer is also the only
/// thing that *can* push, since a push needs the connection it dialled.
public struct ProbeCommands: Sendable {
    let peer: ProbePeer
    let store: ProbeStore

    public init(peer: ProbePeer, store: ProbeStore) {
        self.peer = peer
        self.store = store
    }

    /// Reads until end of input or `quit`.
    ///
    /// `readLine` blocks a thread, which is why this runs on its own detached
    /// task rather than on the cooperative pool: parking a pool thread on a
    /// human is how the peer's own connections stop being served.
    public func run() async {
        while let line = await Self.nextLine() {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let verb = words.first else { continue }
            if verb == "quit" || verb == "exit" { return }
            do {
                ProbeOutput.say(try await handle(verb, arguments: Array(words.dropFirst()), rest: line))
            } catch {
                ProbeOutput.fail(String(describing: error))
            }
        }
    }

    private static func nextLine() async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: readLine(strippingNewline: true))
            }
        }
    }

    /// Split in two along the same line the probe itself is: what the local
    /// history does, and what the peers do. One switch over fourteen verbs is
    /// past the complexity this repo allows, and the split is where a reader
    /// would draw it anyway.
    private func handle(_ verb: String, arguments: [String], rest: String) async throws -> String {
        switch verb {
        case "add": try await add(text(after: "add", in: rest))
        case "list": render(await store.syncIndex(since: nil), title: "syncable")
        case "dump": render(await store.everything(), title: "everything")
        case "pin": try await setPin(true, arguments)
        case "unpin": try await setPin(false, arguments)
        case "delete": try await delete(arguments)
        case "help": ProbeOptions.usage
        default: try await handlePeerCommand(verb, arguments: arguments)
        }
    }

    /// What the links do: who is out there, where they are, and syncing now.
    private func handlePeerCommand(_ verb: String, arguments: [String]) async throws -> String {
        switch verb {
        case "peers": try await peers()
        case "connect": try await connect(arguments)
        case "address": try await address(arguments)
        case "sync": await peer.resyncAll()
        case "status": try await peer.statusLines().joined(separator: "\n")
        default: try await handleTrustCommand(verb, arguments: arguments)
        }
    }

    /// What changes who this peer trusts.
    private func handleTrustCommand(_ verb: String, arguments: [String]) async throws -> String {
        switch verb {
        case "pair": try await pair(arguments)
        case "unpair": try await unpair(arguments)
        case "accept": await peer.answerPairing(true)
        case "reject": await peer.answerPairing(false)
        default: throw ProbeError.unknownCommand(verb)
        }
    }

    /// Everything after the verb, unsplit, so `add hello there` records one
    /// clipping rather than two words.
    private func text(after verb: String, in line: String) -> String {
        String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - History

    private func add(_ text: String) async throws -> String {
        guard !text.isEmpty else { throw ProbeError.missingArgument(command: "add", expected: "text") }
        let deviceID = try await peer.localDeviceID()
        let bytes = Data(text.utf8)
        let key = RepresentationKey(canonical: "text/plain;charset=utf-8")
        let now = Date()
        let meta = SyncClipMeta(
            contentHash: ProbeContentHash.text(text),
            kind: "text",
            preview: text,
            createdAt: now,
            isPinned: LWWRegister(value: false, timestamp: now, deviceID: deviceID),
            originDeviceID: deviceID,
            representations: [RepresentationDescriptor(key: key, byteCount: bytes.count)]
        )
        let isNew = try await store.add(meta, payloads: [key: bytes])
        await peer.pushToPeers(meta, payloads: [key: bytes])
        return "\(isNew ? "added" : "updated")  \(meta.contentHash)"
    }

    private func render(_ items: [SyncClipMeta], title: String) -> String {
        guard !items.isEmpty else { return "\(title): nothing held" }
        let rows = items.map { meta in
            let flags = [
                meta.isPinned.value ? "pinned" : nil,
                meta.isConcealed ? "CONCEALED" : nil,
                meta.representations.isEmpty ? "no bytes" : "\(meta.representations.count) rep",
            ].compactMap { $0 }.joined(separator: " ")
            return "  \(meta.contentHash.prefix(12))  \(flags.padded(to: 22))  "
                + ProbeFormat.oneLine(meta.preview)
        }
        return (["\(title): \(items.count) item(s)"] + rows).joined(separator: "\n")
    }

    private func setPin(_ isPinned: Bool, _ arguments: [String]) async throws -> String {
        let verb = isPinned ? "pin" : "unpin"
        guard let prefix = arguments.first else {
            throw ProbeError.missingArgument(command: verb, expected: "a content hash")
        }
        let hash = try await resolveHash(prefix)
        let deviceID = try await peer.localDeviceID()
        let changed = try await store.setPin(
            isPinned, contentHash: hash, deviceID: deviceID, at: Date())
        return changed ? "\(verb)ned \(hash.prefix(12))" : "no such item"
    }

    private func delete(_ arguments: [String]) async throws -> String {
        guard let prefix = arguments.first else {
            throw ProbeError.missingArgument(command: "delete", expected: "a content hash")
        }
        let hash = try await resolveHash(prefix)
        let deviceID = try await peer.localDeviceID()
        let deleted = try await store.delete(contentHash: hash, deviceID: deviceID, at: Date())
        return deleted ? "deleted \(hash.prefix(12)), tombstone written" : "no such item"
    }

    /// Accepts a prefix of a content hash, because nobody is typing sixty-four
    /// characters from a terminal.
    ///
    /// Ambiguity is an error rather than a guess: acting on the wrong clipping
    /// is exactly the sort of thing that would make a runbook step read as a
    /// protocol bug.
    private func resolveHash(_ prefix: String) async throws -> String {
        let matches = await store.everything().map(\.contentHash).filter { $0.hasPrefix(prefix) }
        switch matches.count {
        case 1: return matches[0]
        case 0:
            throw ProbeError.missingArgument(
                command: "hash",
                expected: "a content hash — nothing starts with '\(prefix)'"
            )
        default:
            throw ProbeError.missingArgument(
                command: "hash",
                expected: "an unambiguous prefix — \(matches.count) items start with '\(prefix)'"
            )
        }
    }

    // MARK: - Peers

    private func peers() async throws -> String {
        var lines: [String] = []
        for record in await store.pairedPeers() {
            let state = await peer.state(of: record.deviceID) ?? "idle"
            let choice = await store.livePushChoice(for: record.deviceID)
            lines.append(
                "  paired  \(record.deviceID.fingerprint)  \(record.deviceName) "
                    + "(\(record.platform.rawValue))  live push: \(choice.rawValue)  — \(state)"
            )
        }
        lines += await peer.sightingLines()
        return lines.isEmpty ? "no devices" : lines.joined(separator: "\n")
    }

    private func connect(_ arguments: [String]) async throws -> String {
        guard arguments.count >= 3,
            let pairingPort = UInt16(arguments[1]),
            let syncPort = UInt16(arguments[2])
        else {
            throw ProbeError.missingArgument(
                command: "connect",
                expected: "HOST PAIRING_PORT SYNC_PORT — the two listeners are different ports"
            )
        }
        return try await peer.connectManually(
            host: arguments[0],
            pairingPort: pairingPort,
            syncPort: syncPort
        )
    }

    private func address(_ arguments: [String]) async throws -> String {
        guard arguments.count >= 3, let port = UInt16(arguments[2]) else {
            throw ProbeError.missingArgument(command: "address", expected: "FINGERPRINT HOST PORT")
        }
        return try await peer.setManualAddress(
            fingerprint: arguments[0],
            host: arguments[1],
            port: port
        )
    }

    private func pair(_ arguments: [String]) async throws -> String {
        guard let fingerprint = arguments.first else {
            throw ProbeError.missingArgument(command: "pair", expected: "a device code")
        }
        return try await peer.pair(with: fingerprint)
    }

    private func unpair(_ arguments: [String]) async throws -> String {
        guard let fingerprint = arguments.first else {
            throw ProbeError.missingArgument(command: "unpair", expected: "a device code")
        }
        guard
            let record = await store.pairedPeers()
                .first(where: { $0.deviceID.hex.hasPrefix(fingerprint) })
        else { return "no paired device starts with \(fingerprint)" }
        try await store.forgetPairedPeer(record.deviceID)
        await peer.pairedSetMayHaveChanged()
        return "forgot \(record.deviceID.fingerprint)"
    }
}

/// The content hash a text clipping gets.
///
/// Deliberately **not** `SkrepkaCore.ClipItem.hash(kind:text:payload:)`, which
/// this target cannot see and must not: `SkrepkaProbe` builds on Linux, where
/// `SkrepkaCore` does not. It has to produce the same digest for the same text
/// anyway, or a Mac and the probe would hold two rows for one clipping and every
/// merge assertion in the runbook would be meaningless. The real function hashes
/// the kind's hash domain followed by the text for the kinds whose text *is*
/// their identity, and `text` is one of those.
///
/// `ProbeContentHashTests` pins the two against each other rather than trusting
/// this comment.
public enum ProbeContentHash {
    public static func text(_ value: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("text".utf8))
        hasher.update(data: Data(value.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    /// Pads to a column width, for a list that reads as columns.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
