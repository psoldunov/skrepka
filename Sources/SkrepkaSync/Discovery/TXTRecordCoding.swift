import Foundation

// MARK: - Encoding

extension TXTRecord {
    /// The RFC 6763 §6.1 wire form: each entry a single length octet followed
    /// by that many bytes of `key=value`.
    ///
    /// This is what `DNSServiceRegister` takes as its `txtRecord` argument, and
    /// what `NWTXTRecord.init(_: Data)` parses.
    public var dnsSDWireFormat: Data {
        var encoded = Data()
        for entry in entries {
            let bytes = entry.rawBytes
            // Safe without a check: `Entry.init` refuses anything over
            // `maximumEntryBytes`, which is 255.
            encoded.append(UInt8(truncatingIfNeeded: bytes.count))
            encoded.append(contentsOf: bytes)
        }
        return encoded
    }

    /// What `org.freedesktop.Avahi.EntryGroup.AddService` takes as its `txt`
    /// argument, whose D-Bus signature is `aay`.
    ///
    /// The same bytes as ``dnsSDWireFormat`` with the length prefixes removed
    /// and the entries left as separate arrays — avahi adds the prefixes
    /// itself. Phase 6 calls this.
    public var avahiEntries: [[UInt8]] {
        entries.map(\.rawBytes)
    }
}

// MARK: - Decoding

extension TXTRecord {
    /// Reads the RFC 6763 §6.1 wire form.
    ///
    /// Tolerant exactly where the specification says to be. §6.4 tells a client
    /// to ignore a zero-length entry and one whose key is empty because it
    /// began with `=`, so those are dropped rather than thrown; a length octet
    /// that runs off the end of the record is structural corruption and throws
    /// ``TXTRecordError/truncated``.
    public init(dnsSDWireFormat data: Data) throws {
        var decoded: [Entry] = []
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else {
                throw TXTRecordError.truncated
            }
            if let entry = try TXTRecord.entry(fromRawBytes: Array(data[index..<end])) {
                decoded.append(entry)
            }
            index = end
        }
        self.init(received: decoded)
    }

    /// Reads avahi's `aay` form, where the entries arrive already separated and
    /// carry no length prefixes.
    public init(avahiEntries: [[UInt8]]) throws {
        var decoded: [Entry] = []
        for bytes in avahiEntries {
            if let entry = try TXTRecord.entry(fromRawBytes: bytes) {
                decoded.append(entry)
            }
        }
        self.init(received: decoded)
    }

    /// Decodes one `key=value` byte string.
    ///
    /// `nil` where RFC 6763 §6.4 says to ignore the entry rather than reject
    /// the record: a zero-length string, or one whose key is empty.
    static func entry(fromRawBytes bytes: [UInt8]) throws -> Entry? {
        guard !bytes.isEmpty else { return nil }
        let separator = bytes.firstIndex(of: UInt8(ascii: "="))
        let keyBytes = separator.map { Array(bytes[..<$0]) } ?? bytes
        guard !keyBytes.isEmpty else { return nil }

        // Decoded leniently on purpose: bytes that are not UTF-8 become
        // replacement characters, which then fail `validate(key:)` as
        // non-printable. One error case instead of two, and the key is still
        // legible enough to name in the message.
        //
        // The rule below wants the failable initializer so invalid bytes cannot
        // pass silently. Nothing passes here — U+FFFD encodes as EF BF BD, and
        // `validate(key:)` rejects every byte above 0x7E — so the lossy decode
        // buys a nameable key on the error path and loses nothing.
        // swiftlint:disable:next optional_data_string_conversion
        let key = String(decoding: keyBytes, as: UTF8.self)
        let value = separator.map { Array(bytes[bytes.index(after: $0)...]) }
        return try Entry(key: key, value: value)
    }
}
