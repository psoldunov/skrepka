# Phase 4 — `SkrepkaCore` on Linux

**One to one and a half weeks, most of it the storage rewrite. The first phase
with no macOS deliverable.**

## Goal

`SkrepkaCore` and `SkrepkaSync` build on Linux and their tests pass there,
unchanged.

## Preconditions

- Phase 2 done. Phase 3 not strictly required, but finish it anyway — it is the
  last chance to find a protocol mistake with both peers on one machine.
- **[OQ-10](open-questions.md#oq-10) and [OQ-11](open-questions.md#oq-11)
  spiked first.** Both ask whether Swift on Linux can do something this phase
  assumes. A day spent answering them can save committing a month to the wrong
  language for the Linux side.
- [OQ-12](open-questions.md#oq-12) answered — it decides whether `PaperclipPath`
  ports or is rewritten.
- A container or VM pinned to the target distributions. Not whatever Linux box
  is nearest: the whole point of this phase is knowing what Ubuntu and Fedora
  do, and a rolling-release desktop answers a different question.
  **`orb create ubuntu` and `orb create fedora` give exactly that** — full
  machines rather than containers, on versions that include both Phase 8
  targets. See [the Linux environment](README.md#the-linux-environment).

## The port, measured

Measured on 2026-09-05 against `Sources/SkrepkaCore/` at **33 files, 2277
lines**. Re-measure before starting; the tree has grown since the design
document counted 31 files and 2141 lines.

**25 files and 1422 lines are available on Linux — 62% by line, 76% by file.**
That corroborates the design's 60% estimate, but the composition is different
in two ways worth knowing before scheduling the work: one more file is excluded
than the design found, and eight files that import nothing platform-specific
are nonetheless coupled to something that is.

### A — ports unchanged (15 files, 800 lines)

`Clipboard/CaptureDecision`, `Clipboard/CaptureRules`, `Clipboard/PasteboardRead`,
`Clipboard/PasteboardSnapshot`, `Clipboard/PrivacyMarkers`,
`Diagnostics/CaptureHealth`, `Diagnostics/PasteBackStatus`, `Models/ClipKind`,
`Models/ClipPayload`, `Models/ClipSummary`, `Models/PasteboardType`,
`Models/PreviewText`, `Search/Matcher`, `Settings/Preferences`,
`Store/RetentionPolicy`.

This is the load-bearing 800 lines — the privacy rules, the capture decision,
search matching, retention. It moves for free, and it is the reason the port is
worth doing at all.

Two caveats: `CaptureHealth` and `Preferences` are `@MainActor @Observable`, so
they inherit [OQ-11](open-questions.md#oq-11), and `Preferences` needs
`UserDefaults` from swift-corelibs-foundation to behave — including
`didSet`-driven writes surviving a process restart, which is worth one test
rather than an assumption.

### B — needs a seam (8 files, 485 lines)

These import only `Foundation` and look portable. They are not, because they
name a type that is not. Each needs a protocol or a conditional split, and this
is the work the design document does not account for.

| File | Lines | The coupling | The seam |
|---|---|---|---|
| `Clipboard/PasteboardPoller` | 95 | holds a concrete `PasteboardReader`, which imports AppKit — see `PasteboardPoller.swift:17` and `:28` | a `ClipboardSource` protocol with `changeCount()` and `read(sourceBundleID:)`; `PasteboardReader` becomes its macOS conformance and Phase 5 writes the Linux ones |
| `Diagnostics/PasteboardAccess` | 51 | imports AppKit for one initialiser taking `NSPasteboard.AccessBehavior` | the enum is portable; wrap only `init(_:)` in `#if canImport(AppKit)`. On Linux the value is always `.alwaysAllow` — there is no equivalent gate |
| `Diagnostics/ClipboardStatus` | 40 | takes a `PasteboardAccess` | falls out once the above is split |
| `Diagnostics/DiagnosticsSnapshot` | 92 | stores a `PasteboardAccess` | same |
| `Diagnostics/DiagnosticsProblem` | 68 | ranks over `ClipboardStatus` and `PasteBackStatus` | same, plus new Linux-only cases in Phase 5 |
| `Diagnostics/DiagnosticsReport` | 50 | renders a snapshot | same |
| `Store/ClipRecordMapping` | 61 | names `ClipRecord` (SwiftData) and `ThumbnailMaker.Preview` (AppKit) | moves behind `HistoryStoring` with the SwiftData conformance; the SQLite one gets its own mapping |
| `Store/ThumbnailRenderer` | 28 | wraps `ThumbnailMaker`, which imports AppKit | **defer the protocol** ([D-9](open-questions.md#d-9)). A `ThumbnailProducing` protocol with one real conformance and one nil-returning stub is a macOS cost with no macOS benefit. Exclude the file on Linux for now; introduce the protocol in Phase 7, when GdkPixbuf gives it a second real conformance |

`PasteboardPoller` is the one to look at first. It is described everywhere as
pure logic and it is *nearly* that, but it constructs a concrete AppKit type in
its own default argument. Introducing `ClipboardSource` is a small change with
a large consequence: it is also the protocol Phase 5's two Wayland backends and
one X11 backend conform to, so getting its shape right here is worth an hour.

### C — one-line shims (2 files, 137 lines)

| File | Change |
|---|---|
| `Models/ClipItem` | `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`. swift-crypto is source-identical — it compiles its API surface down to nothing on Apple platforms and re-exports CryptoKit, so `SHA256.hash(data:)` is unchanged |
| `SkrepkaLog` | `os.Logger` → swift-log behind the same shape of shim. Thirteen lines, and the call sites use `.error(_:)`/`.notice(_:)`/`.debug(_:)` — confirm swift-log's levels line up before assuming the call sites are untouched |

### D — macOS keeps SwiftData; Linux gets its own (2 files, 260 lines)

`Store/ClipRecord` and `Store/HistoryStore`.

**macOS is untouched.** SwiftData stays exactly where it is, `@Model` and all,
and `HistoryStore` simply becomes the *first* conformance of the
`HistoryStoring` protocol extracted in Phase 3. No behaviour changes and no data
moves — `skrepka.store` keeps being read by the framework that wrote it. Phase 2
does add properties to `ClipRecord`, which is a schema change, but
[D-8](open-questions.md#d-8) makes that a twenty-minute check rather than a
migration project.

**Linux gets a second conformance** backed by raw SQLite through the C library
— not GRDB ([D-3](open-questions.md#d-3)). These two files are the only ones on
the list that are *replaced* rather than ported or excluded, and only on Linux,
where SwiftData does not exist. It is most of the phase's week.

**Why not one engine everywhere.** Moving macOS to SQLite as well would be less
code and no divergence risk. It is refused by
[D-9](open-questions.md#d-9): the Mac app stays native, and the Linux port does
not get to change how it is built. SwiftData is the platform's persistence
framework, and "one engine everywhere" is a Linux convenience.

Supporting, and true regardless: `@Attribute(.externalStorage)` is doing real
work keeping multi-megabyte payload blobs out of the row, and reimplementing it
over raw SQLite is not free.

**What two engines actually costs**, stated so it is not a surprise:

- **The schema is defined twice.** Phase 2 adds `TombstoneRecord` and
  `PairedDeviceRecord` as `@Model` types; on Linux those are two more SQLite
  tables. A column added on one side and forgotten on the other is the failure
  mode.
- **Each conformance owns its own mapping.** `ClipRecordMapping` and
  `SyncMetaMapping` belong to the SwiftData side; the SQLite side writes its
  own.
- **Semantics can drift** — sort stability, what a nil column means,
  transaction boundaries.

All three are held down by the same thing: **`HistoryStoringTests` is one suite
run against every conformance** — SwiftData, `ProbeStore` from Phase 3, and
SQLite. That is the whole reason Phase 3 pulls the protocol forward instead of
leaving it here. A behaviour that differs between engines fails the suite on one
of them.

A `.systemLibrary` target over `sqlite3` with `pkgConfig:` and apt/yum
`providers:`, the same shape Phase 5 uses for `wayland-client` — so a missing
`libsqlite3-dev` names the package rather than failing at link time.

### E — excluded (6 files, 595 lines)

| File | Lines | Why | Where it reappears |
|---|---|---|---|
| `Clipboard/PasteboardReader` | 80 | AppKit | Phase 5, as three `ClipboardSource` conformances |
| `MenuBar/StatusItemIcon` | 108 | AppKit | Phase 7, tray icon |
| `Shortcut/ShortcutSymbols` | 85 | AppKit + Carbon | Phase 7, and the symbols are macOS glyphs — the Linux equivalent is different content, not a port |
| `Store/ImageFileThumbnail` | 86 | AppKit, ImageIO, UniformTypeIdentifiers | Phase 7, GdkPixbuf + shared-mime-info |
| `Store/ThumbnailMaker` | 94 | AppKit | Phase 7 |
| `Branding/PaperclipPath` | 142 | **Core Graphics** — `CGPath`, `CGMutablePath`, `CGAffineTransform` | see below |

**`PaperclipPath` is a finding the design document missed.** It imports
`CoreGraphics`, not AppKit, so it does not appear in the design's "eight files
that import AppKit or SwiftData". It is 142 lines and it is the single source of
the app icon, the menu-bar mark and the in-app artwork — `scripts/make-icon.sh`
compiles it into the icon renderer specifically so the three cannot drift.

Whether it ports depends on [OQ-12](open-questions.md#oq-12): swift-corelibs-
foundation provides `CGFloat`, `CGPoint`, `CGRect` and `CGSize` on Linux, but
`CGPath`, `CGMutablePath` and `CGAffineTransform` are Core Graphics types and
their availability has to be checked rather than assumed. If they are absent,
the mark needs a portable path representation — a small value type with
`move`/`line`/`curve`/`close` cases, rendered to `CGPath` on macOS and to Cairo
on Linux — and `scripts/paperclip.svg` stays the design source either way.
That is half a day, and it is Phase 7 work rather than Phase 4 work. Exclude the
file here and say why.

## The test target

`Tests/SkrepkaCoreTests/` is 14 files and 1765 lines. **Seven files and 790
lines run on Linux**: `CaptureRulesTests`, `ClipItemTests`, `ClipSummaryTests`,
`DiagnosticsTests`, `MatcherTests`, `PasteBackStatusTests`,
`RetentionPolicyTests`.

Seven do not: `Fixtures` (AppKit, ImageIO), `HistoryStoreTests` (SwiftData, and
it uses `Fixtures`), `ThumbnailMakerTests` (AppKit, `Fixtures`),
`StatusItemIconTests` (AppKit), `ShortcutSymbolsTests` (AppKit, Carbon),
`PaperclipPathTests` and `SVGPathParser` (both Core Graphics).

`Fixtures` is only used by `HistoryStoreTests` and `ThumbnailMakerTests`, both
already excluded — so it does not drag the rest of the suite down with it, which
is better than it first looks.

**How to exclude them matters.** `swift test --filter` filters at *run* time;
the files still have to compile. Guard each excluded file at file scope with
`#if canImport(AppKit)` (or `canImport(CoreGraphics)`), rather than juggling a
platform-conditional `exclude:` array in the manifest. The manifest approach
works — `Package.swift` is Swift evaluated on the build host, so `#if os(Linux)`
is legitimate there — but a guard inside the file states the reason at the place
a reader will look for it.

`DiagnosticsTests` is 246 lines and it is the largest single win in the suite,
but it only compiles once the `PasteboardAccess` seam in category B lands. Do
that seam early.

`HistoryStoreTests` does not port, and it should not be recreated. The
`HistoryStoringTests` suite from Phase 3 already runs the same assertions
against every conformance; the SQLite implementation joins it as a third.

## Work

1. Spike OQ-10, OQ-11 and OQ-12. Stop and reconsider if any comes back badly.
2. Land the `PasteboardAccess` conditional split — it unblocks five files and
   246 lines of tests, and it is an hour.
3. Land `ClipboardSource`, and make `PasteboardPoller` take it.
4. Exclude `ThumbnailRenderer` on Linux. Do **not** introduce `ThumbnailProducing` yet — Phase 7 does, when it has a real second conformance ([D-9](open-questions.md#d-9)).
5. Land the CryptoKit and logging shims.
6. Guard the seven excluded test files.
7. Write the SQLite conformance of `HistoryStoring`. This is the week.
8. Write `scripts/doctor-linux.sh`.
9. Get the seven test files green in the container.

## `scripts/doctor-linux.sh`

Without it the next four phases have no definition of done, so it is a
deliverable and not a nicety. Model it on `scripts/doctor.sh` — same `check` and
`optional` helpers, same "skipped, and here is why" reporting, because a gate
that silently skips half its checks is worse than no gate.

Three things need confirming rather than assuming, and `doctor.sh`'s `optional`
helper already handles the "tool is absent" case gracefully:

- **`swift-format` on Linux.** Bundled in the toolchain, or built separately?
  The macOS gate runs `xcrun swift-format`, which does not exist there.
- **SwiftLint on Linux.** Available, but typically built from source rather than
  installed from a package.
- **Periphery on Linux.** Its platform support needs checking; if it is
  macOS-only, the dead-code scan stays a macOS-side check and the Linux gate
  says so out loud.

**Building is not one command.** A bare `swift build` on Linux tries to build
the `Skrepka` app target and its macOS-only `KeyboardShortcuts` dependency.
Either build the two targets explicitly, or declare a `SkrepkaLinux` library
product covering `SkrepkaCore` and `SkrepkaSync` and build that — confirm which
form the resolved SwiftPM accepts before writing it into the script.

## Done when

- `swift build` (in whichever form the previous paragraph settles on) succeeds
  in the container.
- The seven Linux-clean test files pass there, unchanged.
- `HistoryStoringTests` passes against the SQLite conformance.
- `scripts/doctor-linux.sh` exists, runs green, and names every check it skipped.
- `scripts/doctor.sh` is still green on macOS. Every seam introduced here
  touches the macOS build too.

## Risks

**The storage rewrite is where the week goes.** It is also the least
interesting work in the project and the easiest to underestimate. The mitigation
is that `HistoryStoringTests` exists before the implementation does — write to a
green suite, not to a blank file.

**A seam introduced for Linux makes the macOS code worse.** This is what
[D-9](open-questions.md#d-9) exists to catch, and its audit already caught one:
`ThumbnailProducing` is deferred to Phase 7 for exactly this reason. Apply the
same test to anything new — would this change be worth making if Linux did not
exist? If not, it needs a second reason.

**Swift on Linux turns out not to be viable.** That is what OQ-10 and OQ-11 are
for, and this is the last phase where changing the answer is cheap. If Swift
cannot register an Avahi service and cannot run `Observation`, the honest
options are a C or Rust daemon speaking the Phase 1 wire protocol — which is
exactly why that protocol is CBOR over a documented framing and not Swift
`Codable`.
