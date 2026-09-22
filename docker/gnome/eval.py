#!/usr/bin/env python3
"""Evaluate JavaScript in GNOME Shell and print its returned string."""

import json
import sys

# PyGObject is installed in the image, not on the macOS host.
# pyright: reportMissingImports=false
from gi.repository import Gio, GLib

if len(sys.argv) != 2:
    raise SystemExit("usage: skrepka-gnome-eval JAVASCRIPT")

connection = Gio.bus_get_sync(Gio.BusType.SESSION)
reply = connection.call_sync(
    "org.gnome.Shell",
    "/org/gnome/Shell",
    "org.gnome.Shell",
    "Eval",
    GLib.Variant("(s)", (sys.argv[1],)),
    GLib.VariantType("(bs)"),
    Gio.DBusCallFlags.NONE,
    10_000,
    None,
)
success, result = reply.unpack()
if not success:
    print(result, file=sys.stderr)
    raise SystemExit(1)
try:
    value = json.loads(result)
except json.JSONDecodeError:
    print(result)
else:
    print(value if isinstance(value, str) else json.dumps(value))
