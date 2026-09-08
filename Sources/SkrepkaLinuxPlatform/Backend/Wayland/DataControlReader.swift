import Foundation
import SkrepkaCore

extension DataControlSession.Command: LinuxSessionCommand {}

/// A ``SkrepkaCore/ClipboardSource`` over either Wayland data-control protocol.
///
/// ## One reader, not two
///
/// The phase plan named `ExtDataControlReader` and `WlrDataControlReader` as
/// separate deliverables. They collapsed into this, and the reason is a
/// measurement rather than a preference: normalising the `ext_data_control_`
/// and `zwlr_data_control_` prefixes off the two vendored protocol XML files
/// leaves **37 identical entries each** — every interface, request, event and
/// argument. `wayland-scanner` emits 665 lines of header from either.
///
/// Two readers would therefore be one implementation typed out twice, and the
/// deprecated spelling is the one with hardware behind it — a bug fixed in the
/// current one would sit unfixed where it actually bites. What differs between
/// the protocols is the C symbol names, and that is exactly what
/// ``DataControlProtocolBinding`` and its two conformers isolate. The two
/// named readers survive as ``ext`` and ``wlr``.
///
/// ## Event driven, so nothing polls
///
/// ``changeNotifications()`` returns a stream, so `ClipboardWatcher` runs no
/// timer at all. That is the whole reason `ClipboardSource` carries both
/// shapes: macOS has no clipboard notification and is stuck at a 200 ms tick,
/// and Wayland has had one all along.
///
/// The thread, the wakeup pipe and the baseline wait are
/// ``LinuxSessionRunner``'s, shared with ``XFixesReader`` for the same reason
/// the two protocol bindings share this class.
public actor DataControlReader: ClipboardSource {
    public typealias StartError = LinuxSessionStartError

    private let kind: LinuxClipboardBackendKind
    private let displayName: String?
    private let runner = LinuxSessionRunner<DataControlSession.Command>()

    /// - Parameter displayName: which compositor to connect to, or nil to let
    ///   libwayland read `WAYLAND_DISPLAY`. An absolute socket path is used
    ///   as-is and needs no `XDG_RUNTIME_DIR`.
    public init(_ kind: LinuxClipboardBackendKind, displayName: String? = nil) {
        self.kind = kind
        self.displayName = displayName
    }

    /// `ext-data-control-v1`, the current protocol.
    public static func ext() -> DataControlReader { DataControlReader(.extDataControl) }
    /// `zwlr-data-control-unstable-v1`, deprecated and still the only one some
    /// compositors advertise.
    public static func wlr() -> DataControlReader { DataControlReader(.wlrDataControl) }

    /// Connects, and returns once the clipboard's current contents have been
    /// read.
    public func start() async throws {
        // Copied out so the thread body captures these and nothing else of the
        // actor's; the session itself is built inside and never leaves.
        let kind = self.kind
        let displayName = self.displayName
        try await runner.start(threadNamed: "dev.soldunov.skrepka.wayland-clipboard") { context in
            let binding: any DataControlProtocolBinding =
                kind == .extDataControl ? ExtDataControlBinding() : WlrDataControlBinding()
            DataControlSession(
                binding: binding,
                state: context.state,
                notify: context.notify,
                displayName: displayName
            )
            .run(commands: context.commands, wakeup: context.wakeup)
        }
    }

    /// Stops the session and waits for its thread to unwind.
    public func stop() async {
        await runner.stop()
    }

    /// Puts a payload on the clipboard, keyed by MIME target, or clears it.
    ///
    /// Skrepka keeps serving it until another client takes the selection —
    /// which is what a Wayland data source is: not a write, but an offer that
    /// stays live. Returns as soon as the request is queued; the loop performs
    /// it on its next pass.
    public func setSelection(_ payload: [String: Data]?) {
        runner.setSelection(payload)
    }

    /// Why the session stopped, when it stopped for a reason.
    public var failure: String? { runner.failure }

    // MARK: - ClipboardSource

    public func changeCount() -> Int { runner.state.contents.changeCount }

    /// - Parameter sourceBundleID: ignored. Design §8: there is no Linux
    ///   analogue of a bundle identifier, and filling it with a process name
    ///   would put something in the field that no surface reading it means.
    public func read(sourceBundleID: String?) -> PasteboardRead { runner.state.contents.read }

    public func changeNotifications() -> AsyncStream<Void>? { runner.notifications }
}
