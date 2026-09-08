import CX11
import Foundation

@testable import SkrepkaLinuxPlatform

#if canImport(Glibc)
    import Glibc
#endif

/// A direct Xlib requestor for the `MULTIPLE` target.
///
/// `xclip` and `xsel` never issue one — they convert a single target per
/// invocation — so the pair-rewriting half of
/// ``XClipboardSession/handleMultiple(_:property:)`` has no outside tool that
/// can reach it. This is the smallest client that can: its own display
/// connection, its own unmapped `InputOnly` window, and one `ATOM_PAIR`
/// property naming two conversions.
///
/// It uses ``XProperty`` for the raw property plumbing rather than calling
/// `XGetWindowProperty` again here. That call mixes three units in one
/// signature and format 32 means a client-side `long`, both of which
/// ``XProperty`` already gets right and documents; reproducing it would add a
/// second place to get the widths wrong. What the test asserts is unaffected by
/// that choice — the refusal marker is `None`, which is zero at any width, and
/// the served bytes come back as format 8.
///
/// Not `Sendable`, and deliberately: like every other Xlib user in this
/// repository it is confined to the thread that built it.
final class XMultipleRequestor {
    /// What one `MULTIPLE` conversion produced.
    struct Outcome {
        /// The `ATOM_PAIR` list as the owner left it — the odd entries are the
        /// property atoms, rewritten to `X11.none` where the owner refused.
        let pairs: [Atom]
        /// Whatever landed on the property named for the target that Skrepka
        /// does serve.
        let servedBytes: Data
        /// The property the owner named in its `SelectionNotify`. `X11.none`
        /// is the protocol's only refusal.
        let repliedProperty: Atom

        /// The property atom left against the target the owner does serve.
        /// `nil` when the list did not come back as the four atoms sent.
        var servedPropertyAtom: Atom? { pairs.count == 4 ? pairs[1] : nil }
        /// The property atom left against the target it cannot serve. ICCCM
        /// §2.6.2 requires this to be `None`.
        var unservedPropertyAtom: Atom? { pairs.count == 4 ? pairs[3] : nil }
    }

    enum Failure: Error {
        case cannotOpenDisplay(String)
        case noSelectionNotify
    }

    /// A target no atom in `XAtoms.swift` names and no payload this test sets
    /// ever offers, so the owner cannot possibly convert it.
    static let unservableTargetName = "SKREPKA_TEST_UNSERVABLE_TARGET"

    private let display: OpaquePointer
    private let window: Window
    private let clipboard: Atom
    private let multiple: Atom
    private let atomPair: Atom
    /// Where the `ATOM_PAIR` list itself lives, on our own window.
    private let requestProperty: Atom
    /// The two destinations the pairs name. Exposed so a test can assert the
    /// owner left one of them alone and replaced the other.
    let servedProperty: Atom
    let unservedProperty: Atom

    init(displayName: String) throws {
        guard let display = XOpenDisplay(displayName) else {
            throw Failure.cannotOpenDisplay(displayName)
        }
        self.display = display

        // InputOnly, 1×1, never mapped: nothing is drawn and nothing is shown.
        // Properties are stored on the window resource regardless of class, so
        // this is enough to receive a selection reply.
        var attributes = XSetWindowAttributes()
        window = XCreateWindow(
            display,
            XDefaultRootWindow(display),
            0,  // x
            0,  // y
            1,  // width
            1,  // height
            0,  // border width
            0,  // depth: CopyFromParent, which InputOnly requires
            UInt32(InputOnly),
            nil,  // visual: CopyFromParent
            0,  // value mask: no attributes are set
            &attributes
        )

        func intern(_ name: String) -> Atom { XInternAtom(display, name, 0) }
        clipboard = intern("CLIPBOARD")
        multiple = intern("MULTIPLE")
        atomPair = intern("ATOM_PAIR")
        requestProperty = intern("SKREPKA_TEST_MULTIPLE")
        servedProperty = intern("SKREPKA_TEST_SERVED")
        unservedProperty = intern("SKREPKA_TEST_UNSERVED")
    }

    deinit {
        XDestroyWindow(display, window)
        XCloseDisplay(display)
    }

    /// The atom for a target name, on this connection.
    func atom(named name: String) -> Atom { XInternAtom(display, name, 0) }

    /// Issues one `MULTIPLE` request for two pairs and reads the answer back.
    ///
    /// - Parameters:
    ///   - servedTarget: a target the owner does convert.
    ///   - unservableTarget: one it cannot.
    func requestMultiple(
        servedTarget: Atom,
        unservableTarget: Atom,
        timeout: Duration = .seconds(5)
    ) throws -> Outcome {
        for property in [requestProperty, servedProperty, unservedProperty] {
            XDeleteProperty(display, window, property)
        }
        XProperty.write(
            atoms: [servedTarget, servedProperty, unservableTarget, unservedProperty],
            display: display,
            window: window,
            property: requestProperty,
            type: atomPair
        )

        // `CurrentTime` rather than a real server timestamp: ICCCM discourages
        // it for production requestors, and the owner's own §2.2 range check
        // admits it by name, so it is the honest shape for a fixture that has
        // no event of its own to quote.
        XConvertSelection(
            display, clipboard, multiple, requestProperty, window, Time(CurrentTime)
        )
        XFlush(display)

        guard let notify = try waitForSelectionNotify(timeout: timeout) else {
            throw Failure.noSelectionNotify
        }
        return readOutcome(repliedProperty: notify.property)
    }

    /// The reply the owner owes us, or nil if none arrived in time.
    ///
    /// `XCheckTypedWindowEvent` flushes the output buffer and returns false
    /// when the queue is empty, so this polls rather than blocking on
    /// `XNextEvent` — a blocked read would hang the whole suite if the owner
    /// never answered.
    private func waitForSelectionNotify(timeout: Duration) throws -> XSelectionEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var event = XEvent()
        while ContinuousClock.now < deadline {
            if XCheckTypedWindowEvent(display, window, SelectionNotify, &event) != 0 {
                return event.xselection
            }
            usleep(20_000)
        }
        return nil
    }

    private func readOutcome(repliedProperty: Atom) -> Outcome {
        let pairs =
            XProperty.read(
                display: display, window: window, property: requestProperty, delete: false
            )
            .map(XProperty.atoms(in:)) ?? []
        let served =
            XProperty.read(
                display: display, window: window, property: servedProperty, delete: false
            )?
            .bytes ?? Data()
        return Outcome(pairs: pairs, servedBytes: served, repliedProperty: repliedProperty)
    }
}
