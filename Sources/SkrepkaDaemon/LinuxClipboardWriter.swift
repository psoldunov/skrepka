import Foundation
import SkrepkaSync

/// Wire-keyed payload bytes as the targets a Linux selection is offered under.
///
/// The counterpart of `RepresentationKeyMap.utiKeyed(_:)`, which does the same
/// job for a macOS pasteboard, and it lives here for the same reason that one
/// lives in the map: there is more than one caller — the live-push write today,
/// and `skrepka copy` — and two spellings of one mapping is how they drift.
///
/// ## Keyed off `canonical`, never off `origin`
///
/// A ``SkrepkaSync/RepresentationKey`` carries the sender's own name for the
/// representation in `origin`, which is a macOS uniform type identifier when
/// the sender was a Mac. Offering `public.utf8-plain-text` as an X11 selection
/// target or a Wayland MIME type would advertise something no Linux application
/// asks for, and the paste would come back empty with nothing saying why.
///
/// ## What is dropped, and why that is right
///
/// A key `RepresentationKeyMap` has no Linux target for is left out rather than
/// offered under an invented name. The map refusing to name it means no Linux
/// application would know to ask for it, and a target advertised with bytes
/// nothing can read is worse than one that was never offered — a toolkit that
/// picks the richest target it recognises would pick that one.
public enum LinuxClipboardWriter {
    /// The selection to offer, or an empty dictionary when nothing here can be.
    ///
    /// Empty is a real answer and the caller must check it: setting a selection
    /// with no targets claims the clipboard and serves nothing, which loses
    /// whatever was on it.
    public static func targets(for payloads: [RepresentationKey: Data]) -> [String: Data] {
        var targets: [String: Data] = [:]
        for (key, data) in payloads {
            guard !data.isEmpty,
                let target = RepresentationKeyMap.linuxTarget(forCanonical: key.canonical)
            else { continue }
            // First writer wins. Two wire keys mapping to one target would be a
            // bug in the map rather than something to resolve here, and
            // overwriting would make which bytes survive depend on dictionary
            // order.
            if targets[target] == nil { targets[target] = data }
        }
        return targets
    }
}
