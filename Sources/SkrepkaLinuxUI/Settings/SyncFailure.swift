import SkrepkaIPC

/// Why the window could not do what it was asked, in a sentence for the person
/// using it, and what they can do about it.
///
/// The repository's rule is that an error reaching a user gets a message
/// written for one rather than a description dump. `IPCError` already knows
/// the remedies — the CLI prints them — so this keeps those and rewrites only
/// the part a window shows as a heading.
public struct SyncFailure: Sendable, Hashable, Error {
    public let message: String
    /// A command or a step to take, where there is one.
    public let remedy: String?

    public init(message: String, remedy: String? = nil) {
        self.message = message
        self.remedy = remedy
    }

    /// The failure for whatever a daemon call threw.
    public init(describing error: any Error) {
        switch error {
        case let failure as SyncFailure:
            self = failure
        case let error as IPCError:
            self = Self.describe(error)
        case let failure as SkrepkaDocumentCoding.Failure:
            self.init(
                message: "The Skrepka daemon answered in a form this window cannot read: \(failure).",
                remedy: Self.updateBoth
            )
        default:
            // Nothing a user can act on is known about an error of any other
            // type, so the description is the most useful thing to show.
            self.init(message: SyncText.sentence("Something went wrong: \(error)"))
        }
    }

    static let updateBoth = "Update skrepkad and skrepka-settings together."

    private static func describe(_ error: IPCError) -> SyncFailure {
        if error.isDaemonNotRunning {
            return SyncFailure(message: "The Skrepka daemon is not running.", remedy: error.remedy)
        }
        switch error {
        case .daemonUnavailable:
            return SyncFailure(
                message: "This window cannot reach the session bus, so it cannot talk to Skrepka.",
                remedy: error.remedy
            )
        case .timedOut:
            return SyncFailure(message: "The Skrepka daemon did not answer in time.", remedy: error.remedy)
        case .busError(_, _, let detail) where !detail.isEmpty:
            // The daemon's own sentence — "No single device on this network
            // matches …", "sync is turned off on this device …" — which is
            // already written for a person.
            return SyncFailure(message: SyncText.sentence(detail))
        case .busError(let member, let name, _):
            return SyncFailure(message: "The Skrepka daemon refused \(member) (\(name)).", remedy: updateBoth)
        case .noReply(let member), .unexpectedReply(let member):
            return SyncFailure(
                message: "The Skrepka daemon gave no usable answer to \(member).",
                remedy: updateBoth
            )
        }
    }
}
