import Foundation
import SkrepkaIPC

/// Why the service could not start, or could not answer.
///
/// Its own file rather than the bottom of `DaemonService.swift`: the claim that
/// throws ``nameAlreadyOwned`` now lives in ``BusNameClaim`` and the export that
/// throws it lives in ``DaemonService``, so it belongs to neither.
///
/// `Equatable` so a test can name the case it expects rather than only the type
/// — `#expect(throws:)` takes a value only from an equatable error, and "it
/// threw some `ServiceError`" is exactly the assertion that would keep passing
/// if the claim started reporting the wrong one.
public enum ServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case cannotClaimName(reason: String)
    /// Another process already owns `dev.soldunov.Skrepka` on this session bus.
    case nameAlreadyOwned
    /// A caller passed the wrong shape of argument to a member.
    case badArguments(String)

    public var description: String {
        switch self {
        case .cannotClaimName(let reason):
            "could not claim \(SkrepkaInterface.busName): \(reason)"
        case .nameAlreadyOwned:
            """
            Another Skrepka daemon already owns \(SkrepkaInterface.busName) on this session. \
            Two daemons on one clipboard would duplicate the history and publish two records \
            on the network. Stop the other one: systemctl --user stop skrepkad
            """
        case .badArguments(let member):
            "\(member) was called with arguments this build cannot read"
        }
    }
}
