# Clippy

A clipboard-history manager for macOS 26. Menu-bar daemon, no Dock icon, a
global hotkey opens a Liquid Glass picker panel over the frontmost app.

## Build and run

```
scripts/setup.sh      # resolve dependencies, warm the debug build
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # build build/Clippy.app only
scripts/notarize.sh   # build, sign, notarize, staple — for builds you send out
scripts/doctor.sh     # the quality gate — run after every change
scripts/make-icon.sh  # redraw AppIcon.icns from scripts/make-icon.swift
```

`scripts/bundle.sh` signs without a secure timestamp, which is fine locally and
fatal for distribution: the notary service rejects it, and the signature dies
when the Developer ID certificate expires. `scripts/notarize.sh` sets
`CLIPPY_NOTARIZE=1`, which turns the timestamp on and makes an ad-hoc fallback a
hard error. It needs a one-time `xcrun notarytool store-credentials clippy`.

Every script pins `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer`.
Do not build with a bare `swift build`: `xcode-select -p` points at
CommandLineTools, whose toolchain ships no `libSwiftDataMacros.dylib`, so `@Model`
in `Sources/ClippyCore/Store/` fails to expand. Mixing the two toolchains also
invalidates `.build/` and forces a full rebuild every time you switch.

`scripts/doctor.sh` is the definition of done. Launch with `scripts/run.sh`, not
by executing the binary: TCC attributes permissions to the responsible process,
so a shell-launched binary inherits the terminal's grants instead of exercising
the real permission path.

## Layout

- `Sources/ClippyCore/` — models, storage, pasteboard, search. Testable, no UI.
- `Sources/Clippy/` — app shell, panel, SwiftUI views, platform glue.
- `Tests/ClippyCoreTests/` — Swift Testing.

## Rules

@.claude/rules/verify-against-docs.md
@.claude/rules/swift-conventions.md
