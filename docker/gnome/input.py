#!/usr/bin/env python3
"""Inject keyboard or pointer input through Mutter's Clutter virtual devices."""

import json
import sys

# PyGObject is installed in the image, not on the macOS host.
# pyright: reportMissingImports=false
import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib  # noqa: E402

USAGE = "usage: skrepka-gnome-input key MOD+KEY | type TEXT | click X Y [primary|secondary]"


def evaluate(script: str) -> None:
    connection = Gio.bus_get_sync(Gio.BusType.SESSION)
    reply = connection.call_sync(
        "org.gnome.Shell",
        "/org/gnome/Shell",
        "org.gnome.Shell",
        "Eval",
        GLib.Variant("(s)", (script,)),
        GLib.VariantType("(bs)"),
        Gio.DBusCallFlags.NONE,
        10_000,
        None,
    )
    success, result = reply.unpack()
    if not success:
        raise SystemExit(result)


def keyval(name: str) -> int:
    aliases = {
        "ctrl": "Control_L",
        "control": "Control_L",
        "alt": "Alt_L",
        "shift": "Shift_L",
        "super": "Super_L",
        "meta": "Super_L",
        "esc": "Escape",
        "return": "Return",
        "enter": "Return",
        "space": "space",
    }
    value = Gdk.keyval_from_name(aliases.get(name.lower(), name))
    if value == 0 and len(name) == 1:
        value = Gdk.unicode_to_keyval(ord(name))
    if value == 0:
        raise SystemExit(f"unknown key: {name}")
    return value


def send_key(names: list[str]) -> None:
    # Linux input-event codes, verified in the image's linux/input-event-codes.h.
    # notify_key takes hardware codes; notify_keyval is kept for text below.
    codes = {
        "esc": 1, "escape": 1, "tab": 15, "return": 28, "enter": 28,
        "ctrl": 29, "control": 29, "shift": 42, "v": 47, "alt": 56,
        "space": 57, "super": 125, "meta": 125,
    }
    try:
        values = [codes[name.lower()] for name in names]
    except KeyError as error:
        raise SystemExit(f"unsupported physical key: {error.args[0]}") from error
    evaluate(f"""(async () => {{
const Clutter = imports.gi.Clutter;
const GLib = imports.gi.GLib;
const device = global.stage.context.get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
const keys = {json.dumps(values)};
const events = keys.map(k => [k, Clutter.KeyState.PRESSED]).concat([...keys].reverse().map(k => [k, Clutter.KeyState.RELEASED]));
for (const [key, state] of events) {{
    device.notify_key(GLib.get_monotonic_time(), key, state);
    await new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, 40, () => {{ resolve(); return GLib.SOURCE_REMOVE; }}));
}}
return "sent";
}})()""")


def type_text(text: str) -> None:
    values = [Gdk.unicode_to_keyval(ord(character)) for character in text]
    evaluate(f"""(async () => {{
const Clutter = imports.gi.Clutter;
const GLib = imports.gi.GLib;
const device = global.stage.context.get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
const keys = {json.dumps(values)};
const events = keys.flatMap(k => [[k, Clutter.KeyState.PRESSED], [k, Clutter.KeyState.RELEASED]]);
for (const [key, state] of events) {{
    device.notify_keyval(GLib.get_monotonic_time(), key, state);
    await new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, 15, () => {{ resolve(); return GLib.SOURCE_REMOVE; }}));
}}
return "sent";
}})()""")


def click(x: int, y: int, button: str = "primary") -> None:
    clutter_button = {
        "primary": "BUTTON_PRIMARY",
        "secondary": "BUTTON_SECONDARY",
    }.get(button)
    if clutter_button is None:
        raise SystemExit(USAGE)
    evaluate(f"""(async () => {{
const Clutter = imports.gi.Clutter;
const GLib = imports.gi.GLib;
const wait = ms => new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {{ resolve(); return GLib.SOURCE_REMOVE; }}));
const device = global.stage.context.get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
device.notify_absolute_motion(GLib.get_monotonic_time(), {x}, {y});
await wait(60);
device.notify_button(GLib.get_monotonic_time(), Clutter.{clutter_button}, Clutter.ButtonState.PRESSED);
await wait(60);
device.notify_button(GLib.get_monotonic_time(), Clutter.{clutter_button}, Clutter.ButtonState.RELEASED);
return "sent";
}})()""")


if len(sys.argv) < 3:
    raise SystemExit(USAGE)
command = sys.argv[1]
if command == "key" and len(sys.argv) == 3:
    send_key(sys.argv[2].split("+"))
elif command == "type" and len(sys.argv) == 3:
    type_text(sys.argv[2])
elif command == "click" and len(sys.argv) in (4, 5):
    try:
        coordinates = (int(sys.argv[2]), int(sys.argv[3]))
    except ValueError as error:
        raise SystemExit(USAGE) from error
    click(*coordinates, *(sys.argv[4:] or ["primary"]))
else:
    raise SystemExit(USAGE)
