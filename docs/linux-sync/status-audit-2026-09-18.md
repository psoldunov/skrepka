# Linux sync — status audit, 2026-09-18

Code at `e3d5a92` checked against every phase doc in this directory. Five
read-only agents took one slice each; their key claims were re-checked by hand.
The same day's follow-up work is recorded under [Done today](#done-today).

---

## Next: Phase 7, against the headless Sway

Linux hardware testing is **deferred** (owner's decision, 2026-09-18). Phase 7
carries on without it — see [Phase 7](#phase-7-the-linux-picker) below.

**Deferred: the Steam Deck session.** It is ready, and it is a little over 2
hours:

1. On the Mac: `scripts/build-deck.sh`. *About 20 minutes the first time.*
2. On the Deck: follow [`steam-deck-session.md`](steam-deck-session.md),
   sections 0 → 5. *100 minutes if nothing blocks.*
3. Record the results where section 5 says. *10 minutes.*

Four things wait on it:

1. The Phase 6 hardware runbook.
2. Phase 7 step 1 on KDE, so D-4 stays provisional.
3. The first live run of `ExtDataControlBinding`.
4. [OQ-4](open-questions.md#oq-4).

---

## Done today

Commits are named by subject rather than hash: this repository squash-merges,
and a branch's hashes do not survive that.

| | What | Commit |
|---|---|---|
| ✅ | macOS gate green again under Xcode 27 / Swift 6.4 — 556 tests | *fix: build and gate under Xcode 27 and Swift 6.4* |
| ✅ | OQ-16 decided as [D-11](open-questions.md#d-11): Return copies, the user presses Ctrl+V | *docs: decide how the Linux picker pastes, and bring the plan back in line with the code* |
| ✅ | Doc drift fixed across README and seven phase docs | the same |
| ✅ | Unpin propagation tested end to end in the probe runbook | *test: assert that an unpin propagates in the probe runbook* |
| ✅ | x86_64 Deck build, palette demo, session checklist | *build: ship an x86_64 Linux build to the Steam Deck, and script its first session* |

**What broke on macOS, and the fix.** Nothing in the repo changed; the
toolchain did.

1. swift-format now requires `orderedImports.shouldGroupImports`. It is set to
   `true`, which leaves the existing formatting alone (`false` would flag 91
   files).
2. Swift 6.4 refuses a `Sendable` conformance implied from another file.
   `HistoryStore` now declares `Sendable` itself, and SwiftLint's
   `redundant_sendable` is silenced on that line with the reason beside it.
3. SwiftPM now builds with Swift Build, which moved the index store to
   `.build/out`. `scripts/doctor.sh` points Periphery there, and a canary
   function proved the scan still catches dead code.

---

## Where things stand

**5 of 9 phases are complete in code. 1 more is nearly there.**

| Phase | Status | What is left |
|---|---|---|
| 1 Sync core | ✅ Complete | — |
| 2 Plumbing | ✅ Complete | — |
| 4 Core on Linux | ✅ Complete | — |
| 5 Linux clipboard | ✅ Complete | `ext` Wayland binding never run live — Deck, deferred |
| 6 Linux daemon | ✅ Complete in code | hardware runbook — Deck, deferred |
| 3 macOS sync | 🟡 Nearly done | real two-Mac test; live push over 256 KB |
| 7 Linux GUI | 🟡 About 20% | rows, daemon link, hotkey, tray, Settings |
| 8 GNOME + packaging | 🟡 About 10% | extension, `.deb`/`.rpm`, desktop entries |
| 0 Universal Clipboard spike | ⛔ Blocked | needs a second Apple device |

| Gate | Result |
|---|---|
| `scripts/doctor.sh` | ✅ 556 tests in 74 suites, Xcode 27.0 / Swift 6.4 |
| `scripts/doctor-linux.sh` | ✅ 708 tests in 98 suites, Swift 6.3.3 |

**Watch:** the two compilers now differ. `swift:6.4-noble` isn't published yet;
when it is, bump `SWIFT_VERSION` and re-run the Linux gate.

---

## Phase 7: the Linux picker

Everything below builds and tests against the headless Sway. The one risk the
deferral leaves open: KWin may disagree with something Sway accepts.

**Now**

1. Connect the picker to the daemon over D-Bus (`dev.soldunov.Skrepka1`).
   *1–2 days.*
2. Real rows (`PickerRow`): thumbnail, kind glyph, pin, footer, empty state.
   *2–3 days.*
3. `ThumbnailProducing` in `SkrepkaCore`, in a macOS and a GdkPixbuf version.
   *1–2 days.*
4. Global hotkey through the `GlobalShortcuts` portal. *1–2 days.*
5. Return writes the chosen clip to the clipboard (D-11). *Hours.*

**Later**

- Tray (StatusNotifierItem) and a Cairo renderer for the mark. *2–3 days.*
- Settings: retention, exclusions, peers, pairing. *3–4 days.*

**Total: about 2½–3½ weeks**, which matches the plan's own estimate.

---

## Other code gaps

1. **Live push over 256 KB never reaches the other clipboard.** It lands in
   history only. The fix is to allow more than one request at a time in
   `Sources/SkrepkaSync/Transport/SyncInitiator.swift`. *Days.*
2. **Clock-skew refusals are silent.** `SkrepkaSync` has no logger
   (`Sources/SkrepkaSync/Transport/InboundClock.swift:39`). *Half a day.*
3. **No CI.** `.github/` has templates only. Today's Swift 6.4 break is what CI
   would have caught. *Half a day* for a Linux workflow.
4. **Pairing has no connect-by-address fallback.** It only matters if a
   network's mDNS fails; SteamOS enables Avahi by default. *1–2 hours.*
5. Automate runbook step 10: kill a peer mid-fetch, then check it resumes.
   *Half a day.*

---

## Phase 8, when Phase 7 is further along

1. ~~Harden `scripts/install.sh`: release download with checksum, version pin,
   `uname -m` mapping, desktop entries, GTK4 library check.~~ Done for 0.2.0:
   the release download, checksum, version pin, x86_64 check and a pre-install
   run of `skrepkad --version` are the new root `install.sh`, and building from
   a checkout moved to `scripts/setup-linux.sh`. Desktop entries and the GTK4
   library warning were already there.
2. Write the Flatpak-is-out reason into `packaging/README.md`. *30 minutes.*
3. Scaffold `gnome-extension/` against `dev.soldunov.Skrepka1`. *1–2 days.*
4. Skeletons for `packaging/debian/` and `packaging/rpm/`. *1 day.*

---

## Evidence, per phase

Reference only. Skim when you need a file path.

- **Phase 0.** No probe code. OQ-1 and OQ-2 are open. Consistent.
- **Phase 1.** `Sources/SkrepkaSync/` has 96 files and no `SkrepkaCore`
  dependency. CBOR is hand-rolled and strict on decode. D-7 (concealed items
  never sync) is enforced in both stores.
- **Phase 2.** Three `@Model` entities, pairing, pinned TLS 1.3, Bonjour.
  `ClipProjection` solved the main-actor merge cost.
- **Phase 3.** `SyncCoordinator` is wired into `AppCoordinator`. Runbook steps
  1, 3, 6, 7, 11 and 12 now run end to end in `scripts/probe-runbook.sh`.
- **Phase 4.** Static `SkrepkaLinux` product, a 20-file SQLite store, and 59 of
  83 `SkrepkaCore` files compile on Linux.
- **Phase 5.** `SessionProbe` prefers `ext` over `wlr`. 18 live tests run
  against headless Sway and Xvfb.
- **Phase 6.** `AvahiDiscovery`, `skrepkad`, `SkrepkaIPC`, the CLI, the systemd
  unit, `scripts/install.sh`. The two parts skipped on purpose are recorded.
- **Phase 7.** Palette window, key map, metrics, mark path code, 26 UI tests,
  and now `skrepka-palette-demo`. No `Tray/`, `Hotkey/`, `Settings/` or
  `Thumbnails/` yet.
- **Phase 8.** Only Phase 6's installer and systemd unit.

## Agent claims corrected by hand

- Phase 7's "mark matches the SVG" test exists:
  `Tests/SkrepkaCoreTests/PaperclipMarkTests.swift`.
- `Store/SQLite/` holds 20 files, not 18.
- `dropTombstone` does not read the wall clock; it uses `MergeInput.now`.
- The first draft of the Deck checklist named a `skrepka status` command, a
  "four-word" code and install messages that don't exist. It was corrected
  against the code before commit.
