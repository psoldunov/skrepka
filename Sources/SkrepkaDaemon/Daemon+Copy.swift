import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

// Putting one history entry on the clipboard — `skrepka copy` and the picker's
// `CopyAs`. Split from `Daemon+Documents.swift` at the 300-line ceiling.
extension Daemon {
    /// The clipboard targets an entry's stored representations can be written
    /// as, dropping any whose type identifier this build does not map.
    static func writableTargets(
        from representations: [String: Data]
    ) -> [String: Data] {
        var payloads: [RepresentationKey: Data] = [:]
        for (type, data) in representations {
            guard let key = RepresentationKeyMap.key(forUTI: type) else { continue }
            payloads[key] = data
        }
        return LinuxClipboardWriter.targets(for: payloads)
    }

    /// The text target alone, for a paste that must not carry markup or images.
    static func plainWritableTargets(from representations: [String: Data]) -> [String: Data] {
        let text = representations.filter {
            RepresentationKeyMap.canonical(forUTI: $0.key) == "text/plain;charset=utf-8"
        }
        return writableTargets(from: text)
    }

    /// Puts one entry on the clipboard.
    public func copy(_ selector: ClipSelector) async -> ActionDocument {
        await copy(
            selector,
            targetBuilder: \.targets,
            emptyTargetDetail: "nothing in that entry can be written to a Linux clipboard"
        )
    }

    func copy(
        _ selector: ClipSelector,
        targetBuilder: (ClipboardWrite) -> [String: Data],
        emptyTargetDetail: String
    ) async -> ActionDocument {
        guard clipboard != nil else {
            return .refused(
                """
                There is no clipboard to write to in this session. \
                Run `skrepka doctor` to see what this session offers.
                """
            )
        }
        let entry: SQLiteHistoryStore.ClipListing
        let write: ClipboardWrite
        switch await resolvedWrite(selector) {
        case .refused(let answer): return answer
        case .found(let found, let built):
            entry = found
            write = built
        }
        let targets = targetBuilder(write)
        guard !targets.isEmpty else {
            return .refused(emptyTargetDetail, subject: entry.contentHash)
        }
        // Re-bound here rather than relied on from the guard at the top: the
        // reads above are suspension points, and `performStop()` clears
        // `clipboard` between them. The optional chain this replaces wrote
        // nothing in that case and still answered `.succeeded`, so `skrepka
        // copy` printed "Copied." over an unchanged clipboard.
        guard let clipboard else {
            return .refused(
                """
                The clipboard for this session went away while that entry was \
                being read, so nothing was copied. Try again.
                """,
                subject: entry.contentHash
            )
        }
        // `.copy`, unlike a live push's `.handoff`: a copy the user asked for
        // is a copy, and hoisting it back to the top of the history is what
        // every clipboard manager does. Not for a file row from another
        // device, though: what is written is files in this machine's cache,
        // or their names, and captured back it would be a second row pointing
        // into a cache that is swept when the first one goes.
        await clipboard.setSelection(targets, as: write.replacesRow ? .handoff : .copy)
        return .succeeded(Self.copiedDetail(entry), subject: entry.contentHash)
    }

    private enum ResolvedWrite {
        case found(SQLiteHistoryStore.ClipListing, ClipboardWrite)
        case refused(ActionDocument)
    }

    /// The entry a selector names and what it puts on the clipboard.
    private func resolvedWrite(_ selector: ClipSelector) async -> ResolvedWrite {
        let listing: [SQLiteHistoryStore.ClipListing]
        do {
            listing = try await store.listing()
        } catch {
            // Surfaced rather than discarded: an empty listing here reads as
            // "there is nothing in the history yet", which is the one thing
            // this failure is not.
            return .refused(.refused("could not read the history: \(error)"))
        }
        guard let entry = Self.resolve(selector, in: listing) else {
            return .refused(.refused(Self.notFound(selector, count: listing.count)))
        }
        guard let contents = await store.contents(for: entry.summary.id) else {
            return .refused(
                .refused("that entry holds no bytes on this device yet", subject: entry.contentHash))
        }
        let local = await localDeviceHex(ifAnyOf: [entry])
        let source = WritableRow(
            kind: entry.summary.kind,
            representations: contents.payload.representations,
            fileURLs: contents.fileURLs,
            preview: entry.summary.text,
            contentHash: entry.contentHash,
            isForeign: Self.isForeign(origin: entry.originDeviceID, local: local)
        )
        return .found(entry, await clipboardWrite(for: source))
    }

    static func resolve(
        _ selector: ClipSelector,
        in listing: [SQLiteHistoryStore.ClipListing]
    ) -> SQLiteHistoryStore.ClipListing? {
        switch selector {
        case .position(let index):
            guard index >= 1, index <= listing.count else { return nil }
            return listing[index - 1]
        case .hash(let prefix):
            let matches = listing.filter { $0.contentHash.hasPrefix(prefix) }
            // Exactly one, or nothing. A prefix that collides names unrelated
            // content and picking either pastes something nobody asked for.
            return matches.count == 1 ? matches.first : nil
        }
    }

    static func notFound(_ selector: ClipSelector, count: Int) -> String {
        switch selector {
        case .position(let index):
            count == 0
                ? "there is nothing in the history yet"
                : "there is no entry \(index) — the history holds \(count)"
        case .hash(let prefix):
            "no single entry starts with \"\(prefix)\""
        }
    }

    /// Reads through the same masking and stripping the listing does: this
    /// string is printed straight into the terminal that asked for the copy.
    private static func copiedDetail(_ entry: SQLiteHistoryStore.ClipListing) -> String {
        "copied \(SafeText.oneLine(entry.summary.previewText, limit: 60))"
    }
}
