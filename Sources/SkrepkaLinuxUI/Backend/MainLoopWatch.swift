import CGtk4

/// The main-loop end of a ``MainLoopInbox``: wakes when something has been
/// posted and hands each message to `deliver`, oldest first, on the thread
/// running the loop.
///
/// Lives on that thread and nowhere else. `deliver` is an ordinary closure —
/// not `Sendable` — because it is only ever called there, and that is what
/// lets it capture a window.
public final class MainLoopWatch<Message: Sendable> {
    /// Why the watch could not attach.
    public enum Unavailable: Error, CustomStringConvertible {
        case noSource

        public var description: String { "GLib could not make a source for the inbox's descriptor" }
    }

    private let source: UnsafeMutablePointer<GSource>

    /// - Parameters:
    ///   - context: The main context to attach to. Nil is GTK's, the default
    ///     context; a test passes a private one so it can iterate it by hand.
    ///   - deliver: Called on the loop's thread, once per message.
    public init(
        inbox: MainLoopInbox<Message>,
        context: OpaquePointer? = nil,
        deliver: @escaping (Message) -> Void
    ) throws {
        guard let source = g_unix_fd_source_new(inbox.descriptor, G_IO_IN) else {
            throw Unavailable.noSource
        }
        let wake = LoopCallback {
            for message in inbox.take() { deliver(message) }
        }
        // `g_unix_fd_source_new` wants a `GUnixFDSourceFunc` behind the
        // `GSourceFunc` type `g_source_set_callback` declares — the cast GLib's
        // own documentation shows. The notify drops the callback when GLib
        // destroys the source, which is the only moment it is sure to be done
        // with it.
        g_source_set_callback(
            source,
            unsafeBitCast(LoopCallback.onDescriptorReadable, to: GSourceFunc.self),
            Unmanaged.passRetained(wake).toOpaque(),
            LoopCallback.onReleased
        )
        g_source_attach(source, context)
        self.source = source
    }

    /// Stops delivering. Idempotent; messages still queued stay in the inbox.
    public func cancel() {
        g_source_destroy(source)
    }

    deinit {
        g_source_destroy(source)
        g_source_unref(source)
    }
}
