# Phase 8 — GNOME support, and packaging

**A week of work, plus review latency nobody controls.**

## Goal

A package that installs on Ubuntu and Fedora, starts under systemd, pairs with
the Mac from a clean install — and works on GNOME.

## Preconditions

- Phase 7 done, or deliberately skipped in favour of the CLI.
- [D-5](open-questions.md#d-5) is settled: **ship the extension, kept as thin as
  possible.** GNOME is the most common Linux desktop and excluding it excludes
  most of the audience, so the second JavaScript codebase and its review queue
  are an accepted standing cost rather than an open question.
- [OQ-3](open-questions.md#oq-3) answered if the portal path is being
  reconsidered at all.

## Why GNOME needs its own phase

GNOME/Mutter implements **neither** `ext-data-control-v1` nor
`wlr-data-control`. This was verified directly rather than inferred: Mutter's
`src/meson.build` on `main` enumerates its Wayland protocols, and it contains
zero occurrences of `data-control`. There is no external-client path, and no
amount of Phase 5 work changes that.

Three answers exist and real clipboard managers use all three:

1. **Run inside gnome-shell.** GPaste's privileged backend talks to Mutter's
   server-side selection tracker directly, reachable only from inside the
   gnome-shell process. Its own source notes this sees every selection change
   globally with no focus gating — unlike a plain `GdkClipboard` client, which
   *is* focus-gated on Wayland.
2. **Ship a GNOME Shell extension.** CopyQ does this. A second codebase, plus
   extensions.gnome.org review.
3. **Fall back to XWayland** (`QT_QPA_PLATFORM=xcb`), which CopyQ documents as
   lossy.

There is a fourth, uglier path: `org.freedesktop.portal.Clipboard` exists and
`xdg-desktop-portal-gnome` implements it, but the interface cannot open its own
session — it only extends a **RemoteDesktop** or **InputCapture** session. So
clipboard monitoring through the portal means holding an open remote-desktop
grant, and probably a persistent screen-sharing indicator
([OQ-3](open-questions.md#oq-3)). Assume it does until someone checks.

**Option 2 is the decision** ([D-5](open-questions.md#d-5)), with option 3 as
the documented fallback for anyone who will not install an extension.

**"Thin" needs enforcing rather than intending.** Anything that ends up in
`extension.js` and could have lived in the daemon is a future GNOME release's
breakage, bought voluntarily. The line: the extension forwards selection changes
over D-Bus and accepts set-selection calls back. Everything else — capture
rules, privacy markers, de-duplication, retention — stays in `SkrepkaCore`.

## Deliverables

```
gnome-extension/
  metadata.json
  extension.js
  dbus.js                       # client for dev.soldunov.Skrepka
  README.md

packaging/
  debian/{control,rules,changelog,skrepka.install}
  rpm/skrepka.spec
  systemd/skrepkad.service      # from Phase 6
  README.md                     # why not Flatpak — see below
```

## Work

### 1. The extension

JavaScript, talking to the Phase 6 D-Bus interface. It uses Mutter's
server-side selection tracker from inside the gnome-shell process and forwards
each change to `skrepkad`, and it accepts a set-selection call in the other
direction so live push works on GNOME too.

Keep it as thin as it can possibly be. Everything that can live in the daemon
should: the extension is the part that has to be reviewed by strangers,
re-approved on every GNOME release, and debugged through `journalctl`. Capture
rules, privacy markers and de-duplication all stay in `SkrepkaCore` where they
are tested.

The D-Bus interface is versioned from its first commit, because the extension
ships through a review queue and will lag the daemon by weeks.

**It must degrade honestly.** If the extension is not installed, `skrepka
doctor` says so and the Settings UI says so, with the remedy. Silently capturing
nothing is the failure mode that generates a bug report for every user.

### 2. Packaging

`.deb` and `.rpm`. Both install `skrepkad`, `skrepka`, the GUI if Phase 7
shipped, the systemd user unit, and a desktop entry.

**Flatpak is out, and the reason belongs in `packaging/README.md` rather than
being rediscovered.** Sway's `is_privileged()` lists both
`wlr_data_control_manager_v1` and `ext_data_control_manager_v1`, and its global
filter returns them only for clients with no security context — the comment in
its source says so outright: *restrict usage of privileged protocols to
unsandboxed clients.* Flatpak sets a security context. A GNOME Shell extension
cannot register from a sandbox either.

Whether KWin applies the same filter is [OQ-4](open-questions.md#oq-4) — its
`wayland_server.cpp` registers `DataControlDeviceManagerV1Interface`
unconditionally, but the `Display` global filter was not traced. It does not
change the decision; it changes how the decision is explained.

**AppImage** works for the binary alone and cannot carry the extension.
**The Static Linux SDK** (musl, fully static) suits `skrepkad` and is unusable
for a GTK GUI, which needs glibc, GL and D-Bus. If a headless-only package is
ever wanted, that is the tool for it — and after Phase 6 a headless-only package
is a real product.

### 3. Dependencies, declared properly

The package must declare what it needs, per distribution: `libwayland-client`,
`libX11`/`libXfixes`, `avahi-daemon` (recommended, not required — the embedded
responder is the fallback), GTK4 and its stack if the GUI is included. A missing
runtime library should be a package-manager error at install time, not a linker
error at first launch.

## Tests

The test here is installation, on clean machines, and it should be scripted
against a throwaway `orb create` machine per distribution — see
[the Linux environment](README.md#the-linux-environment). Run the matrix on
`arm64` *and* on `amd64`: the OrbStack buildx builder offers both, and a
packaging bug that only shows on x86_64 is one that only shows for users.

| Check | On |
|---|---|
| package installs, no unmet dependencies | Ubuntu LTS, Fedora current |
| `systemctl --user enable --now skrepkad` starts it | both |
| `skrepka doctor --json` reports a healthy session | both, under KDE, Sway, GNOME and X11 |
| pairing from a clean install reaches "paired" | both |
| uninstall removes the unit and leaves the database | both |
| upgrade over a previous version keeps history and pairings | both |

That last row is the one that will be skipped and should not be. A clipboard
manager that loses its history on upgrade loses its users.

## Done when

- A package installs on Ubuntu and on Fedora.
- The daemon starts under systemd on both.
- A fresh machine pairs with the Mac from a clean install.
- The GNOME extension is submitted, and its absence is reported honestly in the
  meantime.

## Risks

**extensions.gnome.org review is calendar time, not effort.** Budget it as such
and do not put anything on the critical path behind it. The extension being
"submitted" is a legitimate definition of done for this phase; "approved" is not
something the project controls.

**A GNOME release breaks the extension.** It will, eventually — that is the
standing cost of option 2 and it is what [D-5](open-questions.md#d-5) is really
asking about. Keeping the extension thin is the only mitigation that works.

**Two package formats, twice the maintenance.** Real, and the reason the
headless static build is worth remembering: if `.deb` and `.rpm` become a
burden, a single static `skrepkad` plus the CLI is a defensible product that one
person can maintain.
