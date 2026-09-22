/// Which rows' pictures the picker has asked the daemon for, and which of those
/// to ask for again.
///
/// Each picture is asked for once, not once per redraw: the list redraws on
/// every keystroke of a search, and a picture can be sixteen megabytes of
/// base64 on the session bus. But an answer with no picture in it is not
/// final. A picture file read off disk can be missing for a while — on a drive
/// not mounted yet, or moved and moved back — and a daemon that did not answer
/// at all may answer next time. Those are asked for again when the picker next
/// opens, which is when somebody is looking, and at most once an opening.
///
/// Bytes that arrived and would not decode are the exception, and are not
/// asked for again: the same bytes meet the same GdkPixbuf loaders, which do
/// not change while the process runs. A WebP on a desktop with no WebP loader
/// is the case this is for.
///
/// Pure, so the policy is tested without a daemon or a display.
struct PreviewRequests: Equatable {
    /// Asked for this opening, or answered for good.
    private(set) var asked: Set<String> = []
    /// Asked for, and answered with no picture — to be asked for again.
    private(set) var unanswered: Set<String> = []

    /// Whether `hash` should be asked for now.
    func needsAsking(_ hash: String) -> Bool {
        !asked.contains(hash)
    }

    /// These requests, with `hash` asked for.
    func asking(_ hash: String) -> PreviewRequests {
        PreviewRequests(asked: asked.union([hash]), unanswered: unanswered.subtracting([hash]))
    }

    /// These requests, with `hash` answered. Without a picture — the daemon
    /// had none to send, or could not be reached — it is asked for again at
    /// the next opening. With one it is settled, whether or not it decodes.
    func answered(_ hash: String, withPicture: Bool) -> PreviewRequests {
        guard !withPicture else { return self }
        return PreviewRequests(asked: asked, unanswered: unanswered.union([hash]))
    }

    /// These requests as the picker opens again: everything answered without a
    /// picture is asked for afresh.
    func reopened() -> PreviewRequests {
        PreviewRequests(asked: asked.subtracting(unanswered), unanswered: [])
    }
}
