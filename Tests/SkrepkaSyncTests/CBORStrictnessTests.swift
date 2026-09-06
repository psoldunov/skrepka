import Foundation
import Testing

@testable import SkrepkaSync

/// What the decoder refuses that a *well-formed* CBOR reader would accept.
///
/// `CanonicalCBORTests` pins the codec against RFC 8949 itself — the Appendix A
/// vectors, malformed bodies, the huge-declared-length family. This suite pins
/// the two places the decoder is deliberately narrower than the RFC: a total
/// item budget the RFC has no opinion about, and §4.2.1's core deterministic
/// encoding requirements, which the RFC states for *encoders* and which this
/// codec enforces on both halves so one logical message has one encoding.
@Suite("CBOR strictness")
struct CBORStrictnessTests {
    private func bytes(_ literal: String) throws -> Data { try CBORVector.bytes(literal) }

    /// The case ``CanonicalCBORTests/refusesHugeDeclaredLengths()`` does not
    /// cover: a count that is entirely *honest* about the bytes backing it.
    ///
    /// `9a 02000000` is an array of 33,554,432 elements followed by exactly that
    /// many `0xf6` nulls. The body is 33,554,437 bytes, inside
    /// ``SyncLimits/maximumFrameBodyBytes``, so the framing layer passes it, and
    /// ``ByteCursor/boundedCount(_:)`` passes it too — every declared element
    /// really is there. What it costs is the product nothing else bounded: a
    /// `CBORValue` carries sixteen bytes of payload, so honouring this is half a
    /// gigabyte resident and about twice that at the peak of the array's
    /// doubling growth, per connection. `PinPolicy.pairing` accepts any
    /// well-formed leaf and the policy check happens *after* the decode, so an
    /// unpaired device on the LAN can send it.
    @Test("Refuses an honest count whose elements would not fit in memory")
    func refusesAnHonestCountPastTheItemBudget() throws {
        let body = try bytes("9a02000000") + Data(repeating: 0xf6, count: 33_554_432)
        #expect(body.count < SyncLimits.maximumFrameBodyBytes)
        #expect(throws: CBORError.itemBudgetExhausted) { try CBORDecoder.decode(body) }
    }

    /// The budget's edge, cheaply. The array head is itself an item, so a
    /// container of ``SyncLimits/maximumWireItemCount`` elements is one over the
    /// budget and a container of one fewer sits exactly at it.
    @Test("Spends the item budget on the container as well as on its elements")
    func countsTheContainerTowardsTheItemBudget() {
        func nullArray(of count: Int) -> Data {
            let wide = UInt32(count)
            let head = Data([
                0x9a,
                UInt8(truncatingIfNeeded: wide >> 24),
                UInt8(truncatingIfNeeded: wide >> 16),
                UInt8(truncatingIfNeeded: wide >> 8),
                UInt8(truncatingIfNeeded: wide),
            ])
            return head + Data(repeating: 0xf6, count: count)
        }

        #expect(throws: CBORError.itemBudgetExhausted) {
            try CBORDecoder.decode(nullArray(of: SyncLimits.maximumWireItemCount))
        }
        #expect(throws: Never.self) {
            try CBORDecoder.decode(nullArray(of: SyncLimits.maximumWireItemCount - 1))
        }
    }

    /// RFC 8949 §4.2.1 preferred serialization, enforced on the way *in* as well
    /// as on the way out. `1801` is unsigned 1 written in a two-byte head: valid
    /// CBOR, never something ``CBOREncoder`` emits, and a second encoding of a
    /// message that already has one.
    @Test("Refuses an argument written in a wider head than it needs")
    func refusesNonShortestArguments() throws {
        let wide = [
            "1801",  // unsigned 1 in a one-byte argument
            "190001",  // unsigned 1 in a two-byte argument
            "1a00000001",  // unsigned 1 in a four-byte argument
            "1b0000000000000001",  // unsigned 1 in an eight-byte argument
            "190018",  // unsigned 24, which fits the one-byte form
            "1a00000100",  // unsigned 256, which fits the two-byte form
            "1b0000000000010000",  // unsigned 65536, which fits the four-byte form
            "3801",  // -2 in a one-byte argument
            "5800",  // an empty byte string with a one-byte length
            "7800",  // an empty text string with a one-byte length
            "9800",  // an empty array with a one-byte count
            "b800",  // an empty map with a one-byte count
        ]
        for encoded in wide {
            #expect(throws: CBORError.self) { try CBORDecoder.decode(try bytes(encoded)) }
        }
    }

    /// The shortest form of each width still decodes, so the check bounds the
    /// heads it should and no more.
    @Test("Accepts the shortest head of every width")
    func acceptsTheShortestHeadOfEveryWidth() throws {
        let shortest: [(literal: String, value: UInt64)] = [
            ("17", 23),
            ("1818", 24),
            ("190100", 256),
            ("1a00010000", 65_536),
            ("1b0000000100000000", 4_294_967_296),
        ]
        for (literal, value) in shortest {
            #expect(try CBORDecoder.decode(try bytes(literal)) == .unsigned(value))
        }
    }

    /// §4.2.1 again: keys in the bytewise lexicographic order of their own
    /// encodings. ``CanonicalCBORTests/sortsMapKeysCanonically()`` pins the
    /// encoder's half of that; without this the decoder accepted either order,
    /// so one logical message had `n!` valid encodings and nothing in the codec
    /// said which of them the two halves agreed on.
    @Test("Refuses map keys that are not in canonical order")
    func refusesMapKeysOutOfOrder() throws {
        // {"b": 1, "a": 2}
        #expect(throws: CBORError.mapKeysOutOfOrder) {
            try CBORDecoder.decode(try bytes("a2616201616102"))
        }
        // The same pair the other way round is the canonical encoding.
        #expect(
            try CBORDecoder.decode(try bytes("a2616101616202"))
                == .map([.text("a"): .unsigned(1), .text("b"): .unsigned(2)])
        )
        // {"aa": 1, "z": 2} — sorted by key, which is not the order §4.2.1 asks
        // for: "z" encodes as 617a and "aa" as 626161, so "z" comes first.
        #expect(throws: CBORError.mapKeysOutOfOrder) {
            try CBORDecoder.decode(try bytes("a262616101617a02"))
        }
    }

    /// Where this decoder is deliberately narrower than RFC 8949 §5.6.
    ///
    /// `{"café"(NFC): 1, "café"(NFD): 2}` is two distinct keys to the RFC — the
    /// encodings differ, and they are in canonical order — and one key here,
    /// because duplicate detection goes through `Dictionary` and `CBORValue`
    /// hashes text by Swift `String` equality, which is Unicode canonical
    /// equivalence. No key this protocol uses is accented, and refusing a body
    /// the RFC allows is the safe direction; accepting one it forbids would be
    /// the other.
    @Test("Treats canonically equivalent text keys as one key, unlike RFC 8949 §5.6")
    func refusesCanonicallyEquivalentTextKeys() throws {
        let nfcThenNFD = "a2" + "65636166c3a9" + "01" + "6663616665cc81" + "02"
        #expect(throws: CBORError.duplicateMapKey) {
            try CBORDecoder.decode(try bytes(nfcThenNFD))
        }
    }
}
