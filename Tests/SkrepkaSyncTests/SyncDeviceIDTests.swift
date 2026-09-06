import Foundation
import Testing

@testable import SkrepkaSync

/// The identity the whole authentication story rests on.
@Suite("Sync device identifier")
struct SyncDeviceIDTests {
    /// Derived, not random. A separate random id would be a second identity for
    /// the same device, and two identities that can disagree are an
    /// authentication hole rather than a redundancy.
    @Test("The identifier is the certificate's SHA-256, in lowercase hex")
    func derivesFromTheCertificate() {
        let certificate = Data("certificate-one".utf8)
        let deviceID = SyncDeviceID(certificateDER: certificate)

        #expect(deviceID.hex.count == SyncDeviceID.hexLength)
        #expect(deviceID.hex == deviceID.hex.lowercased())
        // Same certificate, same identifier — on every machine that sees it.
        #expect(deviceID == SyncDeviceID(certificateDER: certificate))
        #expect(deviceID != SyncDeviceID(certificateDER: Data("certificate-two".utf8)))
    }

    /// Design §9 described `id=` and `fp=` as two fields. With a derived
    /// identifier the fingerprint is a prefix of the identifier, so the record
    /// carries one key instead of two and the two cannot disagree.
    @Test("The discovery fingerprint is a prefix of the identifier")
    func fingerprintIsAPrefix() {
        let deviceID = SyncFixtures.deviceA
        #expect(deviceID.fingerprint.count == SyncDeviceID.fingerprintLength)
        #expect(deviceID.hex.hasPrefix(deviceID.fingerprint))
    }

    /// An identifier arriving from a TXT record, a database column or a decoded
    /// frame is validated rather than normalised: two spellings of one device
    /// that compare unequal are worse than a rejected one.
    @Test("A malformed identifier is refused rather than normalised")
    func refusesMalformedIdentifiers() throws {
        let valid = SyncFixtures.deviceA.hex
        #expect(SyncDeviceID(hex: valid)?.hex == valid)

        let malformed = [
            "",
            String(valid.dropLast()),
            valid + "0",
            valid.uppercased(),
            String(repeating: "g", count: SyncDeviceID.hexLength),
            String(repeating: "٠", count: SyncDeviceID.hexLength),  // Arabic-Indic digits
        ]
        for hex in malformed { #expect(SyncDeviceID(hex: hex) == nil) }
    }

    @Test("Coding refuses an identifier that is not one")
    func codingValidates() throws {
        let encoded = try JSONEncoder().encode(SyncFixtures.deviceA)
        #expect(try JSONDecoder().decode(SyncDeviceID.self, from: encoded) == SyncFixtures.deviceA)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SyncDeviceID.self, from: Data(#""nonsense""#.utf8))
        }
    }
}
