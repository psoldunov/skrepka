# Contributing to Skrepka

Thanks for looking. Skrepka is a small, opinionated clipboard manager for macOS
and Linux, and the shape of a contribution matters more here than its size —
this file is what that shape is, so you do not find out in review.

## Before you write code

Open an issue first for anything larger than a typo or a one-line fix. A bug
report needs no permission; a feature does. Skrepka has a deliberately narrow
scope, and the cheapest place to find out that an idea is out of scope is an
issue, not a finished branch.

Two things that will be declined regardless of how well they are written:

- **Private API.** `_sourceSigningIdentifier` and friends are off limits
  however useful they look.
- **Compatibility shims for older macOS.** On the Mac, Skrepka targets macOS 26
  and nothing else. Anything the macOS 26 SDK ships is fair game; anything it
  does not is a finding, not a workaround opportunity.

The Linux side and LAN sync were designed in
[`docs/linux-sync-consideration.md`](docs/linux-sync-consideration.md) and
built phase by phase to the plan in
[`docs/linux-sync/`](docs/linux-sync/README.md). Read both before proposing
anything in that area, so the research is not repeated — and start with
[`open-questions.md`](docs/linux-sync/open-questions.md), which holds the
decisions already taken and the questions still open. One of those decisions
is why SteamOS gets a user-scope installer, other distributions a `.deb` or an
`.rpm` as well, and nothing gets a Flatpak;
[`packaging/README.md`](packaging/README.md) has the short version.

## What you need

On a Mac, for the Mac app — and for everything else, since the Linux side
builds and tests in containers from here:

- macOS 26.0 or later
- **Xcode 26, a full install.** Not Command Line Tools. Its toolchain ships no
  `libSwiftDataMacros.dylib`, so every `@Model` in `Sources/SkrepkaCore/Store/`
  fails to expand. Every script in `scripts/` that runs Swift on the Mac pins
  `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer` for exactly
  this reason; the Linux ones run theirs in the build image, or natively on a
  Linux host, with no Xcode to pin. Never
  build with a bare `swift build`, which also invalidates `.build/` and forces
  a full rebuild each time you switch toolchains.
- SwiftLint and Periphery:

  ```sh
  brew install swiftlint periphery
  ```

  The quality gate skips either one with a warning rather than failing, so a
  green run on your machine without them is not the same green run as CI's.

Then:

```sh
scripts/setup.sh   # resolve the pinned graph, warm the debug build
scripts/run.sh     # build, bundle, sign, launch
```

Launch with `scripts/run.sh` rather than running the built binary. TCC
attributes permissions to the responsible process, so a shell-launched binary
inherits your terminal's grants instead of exercising the real permission path
— which means a permissions bug will not reproduce for you.

For the Linux side, add [OrbStack](https://orbstack.dev) or Docker.
`scripts/linux.sh <command>` runs anything inside the Linux build image, and
the headless desktop images — `scripts/kde-image.sh` for SteamOS 3.8's Plasma,
`scripts/gnome-image.sh` for Ubuntu 26.04's GNOME 50 — are where the tray, the
shortcut, the picker and automatic paste get exercised. On a Linux machine
itself, a Swift 6.3 toolchain and `scripts/setup-linux.sh` are enough; the
desktop app also needs the development packages for GTK 4.12 or newer and
gtk4-layer-shell.

The containers are not a desktop anyone uses. Say which of your checks ran
headless and which on real hardware — GNOME, for one, has so far only ever run
headless.

## The quality gate

```sh
scripts/doctor.sh          # format check, lint, build with warnings as errors, tests, dead-code scan
scripts/doctor.sh --fast   # format, lint, build only — the mid-edit loop
```

**A green `scripts/doctor.sh` is the definition of done.** Run the full one
before you open a pull request. Do not open one on a red doctor and describe
the failure in the body. A change that touches code compiled on Linux also
needs a green `scripts/doctor-linux.sh` — same flags, same rule.

One that touches the tray, the shortcut, the picker or pasting on Linux also
runs `scripts/kde-smoke.sh` and `scripts/gnome-smoke.sh`, and reports what they
printed. The KDE run must be green. The GNOME run is not green today — its
shortcut check is intermittent and its automatic-paste check fails, as the
README's [Where it runs](README.md#where-it-runs) says — so those two checks
may fail and no others may. Once they are fixed, a green GNOME run is required
as well.

When the formatter disagrees with you, it wins:

```sh
xcrun swift-format format --in-place --recursive --parallel Sources Tests
```

Never disable a lint rule to make the gate pass. If a rule is genuinely wrong
for one line, silence it at that line with a comment saying why. A blanket
entry in `disabled_rules` needs a reason in the pull request description.

## Where code goes

The split between shared logic and platform glue is load-bearing:

- **`Sources/SkrepkaCore/`** — models, storage, pasteboard reading, search,
  settings. No SwiftUI views, no `NSWindow`, no hotkey registration. It compiles
  on both platforms and the tests live here, so anything you want tested goes
  here. This is the default.
- **`Sources/SkrepkaSync/`** — the sync protocol, wire codec, merge engine and
  TLS transport, on both platforms, with no dependency on `SkrepkaCore`.
- **`Sources/Skrepka/`** — the Mac app: SwiftUI scenes, `NSPanel` glue,
  `NSStatusItem`, hotkey registration, paste synthesis. Only what cannot run
  without a live window server.
- **The Linux targets** — `SkrepkaLinuxPlatform` (clipboard backends,
  discovery, paste), `SkrepkaDaemon` (`skrepkad`), `SkrepkaIPC` (the D-Bus
  interface), `SkrepkaCLI` (`skrepka`) and `SkrepkaLinuxUI` (`skrepka-gui`).
  The same rule holds there: what can be decided without a compositor or a GTK
  widget is decided in a type that can be tested without one.

Group by feature, not by type — `MenuBar/`, `Picker/`, `Settings/`,
`Platform/`. Do not add `Views/`, `Models/`, `Services/` directories that
collect one layer across every feature; they turn one change into a
four-directory edit.

The full conventions — Observation over `ObservableObject`, actors over
`DispatchQueue.main.async`, no `@unchecked Sendable`, no force-unwrap, file and
function size ceilings — live in
[`.claude/rules/swift-conventions.md`](.claude/rules/swift-conventions.md).
Read it once; the linter enforces roughly half of it and review covers the
rest.

## Verify APIs against docs, not memory

Confirm a signature, option name, config key, CLI flag or return shape against
documentation for the version installed here *before* writing the code —
starting with the SDK headers and `.swiftinterface` files, which outrank every
other source. Availability annotations are the thing to check: Liquid Glass
lives in `SwiftUICore` rather than `SwiftUI`, and `GlassButtonStyle.init(_:)`
is macOS 26.1 while `.glass(_:)` is 26.0. The full rule is
[`.claude/rules/verify-against-docs.md`](.claude/rules/verify-against-docs.md).

If something genuinely cannot be verified, label it as unverified where the
claim lives rather than smoothing over it.

## Tests

Swift Testing only — `import Testing`, `@Test`, `#expect`, `#require`. It ships
in the toolchain. Reach for XCTest only when an API exists nowhere else, and
say why in a comment.

```sh
swift test --parallel
swift test --filter <regex>
```

Test what is testable and do not fake the rest:

- **Yes** — history de-duplication, ordering, pinning, eviction, persistence
  round-trips, search matching and ranking, pasteboard payload decoding,
  privacy-marker rejection, exclusion filtering.
- **No** — SwiftUI view bodies, hotkey registration, `NSPanel` placement,
  Accessibility permission flows. A test that only asserts a view can be
  constructed costs maintenance and proves nothing.

**A bug fix starts with a failing test that reproduces the bug.** Write it
first, watch it fail, then fix it.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):

```
<type>: <description>

<optional body explaining why, not what>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

For the pull request itself:

- One concern per pull request. Split unrelated changes.
- Fill in the template. The "how you verified it" section is the one that
  matters most — a lot of Skrepka's behaviour only shows up when the app is
  actually running over another app.
- Say which claims you verified against documentation and which you could not,
  particularly for platform API behaviour.
- Note anything the automated gate cannot catch: panel placement, focus
  behaviour, how the mark renders in the menu bar at both appearances — and on
  Linux, which desktops you ran it on, and whether they were real or headless.

## Reporting security issues

Do not open a public issue for a vulnerability. [`SECURITY.md`](SECURITY.md)
has the private route.

## Code of conduct

Participating means agreeing to the
[Code of Conduct](CODE_OF_CONDUCT.md).
