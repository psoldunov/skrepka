import Foundation

/// A read cursor over a `Data`, which is the only place in the decoder that
/// touches an index.
///
/// It exists so bounds checking happens once, in one place, rather than at
/// every call site that could get it wrong. `Data` slices do not start at zero,
/// so every offset here is absolute; a decoder that assumes `startIndex == 0`
/// reads the wrong bytes the first time a slice reaches it, silently.
struct ByteCursor {
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    var remaining: Int { data.endIndex - index }

    var isAtEnd: Bool { remaining == 0 }

    /// Where the cursor is, absolutely, for a caller that has to look back at
    /// the bytes an item occupied once it knows where the item ended.
    var position: Int { index }

    /// The bytes between a ``position`` taken earlier and the cursor now.
    ///
    /// Slices share storage, so this costs nothing to take. It exists so
    /// ``CBORDecoder`` can compare two map keys by their *encodings*, which is
    /// the order RFC 8949 §4.2.1 sorts them in, rather than by re-encoding the
    /// values it just decoded.
    ///
    /// The guard is unreachable — the only marks handed here come from this
    /// cursor, which never moves backwards — and is a bounds check rather than
    /// a trap because a decoder that crashes on a hostile body is the failure
    /// this whole type exists to prevent.
    func bytes(from position: Int) -> Data {
        guard position >= data.startIndex, position <= index else { return Data() }
        return data[position..<index]
    }

    mutating func takeByte() throws -> UInt8 {
        guard remaining >= 1 else { throw CBORError.truncated }
        defer { index += 1 }
        return data[index]
    }

    /// Returns the next `count` bytes as a slice, sharing storage.
    ///
    /// `count` reaches here straight off the wire, so it is bounded against
    /// what the buffer actually holds *before* it is added to the index. That
    /// ordering is the whole point of this type: a declared length of 2^44 is
    /// nine bytes to write and must cost nothing to refuse.
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0 else { throw CBORError.truncated }
        guard count <= remaining else {
            throw CBORError.lengthExceedsBuffer(declared: UInt64(count), remaining: remaining)
        }
        defer { index += count }
        return data[index..<(index + count)]
    }

    /// Converts a wire-supplied argument into a byte count this platform can
    /// index, and bounds it against the buffer.
    ///
    /// Never `reserveCapacity` on the result of this without also having read
    /// the bytes: the bound proves the bytes exist, and that is what makes the
    /// allocation safe.
    func boundedCount(_ argument: UInt64) throws -> Int {
        guard let count = Int(exactly: argument) else {
            throw CBORError.lengthUnrepresentable(declared: argument)
        }
        guard count <= remaining else {
            throw CBORError.lengthExceedsBuffer(declared: argument, remaining: remaining)
        }
        return count
    }
}
