import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// What this machine calls itself on the network.
///
/// The Linux answer to macOS's `Host.current().localizedName`, which has no
/// counterpart here — swift-corelibs-foundation ships `Host`, but its
/// `localizedName` is a Darwin-only nicety and `ProcessInfo.hostName` goes
/// through the same `gethostname(2)` this does with less control over the
/// failure.
///
/// Falls back rather than failing. The name is a human label and the identity
/// is the certificate hash in the TXT record, so a machine with no readable
/// hostname should still appear on the network — under a dull name.
public enum DeviceName {
    /// What a machine with no readable hostname is called.
    ///
    /// Matches the shape of the macOS fallback, which is `"Mac"`.
    public static let fallback = "Linux"

    /// `HOST_NAME_MAX` on Linux is 64, plus one for the terminator. Sized from
    /// the constant rather than a round number so the buffer cannot be the
    /// thing that truncates a name.
    static let bufferSize = 256

    /// This machine's hostname, with any domain part dropped.
    ///
    /// The domain is dropped because a DNS-SD service instance name is one
    /// label of at most 63 octets, and `desktop.example.internal` is both
    /// longer than the label a user recognises and misleading beside a peer
    /// called `MacBook Pro`. `ServiceDescriptor` clamps the length either way.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        // `HOSTNAME` is exported by some shells and is not authoritative —
        // consulted only because a container often has no other answer, and
        // checked after the syscall rather than before it.
        if let name = hostname(), !name.isEmpty { return shortened(name) }
        if let name = environment["HOSTNAME"], !name.isEmpty { return shortened(name) }
        return fallback
    }

    static func shortened(_ name: String) -> String {
        String(name.split(separator: ".").first ?? Substring(name))
    }

    private static func hostname() -> String? {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let written = buffer.withUnsafeMutableBufferPointer { raw -> Int32 in
            raw.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                    gethostname($0, raw.count)
                }
            } ?? -1
        }
        guard written == 0 else { return nil }
        // `gethostname` is not required to terminate the string when the name
        // exactly fills the buffer — POSIX says the result is unspecified in
        // that case — so the terminator is found rather than trusted, and a
        // name with none is treated as filling the buffer and truncated.
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        // Failable rather than lossy: a hostname whose bytes are not UTF-8 is
        // one this build cannot put in a DNS-SD instance name, and falling back
        // to ``fallback`` is a better answer than a name full of replacement
        // characters that no peer can type back.
        return String(bytes: buffer[..<end], encoding: .utf8)
    }
}
