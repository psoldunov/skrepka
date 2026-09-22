# Skrepka Clipboard Capture

GNOME/Mutter does not expose either Wayland data-control protocol to ordinary
clients. This small GNOME Shell extension therefore watches the compositor's
clipboard selection and sends supported representations to the local
`skrepkad` process over the user's session D-Bus.

It has no UI, settings, telemetry, direct network access, subprocesses or data
store. Capture rules, privacy checks, exclusions, de-duplication and retention
remain in the daemon. The extension reads only Skrepka's supported clipboard
formats and only the normal clipboard, never the primary selection.

The Skrepka release installer places these files in:

```text
~/.local/share/gnome-shell/extensions/skrepka@dev.soldunov/
```

On a first install, GNOME Wayland must be logged out and back in once so Shell
can discover the new extension. The installer enables it for that next session.
Later upgrades reload it in place when the running Shell already knows it, and
preserve a user's decision to disable it.

Manual controls:

```sh
gnome-extensions enable skrepka@dev.soldunov
gnome-extensions disable skrepka@dev.soldunov
gnome-extensions info skrepka@dev.soldunov
```

GNOME Shell 46–50 are supported. KDE, Sway, other data-control compositors and
X11 use Skrepka's native clipboard backends and do not load this extension.

The extension has only run in the headless Ubuntu 26.04 / GNOME Shell 50
session that `scripts/gnome-smoke.sh` starts in a container, where it captures
text, images and files. It has not yet run on a real GNOME machine.
