# Skrepka

A clipboard-history manager for macOS 26. Menu-bar daemon, no Dock icon, a
global hotkey opens a Liquid Glass picker panel over the frontmost app.

## Build and run

```
scripts/setup.sh      # resolve dependencies, warm the debug build
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # build build/Skrepka.app only
scripts/notarize.sh   # build, sign, notarize, staple — for builds you send out
scripts/doctor.sh     # the quality gate — run after every change
scripts/make-icon.sh  # redraw AppIcon.icns from scripts/make-icon.swift
```

`scripts/bundle.sh` signs without a secure timestamp, which is fine locally and
fatal for distribution: the notary service rejects it, and the signature dies
when the Developer ID certificate expires. `scripts/notarize.sh` sets
`SKREPKA_NOTARIZE=1`, which turns the timestamp on and makes an ad-hoc fallback
a hard error.

Notarization credentials come from `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID` and
`APPLE_API_ISSUER` — an App Store Connect API key, the same three variables the
Ensemblr repo's `forge.config.ts` reads, so one `.p8` covers both projects and
CI needs no keychain. Set all three or none; a partial set is an error rather
than a silent fallback. With none set it falls back to a notarytool keychain
profile, `xcrun notarytool store-credentials skrepka`, which wants an
app-specific password instead.

`notarize.sh` reads those three from `.env` in the repository root by itself —
copy `.env.example`, or point `SKREPKA_ENV_FILE` at another repo's `.env`
instead of duplicating a key path. The file is parsed as `KEY=VALUE` data, never
sourced, so nothing in it executes; anything already in the environment wins
over it.

Either way the credential is checked before anything is built — the universal
build and the timestamped signature are minutes of work to spend on a missing
`.p8`.

`scripts/bundle.sh` builds for the host architecture alone.
`SKREPKA_UNIVERSAL=1` builds arm64 + x86_64 instead, and `notarize.sh` sets it:
four Intel Macs still run macOS 26, and an arm64-only `.app` will not launch on
one. The script verifies with `lipo -archs` that every requested slice landed
before it signs.

`bundle.sh` and `notarize.sh` reveal what they built in Finder when they finish.
Set `SKREPKA_REVEAL=0` to suppress it — `run.sh` does, because it launches the
app, and `notarize.sh` does for its inner `bundle.sh` call, because that `.app`
has no ticket yet.

The app icon, the menu bar mark and the in-app artwork are all one path:
`PaperclipPath` in `Sources/SkrepkaCore/Branding/`, transcribed from
`scripts/paperclip.svg`. `make-icon.sh` *compiles* `make-icon.swift` with that
file linked in beside it, so plain `swift scripts/make-icon.swift` no longer
works — it cannot see the second file. Change the mark in one place.

Every script pins `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer`.
Do not build with a bare `swift build`: `xcode-select -p` points at
CommandLineTools, whose toolchain ships no `libSwiftDataMacros.dylib`, so `@Model`
in `Sources/SkrepkaCore/Store/` fails to expand. Mixing the two toolchains also
invalidates `.build/` and forces a full rebuild every time you switch.

`scripts/doctor.sh` is the definition of done. Launch with `scripts/run.sh`, not
by executing the binary: TCC attributes permissions to the responsible process,
so a shell-launched binary inherits the terminal's grants instead of exercising
the real permission path.

## Layout

- `Sources/SkrepkaCore/` — models, storage, pasteboard, search. Testable, no UI.
- `Sources/Skrepka/` — app shell, panel, SwiftUI views, platform glue.
- `Tests/SkrepkaCoreTests/` — Swift Testing.

## Rules

@.claude/rules/verify-against-docs.md
@.claude/rules/swift-conventions.md
