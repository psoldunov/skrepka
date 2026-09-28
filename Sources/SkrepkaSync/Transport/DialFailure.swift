import NIOCore
import NIOPosix

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Why a dial never reached the peer, in the four shapes a user can act on.
///
/// `SyncClient.connect` fails with whatever NIO fails with, and none of it is a
/// sentence: a peer behind a firewall that drops packets arrives as
/// `ChannelError.connectTimeout` — "Connect timeout (10 s)" — and a port with
/// nothing listening on it as a `NIOConnectionError` wrapping an `ECONNREFUSED`
/// per address tried. Both platforms used to print those raw or fold them into
/// one "could not connect", which is how a Linux firewall blocking every dial
/// from a Mac read exactly like a sleeping laptop.
///
/// This is the classification only. The words belong to each platform's
/// surface — this target owns no user-facing copy — and they can say more than
/// the error can, because they know which device and which port was dialled.
public enum DialFailure: Sendable, Hashable {
    /// Nothing came back before the connect deadline.
    ///
    /// A firewall that drops packets looks exactly like this, and so does a
    /// peer that went to sleep a moment ago. NixOS ships its firewall on and
    /// dropping, which makes it the usual cause for a Linux peer.
    case noAnswer

    /// The peer's machine answered and turned the connection away, so nothing
    /// is listening on that port: Skrepka is not running there, or the pairing
    /// window closed.
    case refused

    /// This machine has no route to the peer's address.
    case unreachable

    /// The peer's host name did not resolve, so no connection was attempted.
    case notFound

    /// The failure `error` describes, or nil when it is not a dial failure at
    /// all — a TLS refusal, a protocol error, a closed channel.
    public init?(_ error: any Error) {
        switch error {
        case let error as ChannelError:
            guard case .connectTimeout = error else { return nil }
            self = .noAnswer
        case let error as NIOConnectionError:
            guard let failure = Self(connectionError: error) else { return nil }
            self = failure
        case let error as IOError:
            guard let failure = Self(errno: error.errnoCode) else { return nil }
            self = failure
        default:
            return nil
        }
    }

    /// Most telling first, for a dial that failed more than one way.
    private static let precedence: [DialFailure] = [.refused, .noAnswer, .unreachable]

    /// Happy Eyeballs tries every address the name resolved to and keeps one
    /// failure per address, so a dual-stack peer can fail two different ways at
    /// once. The most telling one wins: a refusal proves the machine is there,
    /// which is worth more than a route that one address family happens to lack.
    private init?(connectionError error: NIOConnectionError) {
        let failures = error.connectionErrors.compactMap { failure -> DialFailure? in
            guard let error = failure.error as? IOError else { return nil }
            return DialFailure(errno: error.errnoCode)
        }
        if let strongest = Self.precedence.first(where: failures.contains) {
            self = strongest
        } else if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil {
            self = .notFound
        } else {
            return nil
        }
    }

    private init?(errno code: CInt) {
        switch code {
        case ECONNREFUSED: self = .refused
        case ETIMEDOUT: self = .noAnswer
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL: self = .unreachable
        default: return nil
        }
    }
}
