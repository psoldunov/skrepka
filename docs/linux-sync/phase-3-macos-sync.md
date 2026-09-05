# Phase 3 — macOS app wiring, and the probe peer

**A week. The last phase that ships anything to a macOS user. Everything after
it is Linux.**

## Goal

Sync working in the real app, proven against a headless second peer that stands
in for the Linux client.

## Preconditions

- Phase 2 done, `LoopbackSyncTests` green.
- Phase 0 answered. If it found the promise bug, that fix is already on
  `master` — live push writes the pasteboard, and building on top of a broken
  read path makes both problems harder to see.

## Deliverables

```
Sources/Skrepka/Sync/
  SyncCoordinator.swift
  LivePushReceiver.swift
  PairingSheet.swift
  PeerRowView.swift
Sources/Skrepka/Settings/
  SyncSettingsView.swift
  SettingsTabBar.swift            # + .sync case
Sources/SkrepkaCore/Store/
  HistoryStoring.swift            # protocol, pulled forward from Phase 4

Sources/skrepka-sync-probe/
  main.swift
  ProbeStore.swift                # file-backed HistoryStoring conformance
  ProbeCommands.swift
```

Plus `Package.swift` gaining the `skrepka-sync-probe` executable target.

## Work

### 1. Pull `HistoryStoring` forward from Phase 4

The design document puts the protocol extraction in Phase 4, where SQLite needs
a second conformance. That is a phase too late: **this** phase needs a second
conformance too, for the probe, and a protocol with two conformances is a proven
protocol while one with a single conformance is a guess that compiles.

Extract it here. `HistoryStore` becomes its first conformance and nothing about
its behaviour changes. Phase 4's SQLite implementation then slots into a shape
that has already been exercised by something other than SwiftData.

Keep it narrow. The protocol is what *sync* needs — `syncIndex`, `applyRemote`,
`tombstones`, `recordTombstone`, `payload(for:)`, `capture` — not everything
`HistoryStore` happens to expose. The picker keeps talking to the concrete type.

### 2. `SyncCoordinator`

The one object that owns the sync lifetime, hanging off `AppCoordinator`
alongside `watcher`, `store` and `statusItem` — so there stays exactly one place
to look for what owns what.

It owns: the `PeerDiscovery` browser and advertiser, the `SyncServer`, one
`SyncConnection` per paired peer, the merge loop, and the recently-received
hash set. It is `@MainActor` like everything else in the app target, and the
connections are actors underneath it.

Wire it in `AppCoordinator.start()`, next to `startCaptureLoop()`, and tear it
down in `stop()`. Its errors surface the way `startupError` does — in the UI,
not in a log line nobody reads.

### 3. Live push, both directions

**Sending.** `SyncCoordinator` observes the same capture stream
`AppCoordinator.startCaptureLoop()` consumes. Do not add a second watcher.
Inline the bytes under `SyncLimits.livePushInlineLimit`; above it, push metadata
and let the peer fetch, so a 20 MB screenshot never blocks the live channel.

**Receiving.** The echo-suppression primitive already exists and should be
reused rather than reinvented: `AppCoordinator.choose(_:style:)` already does
`await watcher.pause()` → write → `await watcher.resume()`, and
`ClipboardWatcher.resume()` at
`Sources/SkrepkaCore/Clipboard/ClipboardWatcher.swift:112` re-reads
`changeCount` so whatever happened while paused is discarded. A received live
push does exactly the same dance.

Write through `PasteService` with `shouldPaste: false` and `target: nil` rather
than writing `NSPasteboard` directly — there should be one place in this app
that owns the pasteboard, and it already exists. Two write paths is how the
`org.nspasteboard.source` marker at
`Sources/SkrepkaCore/Models/PasteboardType.swift:26` ends up set on one and not
the other.

**Belt and braces:** a short-lived set of recently received content hashes, so a
hash just accepted is never re-broadcast even if the pause window is missed.
Bound it by count and by age; an unbounded set of hashes is a slow leak.

**The platform rule from design §3 is enforced here**, using
`PeerPlatform.livePushDefaultsOn` from Phase 1. Never between two Apple devices.

### 4. Settings

`SettingsTab` gains a `.sync` case with a title and an SF Symbol, alongside the
four already there. While in that file: the doc comment at
`Sources/Skrepka/Settings/SettingsTabBar.swift:3` says "The three settings
panes" over a four-case enum. Fix it in the same commit.

`SyncSettingsView` shows discovered peers, paired peers, and this device's own
name and short fingerprint. Each paired peer is a `PeerRowView` carrying:

- last-synced time, and item counts in each direction
- the live-push toggle
- **the reason, in the row, when it is off by default.** "Universal Clipboard
  already does this" is a sentence the user can act on; a disabled switch with
  no explanation is a bug report waiting to be filed.
- unpair, which forgets the pinned certificate

`PairingSheet` shows the eight-character SAS on both sides and asks the user to
confirm they match. It must be *readable* — grouped `A3F2-91BC`, in a face where
`0`/`O` and `1`/`l` differ — because the entire MITM defence is a human
comparing two strings on two screens.

### 5. `skrepka-sync-probe`

An executable second peer. File-backed store, advertises `plat=linux`, speaks
the whole protocol, and **never touches `NSPasteboard`** — that is the point of
it. Two Mac desktop sessions would re-introduce the Universal Clipboard
collision this whole design exists to avoid, so the probe keeps Continuity out
of the test loop entirely.

It depends on `SkrepkaSync` and *not* on `SkrepkaCore`, so it stays buildable on
Linux and becomes the Phase 6 smoke-test binary for free.

Subcommands: `advertise`, `pair`, `list`, `add <text>`, `pin <hash>`,
`delete <hash>`, `dump`. Enough to drive every case in the runbook below from a
terminal.

## The runbook

Manual, because none of it is reproducible in CI. Launch the app with
`scripts/run.sh`, not by executing the binary — TCC attributes permissions to
the responsible process.

1. **Pairing.** Probe advertises, Mac discovers it, both show the same SAS,
   both confirm, both persist the pin. Relaunch both; they reconnect without
   asking again.
2. **Mismatch.** Tamper with one side's SAS display and confirm the user
   refusing it leaves nothing paired on either end.
3. **History both ways.** Copy on the Mac, it appears in `probe list`. `probe
   add` a string, it appears in the picker.
4. **Live push is on**, because the probe advertises `plat=linux`. The pushed
   item lands on the Mac's pasteboard.
5. **No echo loop.** A pushed item does not come back. Watch for a repeating
   pair of frames, not just for a duplicate row — de-duplication would hide the
   loop while the traffic continued.
6. **Pins propagate**, in both directions, and an unpin propagates too.
7. **Deletes do not resurrect.** Delete on the Mac, force a re-sync, confirm it
   stays deleted.
8. **Retention leaves the peer alone.** Set the Mac to keep 10 items, push 50
   from the probe, confirm the probe still holds all 50 and the Mac holds 10.
   Then re-sync and confirm the Mac does not tombstone the other 40.
9. **Concealed content never crosses.** Copy from a password manager, confirm
   nothing about it reaches the probe — check `probe dump`, not just
   `probe list`.
10. **Large payloads.** A 20 MB screenshot transfers by chunked fetch, resumes
    after the connection is killed mid-transfer, and never blocks a small live
    push queued behind it.
11. **Flip the probe to `plat=macos`.** Live push defaults off, and the row says
    why.
12. **Unpair** removes the pin, and the ex-peer cannot reconnect.

Record the result of each numbered step. "It worked" for a twelve-step runbook
is not a result.

## Tests

Automated where it is honest to automate:

| Test | Asserts |
|---|---|
| `SyncCoordinatorTests.livePushSuppressesEcho` | a received hash is not re-broadcast, over the hash set rather than the pause window |
| `SyncCoordinatorTests.recentHashSetIsBounded` | by count and by age |
| `SyncCoordinatorTests.livePushOffForApplePeers` | at the coordinator, not only in the model |
| `HistoryStoringTests` | run against both `HistoryStore` and `ProbeStore`, same suite, same assertions |

No test asserts a SwiftUI view can be constructed. The runbook covers the UI and
the repo's conventions say so explicitly.

## Done when

- Every numbered runbook step has a recorded result.
- `scripts/doctor.sh` green.
- `HistoryStoringTests` passes against both conformances.
- The user-facing story is true: two Macs share clipboard *history*, with pins
  and search, and neither one fights Universal Clipboard. Per
  [D-2](open-questions.md#d-2) that is a thing the release notes mention rather
  than lead with — the headline is Linux, and it arrives in Phase 6.

## Risks

**The protocol has a flaw that only shows on a real network.** Loopback hides
latency, reordering, MTU and half-open connections. Mitigate cheaply: run the
probe on a second physical machine over Wi-Fi for step 3 onward, even though it
is still a Mac. It costs nothing and it is the last chance to find a framing bug
before Linux is also in the picture.

**Shipping Mac↔Mac sync commits to supporting it.** Once it is in a release it
has users, and the merge model, the wire format and the pairing UX are frozen
for anyone who paired — whatever the feature was *sold* as.
[D-2](open-questions.md#d-2) settles the positioning (Mac↔Linux is the goal;
Mac↔Mac falls out of the same code) but not the obligation. Version the protocol
from day one and be willing to refuse an incompatible peer, or this phase writes
a forever-compatibility promise nobody meant to make.

**Live push writes the wrong thing.** The failure is silent and destructive: the
user's clipboard is replaced by something they did not copy. Bound it — never
write while the picker is open, never write more than once per received frame,
and make the first release's default conservative.
