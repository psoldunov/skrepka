import DBUS
import Foundation

// The members a picker calls, all since interface version 3.
//
// Split from `DaemonProxy.swift` by audience rather than by kind: that file is
// the CLI's and the Settings window's surface, this is what a window that
// lists, searches, previews and acts on history entries needs. Same three
// steps per member, through the same `document` helper.
extension DaemonProxy {
    // MARK: - Reading

    /// The entries matching `query`, best first. `limit` of 0 is every match.
    public func search(_ query: String, limit: UInt32 = 0) async throws -> HistoryDocument {
        try await document(
            HistoryDocument.self, SkrepkaInterface.Member.search, .string(query), .uint32(limit))
    }

    /// The picture one entry holds. `maxBytes` is capped at
    /// ``PreviewDocument/defaultByteLimit``; 0 uses that cap.
    public func preview(_ selector: ClipSelector, maxBytes: UInt32 = 0) async throws -> PreviewDocument {
        try await document(
            PreviewDocument.self,
            SkrepkaInterface.Member.preview,
            .string(selector.wireValue),
            .uint32(maxBytes)
        )
    }

    // MARK: - Acting

    public func copy(_ selector: ClipSelector, style: CopyStyle) async throws -> ActionDocument {
        try await document(
            ActionDocument.self,
            SkrepkaInterface.Member.copyAs,
            .string(selector.wireValue),
            .string(style.wireValue)
        )
    }

    public func setPinned(_ selector: ClipSelector, _ pinned: Bool) async throws -> ActionDocument {
        try await document(
            ActionDocument.self,
            SkrepkaInterface.Member.setPinned,
            .string(selector.wireValue),
            .boolean(pinned)
        )
    }

    public func delete(_ selector: ClipSelector) async throws -> ActionDocument {
        try await document(
            ActionDocument.self, SkrepkaInterface.Member.delete, .string(selector.wireValue))
    }

    public func clear(keepingPinned: Bool) async throws -> ActionDocument {
        try await document(ActionDocument.self, SkrepkaInterface.Member.clear, .boolean(keepingPinned))
    }

    // MARK: - Watching

    /// One element per `HistoryChanged`, until the caller stops reading or the
    /// connection ends.
    ///
    /// Subscribed before the match rule is added, for the reason
    /// ``pairingRequests()`` gives: the rule is what starts the bus routing the
    /// signal here, so a change emitted between the two would otherwise reach a
    /// connection with nobody reading.
    public func historyChanges() async throws -> AsyncStream<Void> {
        let signals = await connection.subscribeToSignal(
            interface: SkrepkaInterface.name,
            member: SkrepkaInterface.Signal.historyChanged
        )
        let rule = """
            type='signal',sender='\(SkrepkaInterface.busName)',\
            interface='\(SkrepkaInterface.name)',\
            member='\(SkrepkaInterface.Signal.historyChanged)'
            """
        try await addMatch(rule)
        return AsyncStream { continuation in
            let task = Task {
                for await _ in signals {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
