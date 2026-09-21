import Foundation

/// File names a peer sent, made safe to create inside one directory.
///
/// A bundle's names are the sender's, verbatim — see
/// ``SkrepkaSync/FileBundle`` — and a paired peer is authenticated rather than
/// trusted. `../../.ssh/authorized_keys` must land as a file called
/// `authorized_keys` inside the directory it was given, never beside it.
public enum SafeFileName {
    /// Used for a name that has nothing usable left in it.
    public static let fallback = "file"

    /// Longest name, in UTF-8 bytes. `NAME_MAX` on both platforms' usual file
    /// systems; a longer name fails the write rather than being shortened.
    static let maximumBytes = 255

    /// One safe name per input, in order, none repeated.
    ///
    /// Repeats are compared case-insensitively, because the Mac's default
    /// volume is, and two files called `A.txt` and `a.txt` would be one there.
    public static func names(for names: [String]) -> [String] {
        var taken: Set<String> = []
        return names.map { name in
            let base = sanitized(name)
            var candidate = base
            var counter = 2
            while taken.contains(candidate.lowercased()) {
                candidate = numbered(base, counter)
                counter += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    /// The last path component of `name`, whichever separator the sender
    /// used, with control characters removed and `.`/`..` refused.
    public static func sanitized(_ name: String) -> String {
        let component =
            name
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let cleaned = String(
            String.UnicodeScalarView(
                component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
        )
        .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
        return truncated(cleaned)
    }

    /// `report.pdf` → `report 2.pdf`, the way Finder numbers a duplicate.
    /// A leading dot is not an extension, so `.bashrc` → `.bashrc 2`.
    ///
    /// The stem is shortened to make room for the number, never the number
    /// cut back off: a name already at ``maximumBytes`` would otherwise come
    /// back unchanged and collide for ever. An extension too long to keep
    /// beside a number is treated as part of the stem.
    static func numbered(_ name: String, _ counter: Int) -> String {
        let number = " \(counter)"
        var stem = Substring(name)
        var suffix = ""
        let dot = name.lastIndex(of: ".").flatMap { dot in
            dot != name.startIndex && name[dot...].utf8.count + number.utf8.count < maximumBytes ? dot : nil
        }
        if let dot {
            stem = name[..<dot]
            suffix = String(name[dot...])
        }
        let room = maximumBytes - number.utf8.count - suffix.utf8.count
        return truncated(String(stem), toBytes: room) + number + suffix
    }

    /// Cut on a character boundary to `limit` UTF-8 bytes.
    private static func truncated(_ name: String, toBytes limit: Int = maximumBytes) -> String {
        guard name.utf8.count > limit else { return name }
        var kept = ""
        for character in name {
            guard kept.utf8.count + String(character).utf8.count <= limit else { break }
            kept.append(character)
        }
        return kept
    }
}
