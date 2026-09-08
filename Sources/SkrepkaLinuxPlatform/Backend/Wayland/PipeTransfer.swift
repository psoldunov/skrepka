import Foundation
import SkrepkaSync

#if canImport(Glibc)
    import Glibc
#endif

/// Limits the Linux backends enforce on one clipboard transfer.
enum LinuxClipboardLimits {
    /// Largest payload accepted for one representation.
    ///
    /// The protocol's own ceiling rather than a second number: an item too
    /// large to sync is too large to capture, and `SyncLimitsTests` already
    /// pins that to `CaptureRules.defaultMaximumItemBytes`.
    static let maximumRepresentationBytes = SyncLimits.maximumPayloadBytes

    /// How long one transfer may take before it is abandoned.
    ///
    /// A data-control source writes into a pipe and closes it; a source that
    /// does neither would hold the event loop open forever, and with it every
    /// later clipboard change. Generous enough for a large image out of a slow
    /// application, short enough that a wedged one costs a clipping rather than
    /// the session.
    static let transferTimeout: Duration = .seconds(5)

    /// Scratch size for one `read` or `write` call. A pipe's own buffer is
    /// 64 KiB on Linux by default, so a larger scratch buys nothing.
    static let chunkBytes = 64 * 1024
}

/// One representation being read out of a clipboard owner, through a pipe.
///
/// Non-blocking and bounded, because the alternative is what the phase plan
/// warns about: reading several `receive` pipes in a fixed order with blocking
/// reads deadlocks against a sender waiting for you to drain a different one,
/// and a sender that never closes its end hangs capture outright. Here every
/// transfer is an entry in the event loop's `poll` set and progresses only when
/// its descriptor says it can.
final class InboundTransfer {
    let target: String
    let fileDescriptor: Int32
    private(set) var bytes = Data()
    private(set) var outcome: Outcome?

    enum Outcome: Equatable {
        case complete
        /// Over ``LinuxClipboardLimits/maximumRepresentationBytes``. The bytes
        /// read so far are discarded rather than stored truncated — half an
        /// image is not a smaller image.
        case tooLarge
        case timedOut
        case failed(errno: Int32)
    }

    private let deadline: ContinuousClock.Instant
    private var scratch = [UInt8](repeating: 0, count: LinuxClipboardLimits.chunkBytes)

    init(target: String, fileDescriptor: Int32, now: ContinuousClock.Instant = .now) {
        self.target = target
        self.fileDescriptor = fileDescriptor
        deadline = now.advanced(by: LinuxClipboardLimits.transferTimeout)
    }

    var isFinished: Bool { outcome != nil }

    /// Reads whatever is available right now.
    ///
    /// Called only when `poll` has said the descriptor is readable, so a single
    /// `EAGAIN` means the writer got there first and there is nothing to do —
    /// not an error.
    func readAvailable() {
        guard outcome == nil else { return }
        while true {
            let read = scratch.withUnsafeMutableBytes { buffer in
                Glibc.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if read == 0 {
                // EOF. The owner closed its end, which is how the protocol says
                // a transfer ends.
                finish(.complete)
                return
            }
            if read < 0 {
                if handleReadError() { continue }
                return
            }
            bytes.append(contentsOf: scratch[0..<read])
            guard bytes.count <= LinuxClipboardLimits.maximumRepresentationBytes else {
                bytes.removeAll(keepingCapacity: false)
                finish(.tooLarge)
                return
            }
        }
    }

    /// Whether the loop should try again.
    ///
    /// `EINTR` is a signal that arrived mid-call and nothing more. `EAGAIN` and
    /// `EWOULDBLOCK` mean the writer has not caught up, which is not an error
    /// and not a reason to stop waiting. Anything else ends the transfer.
    private func handleReadError() -> Bool {
        switch errno {
        case EINTR: return true
        case EAGAIN, EWOULDBLOCK: return false
        default:
            finish(.failed(errno: errno))
            return false
        }
    }

    /// Abandons the transfer if it has run out of time.
    func expireIfOverdue(now: ContinuousClock.Instant = .now) {
        guard outcome == nil, now >= deadline else { return }
        bytes.removeAll(keepingCapacity: false)
        finish(.timedOut)
    }

    /// Closes the descriptor and records why.
    ///
    /// Closing here rather than at the call site is what makes every exit from
    /// a transfer — EOF, overflow, timeout, error — release the descriptor. A
    /// backend that leaks one per clipboard change runs out of them in an
    /// afternoon of ordinary use.
    private func finish(_ outcome: Outcome) {
        self.outcome = outcome
        close(fileDescriptor)
    }

    /// Releases the descriptor for a transfer abandoned without finishing —
    /// the event loop shutting down under it.
    func cancel() {
        guard outcome == nil else { return }
        finish(.failed(errno: ECANCELED))
    }
}

/// One representation being written to a clipboard requestor, through the pipe
/// its `send` event handed over.
///
/// Non-blocking for the same reason as ``InboundTransfer``, plus one of its
/// own: the requestor may be Skrepka itself. A Wayland compositor sends the
/// selection back to the client that set it, so a blocking write here against a
/// blocking read there is one thread waiting on itself.
final class OutboundTransfer {
    let fileDescriptor: Int32
    private let bytes: Data
    private var offset = 0
    private(set) var isFinished = false
    private let deadline: ContinuousClock.Instant

    init(bytes: Data, fileDescriptor: Int32, now: ContinuousClock.Instant = .now) {
        self.bytes = bytes
        self.fileDescriptor = fileDescriptor
        deadline = now.advanced(by: LinuxClipboardLimits.transferTimeout)
    }

    /// Writes whatever the pipe will take right now.
    func writeAvailable() {
        guard !isFinished else { return }
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = min(remaining, LinuxClipboardLimits.chunkBytes)
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Glibc.write(fileDescriptor, buffer.baseAddress?.advanced(by: offset), count)
            }
            if written > 0 {
                offset += written
                continue
            }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return
            default:
                // EPIPE included, and it is not a fault: a requestor that only
                // wanted the first few bytes closes its end early, which is
                // ordinary and not worth a diagnostic.
                finish()
                return
            }
        }
        finish()
    }

    func expireIfOverdue(now: ContinuousClock.Instant = .now) {
        guard !isFinished, now >= deadline else { return }
        finish()
    }

    func cancel() { finish() }

    /// Closing is what tells the requestor the data is complete — the protocol
    /// says "send the data ... then close it" — so it is the same operation as
    /// finishing and cannot be separated from it.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        close(fileDescriptor)
    }
}
