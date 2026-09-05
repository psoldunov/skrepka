import Foundation

/// What a peer claims to be, as carried in a `hello`.
///
/// Exists as a type so the anti-downgrade rule of design §9 can be written as
/// one comparison of two of these — the pre-TLS claim against the one re-sent
/// inside the tunnel — rather than as four field comparisons a reader has to
/// check are exhaustive.
public struct PeerIdentity: Sendable, Hashable {
    public let deviceID: SyncDeviceID
    public let deviceName: String
    public let platform: PeerPlatform
    public let protocolVersion: ProtocolVersion
    /// Named capabilities the peer advertises. Sorted, so two spellings of the
    /// same set compare equal.
    public let capabilities: [String]

    public init(
        deviceID: SyncDeviceID,
        deviceName: String,
        platform: PeerPlatform,
        protocolVersion: ProtocolVersion,
        capabilities: [String] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities.sorted()
    }

    /// Reads an identity out of a `hello`, and nothing else.
    ///
    /// Returns nil for every other message rather than trapping: a peer may
    /// send anything, and "that was not a hello" is a protocol event the caller
    /// handles, not a programmer error.
    public init?(hello message: SyncMessage) {
        guard case .hello(let identity) = message else { return nil }
        self = identity
    }

    /// The `hello` that announces this identity.
    public var hello: SyncMessage { .hello(self) }
}
