import Foundation
import Testing

@testable import SkrepkaSync

/// The hand-rolled CBOR subset, against RFC 8949 itself.
///
/// This file exists because OQ-8 was answered "no": `valpackett/SwiftCBOR`
/// allocates from a wire-supplied count before reading the bytes and recurses
/// without a depth bound, so a nine-byte body is a remote crash. The subset
/// replacing it has to be *shown* hostile-input-safe rather than assumed to be,
/// and its encoding has to match the RFC rather than a memory of it — hence the
/// Appendix A vectors below, transcribed from Table 6.
@Suite("Canonical CBOR")
struct CanonicalCBORTests {
    private func hex(_ data: Data) -> String { CBORVector.hex(data) }

    private func bytes(_ literal: String) throws -> Data { try CBORVector.bytes(literal) }

    /// RFC 8949 Appendix A, Table 6 — the rows inside this subset.
    ///
    /// Every one of these also pins preferred serialization (§4.2.1): the
    /// expected bytes are the shortest form that holds the value, so an encoder
    /// reaching for a wider argument fails here.
    private static let appendixA: [(value: CBORValue, encoded: String)] = [
        (.unsigned(0), "00"),
        (.unsigned(1), "01"),
        (.unsigned(10), "0a"),
        (.unsigned(23), "17"),
        (.unsigned(24), "1818"),
        (.unsigned(25), "1819"),
        (.unsigned(100), "1864"),
        (.unsigned(1000), "1903e8"),
        (.unsigned(1_000_000), "1a000f4240"),
        (.unsigned(1_000_000_000_000), "1b000000e8d4a51000"),
        (.unsigned(18_446_744_073_709_551_615), "1bffffffffffffffff"),
        (.integer(-1), "20"),
        (.integer(-10), "29"),
        (.integer(-100), "3863"),
        (.integer(-1000), "3903e7"),
        (.boolean(false), "f4"),
        (.boolean(true), "f5"),
        (.null, "f6"),
        (.bytes(Data()), "40"),
        (.bytes(Data([0x01, 0x02, 0x03, 0x04])), "4401020304"),
        (.text(""), "60"),
        (.text("a"), "6161"),
        (.text("IETF"), "6449455446"),
        (.text("\"\\"), "62225c"),
        (.text("\u{00fc}"), "62c3bc"),
        (.text("\u{6c34}"), "63e6b0b4"),
        (.text("\u{10151}"), "64f0908591"),
        (.array([]), "80"),
        (.array([.unsigned(1), .unsigned(2), .unsigned(3)]), "83010203"),
        (
            .array([
                .unsigned(1),
                .array([.unsigned(2), .unsigned(3)]),
                .array([.unsigned(4), .unsigned(5)]),
            ]),
            "8301820203820405"
        ),
        (.map([:]), "a0"),
        (.map([.unsigned(1): .unsigned(2), .unsigned(3): .unsigned(4)]), "a201020304"),
        (
            .map([.text("a"): .unsigned(1), .text("b"): .array([.unsigned(2), .unsigned(3)])]),
            "a26161016162820203"
        ),
        (.array([.text("a"), .map([.text("b"): .text("c")])]), "826161a161626163"),
    ]

    @Test("Encodes the RFC 8949 Appendix A vectors byte for byte")
    func encodesAppendixAVectors() throws {
        for (value, expected) in Self.appendixA {
            #expect(hex(try CBOREncoder.encode(value)) == expected)
        }
    }

    @Test("Decodes the RFC 8949 Appendix A vectors back to the same value")
    func decodesAppendixAVectors() throws {
        for (value, encoded) in Self.appendixA {
            #expect(try CBORDecoder.decode(try bytes(encoded)) == value)
        }
    }

    /// RFC 8949 §4.2.1 sorts keys by the bytewise lexicographic order of their
    /// *encodings*, which is not the order the same keys sort in as strings:
    /// `"z"` encodes as `0x617a` and `"aa"` as `0x626161`, so `"z"` comes
    /// first. An encoder that sorted the keys instead would put them the other
    /// way round, and two peers would hash different bytes.
    @Test("Sorts map keys by encoded bytes, not by key")
    func sortsMapKeysCanonically() throws {
        let value = CBORValue.map([.text("aa"): .unsigned(2), .text("z"): .unsigned(1)])
        #expect(hex(try CBOREncoder.encode(value)) == "a2617a0162616102")
    }

    /// Deterministic encoding is what Phase 2's short authentication string
    /// depends on: two peers hashing the same value must produce the same
    /// digest, and `Dictionary` iteration order is seeded per process.
    @Test("Encodes a map identically however it was built")
    func encodesMapsDeterministically() throws {
        let keys = (0..<64).map { CBORValue.text("field-\($0)") }
        var forwards: [CBORValue: CBORValue] = [:]
        var backwards: [CBORValue: CBORValue] = [:]
        for (index, key) in keys.enumerated() { forwards[key] = .unsigned(UInt64(index)) }
        for (index, key) in keys.enumerated().reversed() {
            backwards[key] = .unsigned(UInt64(index))
        }
        let first = try CBOREncoder.encode(.map(forwards))
        let second = try CBOREncoder.encode(.map(backwards))
        #expect(first == second)
    }

    /// The `SwiftCBOR` defect this codec exists to avoid, as a regression test:
    /// a body of a few bytes declaring 2^40 elements. Every count is bounded
    /// against the bytes that remain before anything is allocated, so these
    /// throw in constant time and constant memory — a frame-size cap would not
    /// have helped, because a tiny body can declare a huge length.
    @Test("Refuses a huge declared length without allocating for it")
    func refusesHugeDeclaredLengths() throws {
        let bodies = [
            "9b00000100000000000102",  // array of 2^40, two bytes present
            "bb00000100000000000102",  // map of 2^40 pairs
            "5b0000010000000000",  // byte string of 2^40
            "7b0000010000000000",  // text string of 2^40
            "9bffffffffffffffff",  // array of 2^64-1, which does not fit in Int
        ]
        for body in bodies {
            #expect(throws: CBORError.self) { try CBORDecoder.decode(try bytes(body)) }
        }
    }

    @Test("Refuses indefinite-length items outright")
    func refusesIndefiniteLengths() throws {
        let indefinite = [
            "5f42010243030405ff",  // (_ h'0102', h'030405')
            "7f657374726561646d696e67ff",  // (_ "strea", "ming")
            "9f0102ff",  // [_ 1, 2]
            "bf616101ff",  // {_ "a": 1}
            "ff",  // a bare break stop code
        ]
        for encoded in indefinite {
            #expect(throws: CBORError.self) { try CBORDecoder.decode(try bytes(encoded)) }
        }
    }

    /// A nested-array bomb. Unbounded recursion here is a stack overflow, which
    /// is a crash no `catch` can reach — so the depth is checked *before* the
    /// decoder recurses rather than after.
    @Test("Refuses nesting past the depth bound instead of overflowing the stack")
    func refusesDeepNesting() {
        let bomb = Data(repeating: 0x81, count: 100_000) + Data([0x00])
        #expect(throws: CBORError.self) { try CBORDecoder.decode(bomb) }

        let atTheLimit =
            Data(repeating: 0x81, count: SyncLimits.maximumWireNestingDepth) + Data([0x00])
        #expect(throws: Never.self) { try CBORDecoder.decode(atTheLimit) }
    }

    @Test("Refuses everything outside the subset")
    func refusesUnsupportedItems() throws {
        let outside = [
            "f97e00",  // half-precision NaN
            "fa47c35000",  // single-precision 100000.0
            "fb3ff199999999999a",  // double-precision 1.1
            "c11a514b67b0",  // tag 1, an epoch date/time
            "f7",  // undefined
            "f8ff",  // simple(255)
            "1c",  // reserved additional information 28
            "1e",  // reserved additional information 30
        ]
        for encoded in outside {
            #expect(throws: CBORError.self) { try CBORDecoder.decode(try bytes(encoded)) }
        }
    }

    @Test("Refuses truncated, invalid and duplicate-keyed bodies")
    func refusesMalformedBodies() throws {
        let malformed = [
            "",  // nothing at all
            "18",  // a one-byte argument that never arrives
            "1b0000",  // an eight-byte argument, truncated
            "4304",  // three declared bytes, one present
            "6301",  // three declared text bytes, one present
            "8201",  // two declared elements, one present
            "62c328",  // a text string that is not valid UTF-8
            "a2616101616102",  // {"a": 1, "a": 2} — invalid per RFC 8949 §5.6
            "0000",  // a complete item with a trailing byte
        ]
        for encoded in malformed {
            #expect(throws: CBORError.self) { try CBORDecoder.decode(try bytes(encoded)) }
        }
    }

    /// The negative-integer boundary, where `-1 - argument` overflows in one
    /// direction and the magnitude does in the other.
    @Test("Round-trips the integer extremes without trapping")
    func roundTripsIntegerExtremes() throws {
        for value in [Int64.min, Int64.min + 1, -1, 0, 1, Int64.max] {
            #expect(CBORValue.integer(value).integerValue == value)
            let decoded = try CBORDecoder.decode(try CBOREncoder.encode(.integer(value)))
            #expect(decoded.integerValue == value)
        }
        // -2^64 and 2^64-1 are representable in CBOR but not in Int64, and are
        // reported as out of range rather than wrapped.
        #expect(CBORValue.negative(UInt64.max).integerValue == nil)
        #expect(CBORValue.unsigned(UInt64.max).integerValue == nil)
    }
}
