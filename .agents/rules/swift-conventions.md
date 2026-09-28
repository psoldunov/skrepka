# Swift Conventions

## The Quality Gate

Run `./scripts/doctor.sh` after every change that touches Swift source. It is
the definition of "done" — format check, the GNOME extension contract checks,
lint, build with warnings as errors, tests, dead-code scan. Do not report work
complete on a red doctor.

Use `./scripts/doctor.sh --fast` (skips tests and the dead-code scan) mid-edit.
Run the full one before you hand work back.

On Linux, `./scripts/doctor.sh` runs `./scripts/doctor-linux.sh` — same flags,
same rule — under whichever Linux toolchain `scripts/linux-env.sh` finds. It
compiles every Linux target and the shared ones, but never `Sources/Skrepka/`:
the macOS app target does not exist in the Linux manifest. A change to the app
target, or to `SkrepkaCore`/`SkrepkaSync` code fenced `#if os(macOS)`, cannot be
verified from Linux. Say so when you hand it back, and name `scripts/doctor.sh`
on a Mac as the check still outstanding, rather than calling it done.

Never disable a rule to make the gate pass. If a rule is genuinely wrong for one
line, silence it at that line with a comment saying why. A blanket entry in
`disabled_rules` needs a reason in the pull request description.

The formatter is not a matter of taste. When it disagrees with you, run
`./scripts/format.sh` — Xcode's swift-format on a Mac, the Linux toolchain's on
Linux.

## Project Layout

Shared logic in its own targets, platform glue in theirs, and the split is
load-bearing:

- `Sources/SkrepkaCore/` — models, storage, pasteboard reading, search,
  settings. No SwiftUI views, no `NSWindow`, no hotkey registration. It compiles
  on both platforms and most of the tests live here, so anything you want tested
  goes here.
- `Sources/SkrepkaSync/` — the sync protocol, wire codec, merge engine and TLS
  transport. Both platforms, and deliberately no dependency on `SkrepkaCore`.
- `Sources/Skrepka/` — the Mac app. SwiftUI scenes, `NSPanel` glue,
  `NSStatusItem`, hotkey registration, paste synthesis. Only what cannot run
  without a window server. `Package.swift` declares it on macOS alone.
- `Sources/SkrepkaLinuxPlatform/`, `SkrepkaIPC/`, `SkrepkaDaemon/`,
  `SkrepkaCLI/`, `SkrepkaLinuxUI/` — the Linux clipboard backends, the daemon's
  D-Bus interface, `skrepkad`, `skrepka` and `skrepka-gui`, declared on Linux
  alone. The same rule holds there: what can be decided without a compositor or
  a GTK widget is decided in a type that can be tested without one.

Group by feature, not by type. `MenuBar/`, `Picker/`, `Settings/`, `Platform/` —
the AppKit glue for a surface sits next to the SwiftUI view it backs. Do not
create `Views/`, `Models/`, `Services/` folders that collect one layer across
every feature; they force four-directory edits for one change.

Put new logic in `SkrepkaCore` by default. Move it to a platform target only
when it genuinely needs AppKit, a live window, or GTK.

`SkrepkaCore` must not `import SwiftUI` or `import AppKit` for view types. It
may import AppKit for `NSPasteboard` and value types like `NSImage` — that is
the line: data yes, views no.

## State

Use the Observation framework. `@Observable` on model classes; never
`ObservableObject` + `@Published`.

- `@State private var model = Model()` — the view that owns the instance.
- `.environment(model)` to inject, `@Environment(Model.self) private var model`
  to read.
- `@Bindable` when a child control needs `$` bindings. Inside a `body`, shadow
  the environment value: `@Bindable var model = model`.

`@StateObject`, `@ObservedObject` and `@EnvironmentObject` are legacy. Do not
introduce them — SwiftUI tracks observable properties read in `body` directly.

Views own no business logic. A view reads state and sends intent; the decision
lives in `SkrepkaCore`.

## Concurrency

The Mac app target is the one target compiled with
`.defaultIsolation(MainActor.self)`, so its declarations are `@MainActor` unless
you say otherwise. Do not add redundant `@MainActor` there.

`SkrepkaCore`, `SkrepkaSync` and every Linux target are `nonisolated` by
default. Mark the few UI-facing types `@MainActor` explicitly; leave pure logic
alone.

Background work goes in an `actor`. Per SE-0466, declarations inside an `actor`
are exempt from default isolation, so a poller actor stays off the main actor
even in the app target. `NSPasteboard` carries no main-actor annotation in the
macOS 26 SDK and is safe to read from a non-main isolation domain — verified
against `NSPasteboard.h`, not assumed.

Model types crossing an isolation boundary conform to `Sendable`. Prefer a value
type that is `Sendable` for free over a class you have to reason about.

Never reach for `@unchecked Sendable`, `nonisolated(unsafe)`, or
`MainActor.assumeIsolated` to silence a diagnostic. Each is a claim you have
proven something the compiler cannot see; if you cannot write that proof in a
comment, restructure the code instead.

Never call `DispatchQueue.main.async` in new code. Use `await MainActor.run` or
put the declaration on the main actor.

## Immutability

Model types are `struct` with `let` properties. Produce a new value; do not
mutate in place. Reserve `class` for identity that must be shared, and
`@Observable` classes for state SwiftUI observes.

SwiftData `@Model` types are the one sanctioned exception — the framework
requires a class with mutable stored properties. Keep them thin: persistence
shape only, no behaviour. Map them to value types at the boundary.

## Testing

Swift Testing only — `import Testing`, `@Test`, `#expect`, `#require`. It ships
in the toolchain. Reach for XCTest only when an API exists nowhere else, and say
why in a comment.

Run with `./scripts/test.sh`, which adds `--parallel`, and one suite with
`./scripts/test.sh --filter <regex>`. It is the way in on both platforms: on
Linux a bare `swift test` builds into `.build` with whatever toolchain is on
PATH, where the script builds into `.build-linux` under the toolchain
`scripts/linux-env.sh` finds.

Test what is testable and do not fake the rest:

- Yes: history de-duplication, ordering, pinning, eviction, persistence
  round-trips, search matching and ranking, pasteboard payload decoding,
  privacy-marker rejection, exclusion filtering.
- No: SwiftUI view bodies, hotkey registration, `NSPanel` placement,
  Accessibility permission flows. Do not write a test that only asserts a view
  can be constructed — it costs maintenance and proves nothing.

A bug fix starts with a failing test that reproduces it.

## Files and Naming

- One primary type per file. The file is named after that type.
- Aim for 200 lines per file. SwiftLint warns over 300 lines and errors over
  400, and the gate runs `swiftlint lint --strict`, which upgrades the warning to
  an error — so 300 is the ceiling in practice. Split by responsibility, not by
  line count.
- Functions under 40 lines. Nesting under 4 levels.
- Follow the Swift API Design Guidelines: clarity at the point of use,
  `UpperCamelCase` types, `lowerCamelCase` everything else, no Hungarian
  prefixes, no `get` prefix on accessors.
- Extensions carry a `// MARK:` when a file holds more than one.
- No abbreviations in public names except ones the platform already uses.

## Errors

Every error is handled or deliberately propagated. A `try?` that discards an
error needs a comment saying why the failure is uninteresting. No empty `catch`.
Never `try!` or force-unwrap outside a test — both are lint failures.

Errors that reach the user get a message written for a user, not a
`localizedDescription` dump.

## Platform APIs

On the Mac this app targets exactly one OS version. Anything the macOS 26 SDK
ships is fair game; anything it does not is a finding, not a workaround
opportunity. The Linux side has floors of its own — glibc 2.38 and GTK 4.12 —
and the same rule holds against them.

- Liquid Glass lives in **`SwiftUICore`**, not `SwiftUI`. There is only one
  `glassEffect` overload and it has no `isEnabled:` parameter — branch on the
  `Glass` value for Reduce Transparency.
- `GlassButtonStyle.init(_ glass:)` is macOS **26.1**. The `.glass(_:)` static
  function is 26.0. Guard the initializer.
- Never use private API. `_sourceSigningIdentifier` and friends are off limits
  however useful they look.
- `NSApplicationActivateIgnoringOtherApps` is deprecated since macOS 14 and has
  no effect. Use `activate(from:options:)`.

## Checklist

- [ ] `./scripts/doctor.sh` is green
- [ ] New logic landed in `SkrepkaCore`, not the app target, unless it needs
      AppKit
- [ ] Files grouped by feature; one primary type per file; under 300 lines
- [ ] `@Observable` used; no `ObservableObject`/`@StateObject`/`@EnvironmentObject`
- [ ] Background work in an `actor`; no `@unchecked Sendable`, no `nonisolated(unsafe)`
- [ ] New behaviour covered by a Swift Testing test, or explicitly untestable
- [ ] No suppressed lint rule without a written reason
- [ ] No force-unwrap, no `try!`, no silently swallowed error
