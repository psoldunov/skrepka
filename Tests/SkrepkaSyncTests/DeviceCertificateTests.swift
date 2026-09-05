import Foundation
import Testing

@testable import SkrepkaSync

/// The identity a device keeps, and the trap that shapes how it is stored.
@Suite("Device certificate")
struct DeviceCertificateTests {
    @Test("Identity survives a round trip through storage")
    func roundTripsThroughStoredBytes() throws {
        let generated = try DeviceCertificate.generate()
        let restored = try DeviceCertificate(
            certificateDER: generated.certificateDER,
            privateKeyPEM: generated.privateKeyPEM
        )
        #expect(restored.deviceID == generated.deviceID)
        #expect(restored.publicKeyBytes == generated.publicKeyBytes)
        #expect(restored.certificateDER == generated.certificateDER)
    }

    /// The measured behaviour recorded in `open-questions.md#oq-6`: ECDSA
    /// signing draws a random nonce, so two certificates built the same way are
    /// two identities. Asserted rather than commented, because it is the reason
    /// `TrustStore.localIdentity()` must persist and never regenerate — and a
    /// future toolchain that made signing deterministic would silently remove
    /// the hazard this test documents.
    @Test("Generating twice produces two identities, which is why the store persists one")
    func generationIsNotDeterministic() throws {
        let first = try DeviceCertificate.generate()
        let second = try DeviceCertificate.generate()
        #expect(first.deviceID != second.deviceID)
    }

    @Test("A key that does not belong to the certificate is refused at construction")
    func refusesAMismatchedKey() throws {
        let one = try DeviceCertificate.generate()
        let two = try DeviceCertificate.generate()
        #expect(throws: DeviceCertificateError.keyDoesNotMatchCertificate) {
            _ = try DeviceCertificate(
                certificateDER: one.certificateDER,
                privateKeyPEM: two.privateKeyPEM
            )
        }
    }

    @Test("Bytes that are not a certificate are refused")
    func refusesRubbish() throws {
        let identity = try DeviceCertificate.generate()
        #expect(throws: (any Error).self) {
            _ = try DeviceCertificate(
                certificateDER: Data("not a certificate".utf8),
                privateKeyPEM: identity.privateKeyPEM
            )
        }
    }

    @Test("The public key read back from a peer's DER matches the owner's own")
    func readsAPeerPublicKey() throws {
        let identity = try DeviceCertificate.generate()
        let asPeerWouldSeeIt = try DeviceCertificate.publicKeyBytes(
            fromCertificateDER: identity.certificateDER
        )
        #expect(asPeerWouldSeeIt == identity.publicKeyBytes)
    }

    @Test("The device identifier is SHA-256 over the stored DER")
    func identifierIsTheHashOfTheStoredBytes() throws {
        let identity = try DeviceCertificate.generate()
        #expect(identity.deviceID == SyncDeviceID(certificateDER: identity.certificateDER))
    }

    @Test("A trust store hands back the same identity every time")
    func trustStorePersistsOneIdentity() async throws {
        let store = InMemoryTrustStore()
        let first = try await store.localIdentity()
        let second = try await store.localIdentity()
        #expect(first.deviceID == second.deviceID)
    }
}
