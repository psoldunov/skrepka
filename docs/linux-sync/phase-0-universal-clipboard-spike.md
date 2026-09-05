# Phase 0 — The Universal Clipboard spike

**Half a day. Independent of everything else, and worth doing whether or not
sync is ever built.**

## Goal

Settle two facts about what Universal Clipboard actually puts on a receiving
Mac's pasteboard, because one of the two answers means Skrepka has a bug today,
with no sync involved.

## Preconditions

None in the codebase. One in hardware: a Mac and a second Apple device signed
into the same Apple ID, with Handoff on, on the same network. An iPhone is the
better second device than another Mac — it exercises the same Continuity path
and cannot be confused with a local copy.

## The two questions

**[OQ-1](open-questions.md#oq-1) — is a Continuity-originated change detectable
at all?** `NSPasteboard.h` in the Xcode 26.5 SDK declares no remote-clipboard or
Continuity marker; AppKit and Foundation headers were grepped and contain
nothing. A `strings` pass over the on-disk AppKit binary also found nothing, but
that is inconclusive — the dyld shared cache means the on-disk binary is a stub.
So the header search is exhausted and only a running machine can answer it.

**[OQ-2](open-questions.md#oq-2) — bytes or a promise?** If the receiving
pasteboard is populated lazily, then `PasteboardReader.read` calling
`item.data(forType:)` on every `changeCount` bump forces a Continuity fetch over
the air. `Sources/SkrepkaCore/Clipboard/PasteboardPoller.swift` polls at 200 ms
and `Sources/SkrepkaCore/Clipboard/PasteboardReader.swift:44` reads
unconditionally, so every copy made on any of the user's Apple devices would
silently pull data into this Mac in the background.

That second one is the point of the phase. The first is a nice-to-have.

## Work

1. **Write a throwaway probe.** A single-file command-line Swift program, not a
   target in `Package.swift` — it is deleted when the phase ends. It should
   loop on `NSPasteboard.general.changeCount` and, on each change, print in
   this order:
   - `changeCount` before anything else is touched
   - `pasteboardItems?.first?.types.map(\.rawValue)` — the full declared list,
     not the filtered set `PasteboardReader.interestingTypes` uses
   - `changeCount` again, after reading the types but before any `data(forType:)`
   - the byte count of each `data(forType:)` call, one at a time, with a
     wall-clock duration for each
   - `changeCount` a third time, after the reads

2. **Baseline it locally.** Copy text, then an image, then a file, on the probe
   machine itself. Record the shape of a local copy so the remote one has
   something to be compared against.

3. **Run the remote case.** Copy on the second device. Watch for three
   signals, in descending order of how much they would tell us:
   - a declared type not present in the local baseline — that answers OQ-1
   - a `data(forType:)` call that takes materially longer than the local
     baseline, or that returns bytes after the type list was already available
     — that answers OQ-2 in the affirmative
   - a `changeCount` that moves *because* of a read — the clearest possible
     evidence of a promise being resolved

4. **Repeat with the payload large enough to be unmistakable.** Copy a
   multi-megabyte screenshot on the second device. A promise resolving over the
   air at that size is measurable in seconds; at 40 bytes of text it is not.

5. **Record the findings.** They go in design §14 items 1 and 2, struck out and
   replaced with what was observed, along with the macOS version and the device
   pair they were observed on. An unrecorded spike is a spike that gets run
   twice.

## What each answer means

| OQ-2 answer | Consequence |
|---|---|
| **Bytes, delivered eagerly** | No bug. Skrepka's unconditional read costs nothing extra. Design §3.1 is struck out and the rest of §3 stands on its own. |
| **A promise, resolved on read** | **Skrepka has a shipping bug.** Every copy on every device the user owns pulls data over the air into this Mac, in the background, unprompted. It is a privacy problem and a bandwidth problem and it exists today. |

| OQ-1 answer | Consequence |
|---|---|
| **A marker exists** | Live push can be suppressed precisely for Continuity-originated copies, and design §3.4's cross-system loop is closable rather than merely bounded. |
| **No marker** | The platform rule in design §3 is the only defence, and it stays as written: live push never runs between two Apple devices. |

## The fix, if OQ-2 says promise

Ships on its own, unblocked by anything else in this directory. Sketch, not a
specification — the real shape depends on what the spike sees:

- The read in `PasteboardReader.read` becomes conditional. It already filters to
  `PasteboardType.readOrder` via `interestingTypes`; the change is to decide
  *whether to resolve at all* before resolving, not which types to resolve.
- The likely seam is between declaring and reading: the type list is available
  without touching content, and `CaptureRules.decide` already handles a snapshot
  whose `representations` are empty but whose `declaredTypes` are populated —
  that is exactly what the privacy-marker path at
  `Sources/SkrepkaCore/Clipboard/PasteboardReader.swift:32` constructs today.
- Whatever gates the read has to be honest in the diagnostics. A copy Skrepka
  deliberately declined to fetch is not the same as one it failed to read, and
  `CaptureDecision` currently has no case for it. Adding one means
  `CaptureHealth.record` must not count it as a successful read either —
  see `Sources/SkrepkaCore/Diagnostics/CaptureHealth.swift:48`.
- **The behaviour is already decided** ([D-1](open-questions.md#d-1)): **fetch
  on demand.** Store the metadata, resolve the bytes only when the user picks
  that row. iPhone copies keep appearing in the history; the background traffic
  goes away.
- **If the pasteboard API cannot express deferred resolution, fall back to
  never fetching a Continuity clip** — accepting that an iPhone copy stops
  appearing in the Mac's history. Do *not* fall back to today's behaviour with a
  disclosure note; D-1 rules that out explicitly.

## Tests

The probe itself is throwaway and untested. The fix, if there is one, arrives
the way every bug fix does in this repo: with a failing test first. That test is
a `CaptureRules` or `PasteboardReader` test over a synthetic snapshot, not a
test against live Continuity — nothing here is reproducible in CI.

## Done when

- OQ-1 and OQ-2 in [`open-questions.md`](open-questions.md) each carry an
  answer, a date, and the macOS version it was observed on.
- Design §14 items 1 and 2 are struck out with the same findings.
- If the answer is "promise": a fix has landed on `master` with a test, and
  `scripts/doctor.sh` is green.

## Risks

**The spike is inconclusive.** Plausible — Continuity is undocumented and may
behave differently by payload type, by device pair, or by network. If two runs
disagree, record both and label the item unverified rather than picking the
convenient answer. An unverified item that is *known* unverified costs far less
than a confident wrong one.

**The bug is real and large.** If Skrepka has been pulling every Continuity clip
over the air, that is worth saying plainly in the release notes rather than
fixing quietly. It is a privacy claim the app implicitly made and did not keep.
