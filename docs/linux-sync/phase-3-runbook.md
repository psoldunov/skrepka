# Phase 3 — runbook results

The twelve steps [Phase 3](phase-3-macos-sync.md) makes its definition of done,
with what was actually run against each one and what was not.

**Read the second column first.** Nine of the twelve are now driven by
[`scripts/probe-runbook.sh`](../../scripts/probe-runbook.sh), which stands two
`skrepka-sync-probe` peers up over loopback and asserts on what they print.
Three are not, and cannot be: they need a real pasteboard, a password manager, or
a second physical machine, and a runbook that pretended otherwise would be worth
less than one that says so.

Date of this record: 2026-09-06. Re-run it with:

```
swift build --product skrepka-sync-probe
scripts/probe-runbook.sh
```

It is deliberately not part of `scripts/doctor.sh`: it starts two processes,
opens sockets and waits on wall-clock time, and a gate that does those things
fails for reasons that have nothing to do with the change under test. It was run
five times while this was written and was green each time.

---

## The twelve steps

| # | Step | Covered by | Result |
|---|---|---|---|
| 1 | **Pairing** — same code both sides, both persist, relaunch reconnects | `probe-runbook.sh cross` | **Pass.** Both ends derive the same eight characters; the initiator pins the peer; a relaunch against the same stores keeps the device identity, keeps the pin, and raises no second sheet. |
| 2 | **Mismatch** — refusing leaves nothing paired on either end | `probe-runbook.sh apple` | **Pass, by the refusal path.** The probe is told to `reject`; the initiator reports "the peer declined the pairing" and neither side records a peer. See the note below on what this does *not* prove. |
| 3 | **History both ways** | `probe-runbook.sh cross` | **Pass.** Each peer holds the other's clipping after one exchange in each direction. |
| 4 | **Live push is on**, because the probe advertises `plat=linux` | `probe-runbook.sh cross` (protocol half) | **Partial.** The push crosses the wire and the receiving peer stores it. **Landing on the Mac's pasteboard is not covered** — the probe has no clipboard, which is the point of it. |
| 5 | **No echo loop** | `RecentHashesTests`, `LivePushPolicyTests` | **Partial.** The suppression rule is asserted directly: a hash accepted from a peer is not re-broadcast, the set is bounded by count and by age, and suppression lapses so a deliberate re-copy still syncs. **A real two-machine loop is not exercised**, because reproducing one needs two pasteboards. |
| 6 | **Pins propagate**, both directions, and an unpin too | `probe-runbook.sh cross` | **Partial.** A pin made on one peer reaches the other. **The unpin direction is not driven**; the register it rides on is the same one, and `LWWRegisterTests` covers the ordering. |
| 7 | **Deletes do not resurrect** | `probe-runbook.sh cross` | **Pass.** Deleted on one peer, two forced re-syncs later it is still gone from the other. |
| 8 | **Retention leaves the peer alone** | `HistoryStoringTests`, `MergeEngineTests` | **Not run end to end.** The probe has no retention policy to set. The rule is unit-tested from both sides: eviction writes no tombstone, and the merge engine never emits one for an item merely absent locally. |
| 9 | **Concealed content never crosses** | `HistoryStoringContractTests`, `HistoryStoringTests` | **Partial.** Every `HistoryStoring` conformance is asserted to filter concealed content out of *both* the index and the payload, and to refuse one offered by a peer. **The end-to-end path — copy from a password manager on the Mac, check `probe dump` — is not automatable** and has not been run. |
| 10 | **Large payloads** — chunked fetch, resume after a kill, never blocking a small push | `LivePushTests`, `LoopbackSyncTests` | **Partial.** A payload over `SyncLimits.livePushInlineLimit` is asserted to cross as metadata alone, leaving the peer to fetch; chunked fetch itself is covered by the loopback suite. **Resuming after the connection is killed mid-transfer has not been tested.** |
| 11 | **`plat=macos` turns live push off**, and the row says why | `probe-runbook.sh apple`, `LivePushPolicyTests` | **Pass.** Two `plat=macos` peers exchange history and never live-push. The reason a row shows is asserted as a value; the row itself is a SwiftUI view and is not. |
| 12 | **Unpair** — the pin goes and the ex-peer cannot reconnect | `probe-runbook.sh apple` | **Pass.** After an unpair the ex-peer's next handshake is refused at TLS with `SSLV3_ALERT_CERTIFICATE_UNKNOWN`, which is the pinning callback doing its job. |

---

## What the automated half does not prove

**Step 2 tests a refusal, not a mismatch.** The probe cannot show a *wrong*
code — the string is derived from two public keys and a timestamp, so producing a
different one on one side means changing the derivation, which is testing the
test. What is asserted is the outcome the step cares about: a user who says no
leaves nothing paired on either end. `ShortAuthStringTests` covers the
derivation, and `PairingSessionTests` covers a `pairConfirm` carrying a string
that does not match.

**Nothing here touches a pasteboard.** That is deliberate and it is the reason
the probe exists: two Mac desktop sessions would put Universal Clipboard back in
the test loop, which is exactly the collision design §3 is written to avoid. The
consequence is that the last hop of live push — `LivePushReceiver` writing
through `PasteService` — is exercised by nothing but the app itself.

**Nothing here runs over a real network.** Everything is loopback, which hides
latency, reordering, MTU and half-open connections. Phase 3's own Risks section
says so and asks for a second physical machine over Wi-Fi. That has not happened.

---

## Still needing a person at the keyboard

Launch with `scripts/run.sh`, not by executing the binary: TCC attributes
permissions to the responsible process, so a shell-launched binary inherits the
terminal's grants instead of exercising the real permission path.

1. **Local Network permission.** The first browse should raise the system
   prompt. `Info.plist` now carries `NSBonjourServices` and
   `NSLocalNetworkUsageDescription`, which `NSNetServices.h` documents as
   required — untested against a live prompt.
2. **Steps 4, 5 and 9 end to end**, against a real pasteboard and a real password
   manager.
3. **Step 10's resume**, by killing a transfer part-way.
4. **The Risks section's second machine**, over Wi-Fi rather than loopback.

Until those are done, the honest statement about this phase is that the protocol
and the storage are exercised and the *last inch into macOS* is not.

---

## Driving the probe by hand

```
swift build --product skrepka-sync-probe
.build/debug/skrepka-sync-probe run --dir ~/probe --platform linux --pair --confirm-pairing
```

It prints its identity, its two ports and where its store is, then takes commands
on standard input — `help` lists them. The two ports are different and both
matter: `pairing` accepts a device that has never paired with this one, `sync`
accepts one that has. On a network with no mDNS, `connect HOST PAIRING_PORT
SYNC_PORT` pairs and records where to reach the peer afterwards.

`sync` forces an index exchange rather than waiting out `PeerLink.resyncInterval`
— which is what step 7's "force a re-sync" needs. The Mac has the same thing as
the **Sync Now** button in Settings ▸ Sync.
