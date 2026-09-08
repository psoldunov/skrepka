import CX11
import Foundation

/// Reading and writing X11 window properties, with the unit conversions in one
/// place.
///
/// `XGetWindowProperty` mixes units in a single call — the Xlib manual defines
/// the read as starting at `4 * long_offset` bytes and running for
/// `MINIMUM(T, 4 * long_length)`, while `bytes_after_return` is in bytes. And
/// format 32 means a client-side **`long`** array, not a 32-bit one: the Xlib
/// manual says "if the specified format is 32, the property data must be a long
/// array", so on any 64-bit machine a `[Int32]` is half garbage with no error
/// reported. Both mistakes are silent, which is why neither call appears
/// anywhere else in this target.
enum XProperty {
    /// One property, read whole.
    struct Value {
        let type: Atom
        let format: Int32
        let bytes: Data
    }

    /// Reads a property in full, deleting it afterwards when asked.
    ///
    /// Two calls, which is the idiom both `xclip` and `xsel` use: a zero-length
    /// probe to learn the type and the size, then one read of exactly that
    /// size. Asking for a guessed length instead either truncates or wastes a
    /// round trip on every small clipping.
    static func read(
        display: OpaquePointer,
        window: Window,
        property: Atom,
        delete: Bool
    ) -> Value? {
        var actualType: Atom = 0
        var actualFormat: Int32 = 0
        var itemCount: UInt = 0
        var bytesAfter: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?

        // Rounded up: the length is in 32-bit words and a three-byte property
        // still needs a whole one.
        guard let byteCount = size(display: display, window: window, property: property) else {
            return nil
        }
        let words = Int(byteCount + 3) / 4
        guard
            XGetWindowProperty(
                display,
                window,
                property,
                0,
                words,
                delete ? 1 : 0,
                X11.anyPropertyType,
                &actualType,
                &actualFormat,
                &itemCount,
                &bytesAfter,
                &data
            ) == Success, let data
        else { return nil }
        defer { XFree(data) }

        let bytesPerItem = Int(actualFormat) / 8
        // Format 32 is a `long` client-side, so its items are eight bytes wide
        // here even though the wire carries four.
        let stride = actualFormat == 32 ? MemoryLayout<Int>.size : max(bytesPerItem, 1)
        return Value(
            type: actualType,
            format: actualFormat,
            bytes: Data(bytes: data, count: Int(itemCount) * stride)
        )
    }

    /// How many bytes a property holds, via the zero-length probe.
    ///
    /// Separate from ``read(display:window:property:delete:)`` so neither
    /// function carries two `XGetWindowProperty` calls with twelve arguments
    /// each — the repository's function-length budget is what forced the split,
    /// and the seam is the right one anyway: this is the only call whose
    /// answer is a size rather than a value.
    private static func size(display: OpaquePointer, window: Window, property: Atom) -> UInt? {
        var actualType: Atom = 0
        var actualFormat: Int32 = 0
        var itemCount: UInt = 0
        var bytesAfter: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        defer { XFree(data) }
        guard
            XGetWindowProperty(
                display,
                window,
                property,
                0,
                0,
                0,
                X11.anyPropertyType,
                &actualType,
                &actualFormat,
                &itemCount,
                &bytesAfter,
                &data
            ) == Success
        else { return nil }
        return bytesAfter
    }

    /// The atoms in a property that holds a list of them.
    ///
    /// Format 32, so the items are `long` and reading them as anything narrower
    /// returns every other one interleaved with zeroes.
    static func atoms(in value: Value) -> [Atom] {
        guard value.format == 32 else { return [] }
        return value.bytes.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int.self)).map(Atom.init(bitPattern:))
        }
    }

    /// The first `long` in a property — a `TIMESTAMP` reply, or an `INCR`
    /// size hint.
    static func firstWord(in value: Value) -> Int? {
        guard value.format == 32, value.bytes.count >= MemoryLayout<Int>.size else { return nil }
        return value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Int.self) }
    }

    /// Writes a list of atoms as format 32.
    static func write(
        atoms: [Atom],
        display: OpaquePointer,
        window: Window,
        property: Atom,
        type: Atom
    ) {
        // Format 32 means a client-side `long`, not a 32-bit integer: the
        // Xlib manual says "if the specified format is 32, the property data
        // must be a long array". On LP64 that is `Int`, and passing `[Int32]`
        // here produces a property that is half garbage with no error reported.
        let words = atoms.map(Int.init(bitPattern:))
        words.withUnsafeBytes { buffer in
            _ = XChangeProperty(
                display,
                window,
                property,
                type,
                32,
                PropModeReplace,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                Int32(atoms.count)
            )
        }
    }

    /// Writes raw bytes as format 8.
    static func write(
        bytes: Data,
        display: OpaquePointer,
        window: Window,
        property: Atom,
        type: Atom,
        mode: Int32 = PropModeReplace
    ) {
        bytes.withUnsafeBytes { buffer in
            _ = XChangeProperty(
                display,
                window,
                property,
                type,
                8,
                mode,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                Int32(bytes.count)
            )
        }
    }

    /// Largest payload one `XChangeProperty` may carry, in bytes.
    ///
    /// `XMaxRequestSize` and `XExtendedMaxRequestSize` both return **4-byte
    /// units** — the Xlib manual says so for each — and `XChangeProperty` is on
    /// the manual's own list of calls that use the extended encoding when the
    /// server supports it, so the extended size is the right ceiling whenever
    /// it is non-zero. `sz_xChangePropertyReq` is 24, verified against the
    /// installed `/usr/include/X11/Xproto.h`.
    ///
    /// Capped well below that ceiling, per ICCCM §2.5: "clients should use a
    /// sequence of ChangeProperty (mode==Append) requests for reasonable
    /// quantities of data. This avoids locking servers up and limits the waste
    /// of data an Alloc error would cause." 256 KiB is the same slice
    /// ``SkrepkaSync/SyncLimits/payloadChunkBytes`` uses on the wire.
    static func maximumChunkBytes(display: OpaquePointer) -> Int {
        let words =
            XExtendedMaxRequestSize(display) > 0
            ? XExtendedMaxRequestSize(display)
            : XMaxRequestSize(display)
        let headerBytes = 24
        let available = Int(words) * 4 - headerBytes
        return max(4096, min(available, 256 * 1024))
    }
}
