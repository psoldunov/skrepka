import AppKit
import ClippyCore
import CoreGraphics
import Foundation
import os

/// Puts an entry back on the pasteboard and, when permitted, pastes it into the
/// app that was frontmost before the picker opened.
@MainActor
struct PasteService {
    /// `kVK_ANSI_V` from Carbon's `Events.h`.
    private static let virtualKeyV: CGKeyCode = 0x09
    /// Activation is asynchronous; posting ⌘V before the target is frontmost
    /// sends it to the wrong app. Measured to be reliable at this delay.
    private static let activationDelay = Duration.milliseconds(80)

    enum Outcome {
        case pasted
        case copiedOnly(reason: String?)
    }

    /// Everything one paste needs.
    ///
    /// - `target` is the app that was frontmost when the picker opened.
    /// - `shouldPaste` is false when the user prefers to paste themselves.
    struct Request {
        let payload: ClipPayload
        let plainText: String
        let style: PasteStyle
        let sourceBundleID: String?
        let target: NSRunningApplication?
        let shouldPaste: Bool
    }

    func deliver(_ request: Request) async -> Outcome {
        write(request)

        guard request.shouldPaste else { return .copiedOnly(reason: nil) }
        guard AccessibilityPermission.isTrusted else {
            return .copiedOnly(reason: "Grant Accessibility permission to paste automatically.")
        }
        guard let target = request.target else {
            return .copiedOnly(reason: "Could not tell which app to paste into.")
        }

        target.activate(from: .current, options: [])
        try? await Task.sleep(for: Self.activationDelay)

        guard postCommandV() else {
            return .copiedOnly(reason: "Could not send the paste keystroke.")
        }
        return .pasted
    }

    // MARK: - Pasteboard

    private func write(_ request: Request) {
        let effective =
            request.style == .plainText
            ? request.payload.plainTextOnly(request.plainText)
            : request.payload
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        for (type, data) in effective.representations {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        // nspasteboard.org convention: name the app the content came from, so
        // other clipboard managers do not attribute restored content to Clippy.
        item.setString(
            request.sourceBundleID ?? "",
            forType: NSPasteboard.PasteboardType(PasteboardType.source)
        )
        pasteboard.writeObjects([item])
    }

    // MARK: - Synthetic keystroke

    /// `.cgSessionEventTap` rather than the HID tap: session-level posts land in
    /// the active login session and are less likely to be reordered against the
    /// activation that just happened.
    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            ClippyLog.paste.error("Could not create a CGEventSource.")
            return false
        }
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.virtualKeyV,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.virtualKeyV,
                keyDown: false
            )
        else {
            ClippyLog.paste.error("Could not create the paste key events.")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}
