import SkrepkaIPC

/// Which rows' pictures the picker has asked the daemon for, and which of those
/// to ask for again.
///
/// Each picture is asked for once, not once per redraw: the list redraws on
/// every keystroke of a search, and a picture can be sixteen megabytes of
/// base64 on the session bus. Past that, it depends on the answer:
///
/// - **Decoded.** Forgotten here: ``ThumbnailCache`` holds it, and the picker
///   checks the cache first. When the cache evicts it to make room, the row is
///   asked for again the next time it is drawn, rather than showing its
///   placeholder for good.
/// - **No picture.** A picture file read off disk can be missing for a while —
///   on a drive not mounted yet, or moved and moved back — and a daemon that
///   could not be reached may be reachable next time. Asked for again when the
///   picker next opens, which is when somebody is looking, and at most once an
///   opening.
/// - **Bytes that would not decode.** Never asked for again: the same bytes
///   meet the same GdkPixbuf loaders, which do not change while the process
///   runs. A WebP on a desktop with no WebP loader is the case this is for.
///
/// A request still waiting for its answer stays waiting across a reopening,
/// rather than being sent a second time: `PickerLink` answers every request
/// exactly once, in the order they were made, so one request per picture is
/// ever outstanding and an answer always belongs to the request it follows.
///
/// Pure, so the policy is tested without a daemon or a display.
struct PreviewRequests: Equatable {
    /// What an answer came to, as far as asking again is concerned.
    enum Answer: Equatable {
        case decoded
        case undecodable
        case noPicture

        /// `document`'s outcome, given whether its bytes decoded. Judged by
        /// the encoded field rather than `bytes`, which would decode sixteen
        /// megabytes of base64 a second time to learn that it is there.
        init(_ document: PreviewDocument, decoded: Bool) {
            self = decoded ? .decoded : (document.data == nil ? .noPicture : .undecodable)
        }
    }

    /// Asked for, and not answered yet.
    private(set) var pending: Set<String> = []
    /// Answered with no picture — to be asked for again at the next opening.
    private(set) var unanswered: Set<String> = []
    /// Answered with bytes no loader here can decode.
    private(set) var undecodable: Set<String> = []

    /// Whether `hash` should be asked for now. The caller checks the thumbnail
    /// cache first; this says nothing about a picture that is on screen.
    func needsAsking(_ hash: String) -> Bool {
        !pending.contains(hash) && !unanswered.contains(hash) && !undecodable.contains(hash)
    }

    /// These requests, with `hash` asked for.
    func asking(_ hash: String) -> PreviewRequests {
        PreviewRequests(pending: pending.union([hash]), unanswered: unanswered, undecodable: undecodable)
    }

    /// These requests, with `hash` answered.
    func answered(_ hash: String, _ answer: Answer) -> PreviewRequests {
        PreviewRequests(
            pending: pending.subtracting([hash]),
            unanswered: answer == .noPicture ? unanswered.union([hash]) : unanswered,
            undecodable: answer == .undecodable ? undecodable.union([hash]) : undecodable
        )
    }

    /// These requests as the picker opens again: everything answered without a
    /// picture may be asked for afresh.
    func reopened() -> PreviewRequests {
        PreviewRequests(pending: pending, unanswered: [], undecodable: undecodable)
    }
}
