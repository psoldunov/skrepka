# Swift Conventions

## The Quality Gate

Run `./scripts/doctor.sh` after every change that touches Swift source. It is
the definition of "done" — format check, lint, build with warnings as errors,
tests, dead-code scan. Do not report work complete on a red doctor.

Use `./scripts/doctor.sh --fast` (skips tests and the dead-code scan) mid-edit.
Run the full one before you hand work back.

Never disable a rule to make the gate pass. If a rule is genuinely wrong for one
line, silence it at that line with a comment saying why. A blanket entry in
`disabled_rules` needs a reason in the pull request description.

The formatter is not a matter of taste. When it disagrees with you, run
`xcrun swift-format format --in-place --recursive --parallel Sources Tests`.

## Project Layout

Two targets, and the split is load-bearing:

- `Sources/ClippyCore/` — models, storage, pasteboard reading, search, settings.
  No SwiftUI views, no `NSWindow`, no hotkey registration. This target is where
  the tests live, so anything you want tested goes here.
- `Sources/Clippy/` — the app. SwiftUI scenes, `NSPanel` glue, `NSStatusItem`,
  hotkey registration, paste synthesis. Only what cannot run without a window
  server.

Group by feature, not by type. `MenuBar/`, `Picker/`, `Settings/`, `Platform/` —
the AppKit glue for a surface sits next to the SwiftUI view it backs. Do not
create `Views/`, `Models/`, `Services/` folders that collect one layer across
every feature; they force four-directory edits for one change.

Put new logic in `ClippyCore` by default. Move it to the app target only when it
genuinely needs AppKit or a live window.

`ClippyCore` must not `import SwiftUI` or `import AppKit` for view types. It may
import AppKit for `NSPasteboard` and value types like `NSImage` — that is the
line: data yes, views no.

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
lives in `ClippyCore`.

## Concurrency

The app target is compiled with `.defaultIsolation(MainActor.self)`, so its
declarations are `@MainActor` unless you say otherwise. Do not add redundant
`@MainActor` there.

`ClippyCore` is `nonisolated` by default. Mark the few UI-facing types
`@MainActor` explicitly; leave pure logic alone.

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

Run with `swift test --parallel`, or one with `swift test --filter <regex>`.

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
- Aim for 200 lines per file; 300 warns, 400 fails the build. Split by
  responsibility, not by line count.
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

This app targets exactly one OS. Anything the macOS 26 SDK ships is fair game;
anything it does not is a finding, not a workaround opportunity.

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
- [ ] New logic landed in `ClippyCore`, not the app target, unless it needs AppKit
- [ ] Files grouped by feature; one primary type per file; under 300 lines
- [ ] `@Observable` used; no `ObservableObject`/`@StateObject`/`@EnvironmentObject`
- [ ] Background work in an `actor`; no `@unchecked Sendable`, no `nonisolated(unsafe)`
- [ ] New behaviour covered by a Swift Testing test, or explicitly untestable
- [ ] No suppressed lint rule without a written reason
- [ ] No force-unwrap, no `try!`, no silently swallowed error
