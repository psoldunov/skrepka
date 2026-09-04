import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// A field that records the next key combination the user presses.
///
/// Clippy's own rather than `KeyboardShortcuts.Recorder`: that view reaches
/// `Bundle.module` for its placeholder text, and a SwiftPM resource bundle
/// cannot be resolved from inside a signed `.app` — it trapped the moment
/// Settings opened on any machine but the one that built it. The library's own
/// documentation points at `isTakenBySystem` for exactly this, "building a
/// custom recorder UI".
struct ShortcutRecorderView: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    let onChange: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        ShortcutRecorderField(name: name, onChange: onChange)
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {
        nsView.onChange = onChange
    }
}

/// The AppKit control behind ``ShortcutRecorderView``.
@MainActor
final class ShortcutRecorderField: NSView {
    private static let size = NSSize(width: 128, height: 24)

    private let name: KeyboardShortcuts.Name
    var onChange: () -> Void

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var monitor: Any?
    private var rejection: String?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                startListening()
            } else {
                stopListening()
            }
            refresh()
        }
    }

    init(name: KeyboardShortcuts.Name, onChange: @escaping () -> Void) {
        self.name = name
        self.onChange = onChange
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        configure()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // NSView's designated initializer from a nib. This control is only ever
        // built in code, so there is nothing to decode.
        nil
    }

    /// Teardown happens here, not in `deinit`.
    ///
    /// `deinit` is nonisolated and cannot touch the monitor, and cleaning up
    /// matters for more than the monitor: recording disables Clippy's global
    /// hotkey, so a field torn down mid-recording would leave the app with no
    /// working shortcut at all. Losing the window is the one teardown that is
    /// guaranteed to happen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isRecording = false
        }
    }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: - Layout

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.bezelStyle = .accessoryBarAction
        clearButton.isBordered = false
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear shortcut"
        )
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
        ])

        // A role alone does not make a plain NSView visible to assistive
        // technology — without `setAccessibilityElement(true)` the field is not
        // an element at all, and VoiceOver lands on the text field inside it
        // instead, which cannot start recording.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut")
        // The label's text is republished as this field's value, so leaving it
        // exposed would make VoiceOver read the shortcut twice.
        label.setAccessibilityElement(false)
        clearButton.setAccessibilityLabel("Clear shortcut")
    }

    private func refresh() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        label.stringValue = displayString(for: shortcut)
        label.textColor = isRecording || shortcut == nil ? .secondaryLabelColor : .labelColor
        clearButton.isHidden = isRecording || shortcut == nil
        layer?.backgroundColor =
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .clear).cgColor
        layer?.borderColor =
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        setAccessibilityValue(label.stringValue)
        toolTip = rejection
    }

    private func displayString(for shortcut: KeyboardShortcuts.Shortcut?) -> String {
        if let rejection { return rejection }
        if isRecording { return "Press keys…" }
        guard let shortcut else { return "Click to record" }
        return ShortcutFormatter.string(for: shortcut)
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        toggleRecording()
    }

    /// Assistive technology activates the field through this, not `mouseDown`.
    ///
    /// The view claims `NSAccessibility.Role.button`, and a control that claims
    /// a role owes that role's action — without this, VoiceOver could see the
    /// field and read its value but never start recording.
    override func accessibilityPerformPress() -> Bool {
        toggleRecording()
        return true
    }

    private func toggleRecording() {
        window?.makeFirstResponder(self)
        rejection = nil
        isRecording.toggle()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    /// Watches key events while recording.
    ///
    /// A local monitor rather than `keyDown`: a bare letter would otherwise
    /// reach the menu bar as a key equivalent, and a monitor sees the event
    /// before that happens. Clippy's own global hotkey is suspended for the
    /// duration, so pressing it to rebind it does not open the picker instead.
    private func startListening() {
        KeyboardShortcuts.isEnabled = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, isRecording else { return event }
            return handle(event) ? nil : event
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        KeyboardShortcuts.isEnabled = true
    }

    /// - Returns: true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Modifiers alone are not a shortcut; swallow them so the field does
        // not flicker a half-typed combination.
        guard event.type == .keyDown else { return true }

        if Self.isCancel(event) {
            isRecording = false
            return true
        }
        if Self.isClear(event) {
            apply(nil)
            return true
        }
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return true }
        guard !shortcut.isTakenBySystem else {
            rejection = "\(ShortcutFormatter.string(for: shortcut)) is used by macOS"
            refresh()
            return true
        }
        apply(shortcut)
        return true
    }

    /// Bare Escape cancels. With a modifier it is a shortcut like any other,
    /// so ⌥⎋ still records.
    private static func isCancel(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape) else { return false }
        return event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
    }

    /// Either delete key clears the shortcut, the way a system recorder does.
    private static func isClear(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)
    }

    private func apply(_ shortcut: KeyboardShortcuts.Shortcut?) {
        rejection = nil
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        isRecording = false
        refresh()
        onChange()
    }

    @objc private func clear() {
        apply(nil)
    }
}
