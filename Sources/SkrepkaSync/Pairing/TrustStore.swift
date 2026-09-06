import Foundation

/// Everything a device needs to know who it is and who it trusts:
/// ``PairedDeviceStoring`` plus its own key pair.
///
/// A protocol because the answer is different on every platform and none of the
/// three answers belongs in this target:
///
/// - **macOS** keeps the private key in the Keychain, via `KeychainTrustStore`
///   in the app target, and the peer records in SwiftData beside the history.
/// - **Linux** keeps the key in a file at `$XDG_DATA_HOME/skrepka/device.key`,
///   mode `0600`, **created with those permissions rather than `chmod`-ed into
///   them afterwards** — the window between creating a world-readable file and
///   tightening it is small and real. Phase 6 writes that conformance.
/// - **Tests** keep everything in ``InMemoryTrustStore``.
public protocol TrustStore: PairedDeviceStoring {
    /// This device's certificate and key, generating and persisting one the
    /// first time it is asked.
    ///
    /// Must return the same identity on every later call for the lifetime of
    /// the installation. Regenerating changes ``DeviceCertificate/deviceID``
    /// and un-pairs the device from every peer, because the identifier is the
    /// hash of certificate bytes that no longer exist — see
    /// ``DeviceCertificate``. A conformance that regenerates on a read failure
    /// has quietly turned a transient error into a re-pair.
    func localIdentity() async throws -> DeviceCertificate
}
