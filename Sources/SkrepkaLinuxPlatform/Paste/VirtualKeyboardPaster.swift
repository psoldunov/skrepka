import CWaylandClient
import CWaylandProtocols
import Foundation

#if canImport(Glibc)
    import Glibc
#endif

public enum VirtualKeyboardPasteError: Error, CustomStringConvertible {
    case displayUnavailable
    case protocolUnavailable
    case seatUnavailable
    case keymapUnavailable
    case protocolError

    public var description: String {
        switch self {
        case .displayUnavailable: "the Wayland display could not be opened"
        case .protocolUnavailable: "the compositor stopped advertising virtual-keyboard-v1"
        case .seatUnavailable: "the compositor did not advertise a seat"
        case .keymapUnavailable: "a virtual-keyboard keymap could not be created"
        case .protocolError: "the compositor rejected the virtual keyboard"
        }
    }
}

/// Sends Ctrl+V through `zwp_virtual_keyboard_v1`.
public struct VirtualKeyboardPaster: Sendable {
    public static let keymap = """
        xkb_keymap {
        xkb_keycodes "skrepka" { minimum = 8; maximum = 255; <LCTL> = 37; <AB04> = 55; };
        xkb_types "skrepka" { include "complete" };
        xkb_compatibility "skrepka" { include "complete" };
        xkb_symbols "skrepka" {
          key <LCTL> { [ Control_L ] };
          key <AB04> { [ v, V ] };
          modifier_map Control { <LCTL> };
        };
        };
        """ + "\0"

    public init() {}

    public func paste(displayName: String?) throws {
        guard let display = wl_display_connect(displayName) else {
            throw VirtualKeyboardPasteError.displayUnavailable
        }
        defer { wl_display_disconnect(display) }
        let globals = try Globals.collect(display: display)
        guard let manager = globals.manager else { throw VirtualKeyboardPasteError.protocolUnavailable }
        defer { zwp_virtual_keyboard_manager_v1_destroy(manager) }
        guard let seat = globals.seat else { throw VirtualKeyboardPasteError.seatUnavailable }
        defer { wl_seat_destroy(seat) }
        guard let keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat) else {
            throw VirtualKeyboardPasteError.protocolError
        }
        defer { zwp_virtual_keyboard_v1_destroy(keyboard) }
        try uploadKeymap(to: keyboard)
        sendPaste(on: keyboard)
        guard wl_display_roundtrip(display) >= 0 else { throw VirtualKeyboardPasteError.protocolError }
    }

    private func uploadKeymap(to keyboard: OpaquePointer) throws {
        let bytes = Array(Self.keymap.utf8)
        let descriptor = bytes.withUnsafeBytes { raw in
            skrepka_keymap_memfd(raw.bindMemory(to: CChar.self).baseAddress, UInt32(bytes.count))
        }
        guard descriptor >= 0 else { throw VirtualKeyboardPasteError.keymapUnavailable }
        defer { close(descriptor) }
        zwp_virtual_keyboard_v1_keymap(keyboard, 1, descriptor, UInt32(bytes.count))
    }

    private func sendPaste(on keyboard: OpaquePointer) {
        let pressed: UInt32 = 1
        let released: UInt32 = 0
        let controlKey: UInt32 = 29
        let vKey: UInt32 = 47
        let controlMask: UInt32 = 4
        zwp_virtual_keyboard_v1_key(keyboard, 1, controlKey, pressed)
        zwp_virtual_keyboard_v1_modifiers(keyboard, controlMask, 0, 0, 0)
        zwp_virtual_keyboard_v1_key(keyboard, 2, vKey, pressed)
        zwp_virtual_keyboard_v1_key(keyboard, 3, vKey, released)
        zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0)
        zwp_virtual_keyboard_v1_key(keyboard, 4, controlKey, released)
    }
}

private final class Globals {
    var manager: OpaquePointer?
    var seat: OpaquePointer?

    static func collect(display: OpaquePointer) throws -> Globals {
        guard let registry = wl_display_get_registry(display) else {
            throw VirtualKeyboardPasteError.protocolError
        }
        defer { wl_registry_destroy(registry) }
        let globals = Globals()
        var listener = wl_registry_listener(
            global: { data, registry, name, interface, version in
                guard let data, let registry, let interface else { return }
                let globals = Unmanaged<Globals>.fromOpaque(data).takeUnretainedValue()
                globals.bind(
                    registry: registry, name: name, interface: String(cString: interface), version: version)
            },
            global_remove: { _, _, _ in }
        )
        let roundtrip = withUnsafePointer(to: &listener) { pointer in
            wl_registry_add_listener(registry, pointer, Unmanaged.passUnretained(globals).toOpaque())
            return wl_display_roundtrip(display)
        }
        guard roundtrip >= 0 else { throw VirtualKeyboardPasteError.protocolError }
        return globals
    }

    private func bind(registry: OpaquePointer, name: UInt32, interface: String, version: UInt32) {
        let isVirtualKeyboard = interface == PasteMechanism.virtualKeyboardGlobal
        if isVirtualKeyboard, let type = skrepka_virtual_keyboard_manager_interface() {
            manager = wl_registry_bind(registry, name, type, min(version, 1)).map(OpaquePointer.init)
            return
        }
        if interface == "wl_seat", let type = skrepka_wl_seat_interface() {
            seat = wl_registry_bind(registry, name, type, min(version, 1)).map(OpaquePointer.init)
        }
    }
}
