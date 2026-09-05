import Foundation
import Testing

@testable import SkrepkaSync

/// The eight characters a human compares, and the two properties that make the
/// comparison mean anything.
@Suite("Short authentication string")
struct ShortAuthStringTests {
    private let keyA = Data([0x01, 0x02, 0x03, 0x04])
    private let keyB = Data([0xFF, 0xEE, 0xDD, 0xCC])
    private let pairedAt = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("Both ends derive the same string with the key order swapped")
    func bothSidesDeriveTheSameString() {
        let initiator = ShortAuthString.derive(publicKeys: [keyA, keyB], pairedAt: pairedAt)
        let responder = ShortAuthString.derive(publicKeys: [keyB, keyA], pairedAt: pairedAt)
        #expect(initiator == responder)
    }

    @Test("The timestamp changes the string, so a stale exchange cannot be replayed")
    func timestampChangesTheString() {
        let now = ShortAuthString.derive(publicKeys: [keyA, keyB], pairedAt: pairedAt)
        // One millisecond, which is the finest difference the wire can carry.
        let later = ShortAuthString.derive(
            publicKeys: [keyA, keyB],
            pairedAt: pairedAt.addingTimeInterval(0.001)
        )
        #expect(now != later)
    }

    @Test("Sub-millisecond drift does not change the string")
    func ignoresSubMillisecondDrift() {
        // Two devices reading their own clocks will not agree below a
        // millisecond, and the wire carries whole milliseconds — so a
        // derivation that noticed the difference would fail at random.
        let coarse = ShortAuthString.derive(publicKeys: [keyA, keyB], pairedAt: pairedAt)
        let fine = ShortAuthString.derive(
            publicKeys: [keyA, keyB],
            pairedAt: pairedAt.addingTimeInterval(0.0004)
        )
        #expect(coarse == fine)
    }

    @Test("Different keys derive different strings")
    func keysChangeTheString() {
        let pair = ShortAuthString.derive(publicKeys: [keyA, keyB], pairedAt: pairedAt)
        let impostor = ShortAuthString.derive(
            publicKeys: [keyA, Data([0xFF, 0xEE, 0xDD, 0xCD])],
            pairedAt: pairedAt
        )
        #expect(pair != impostor)
    }

    @Test("It is rendered as two groups of four uppercase hex characters")
    func rendersAsGroupsOfFour() throws {
        let string = ShortAuthString.derive(publicKeys: [keyA, keyB], pairedAt: pairedAt)
        #expect(string.count == 9)
        let groups = string.split(separator: "-")
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.count == 4 })
        #expect(groups.allSatisfy { $0.allSatisfy { "0123456789ABCDEF".contains($0) } })
    }

    @Test("Real device certificates derive one string from both directions")
    func agreesOverRealCertificates() throws {
        let one = try DeviceCertificate.generate()
        let two = try DeviceCertificate.generate()
        #expect(
            ShortAuthString.derive(
                publicKeys: [one.publicKeyBytes, two.publicKeyBytes],
                pairedAt: pairedAt
            )
                == ShortAuthString.derive(
                    publicKeys: [two.publicKeyBytes, one.publicKeyBytes],
                    pairedAt: pairedAt
                )
        )
    }
}
