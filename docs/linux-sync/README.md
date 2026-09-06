# Linux Skrepka and LAN sync — implementation plan

**Status, 2026-09-06: Phases 1, 2 and 3 built, Phase 4 done bar its
`doctor-linux` polish, ten of the fourteen research questions answered.** All
eight phases are in scope ([D-6](open-questions.md#d-6)). Nine decisions are
settled. The four questions still open ([OQ-1](open-questions.md#oq-1) to
[OQ-4](open-questions.md#oq-4)) need hardware — a second Apple device, a real
GNOME session, a real KWin session — rather than time.

[Phase 3](phase-3-macos-sync.md) is built and its automatable half is verified:
`SyncCoordinator`, live push both ways, the pairing sheet, the Sync settings pane
and `skrepka-sync-probe`. Nine of its twelve runbook steps are now driven by
[`scripts/probe-runbook.sh`](../../scripts/probe-runbook.sh) — two probe peers
over loopback — and the three that are not need a pasteboard, a password manager
or a second physical machine. **What has not been done is the last inch into
macOS**: nothing has run the app against a live pasteboard, a real Local Network
prompt or a second machine over Wi-Fi. [`phase-3-runbook.md`](phase-3-runbook.md)
records each of the twelve steps and what was actually run against it.

Next is [Phase 5](phase-5-linux-clipboard.md), which needs a real compositor.

What is left of [Phase 4](phase-4-core-on-linux.md) is small: its storage week is
done and `scripts/doctor-linux.sh` exists, so only the tooling notes in its
step 8 remain.

What exists today, and both quality gates are green over it:

| | |
|---|---|
| `Sources/SkrepkaSync/` | Phase 1 complete — 29 files, model, canonical-CBOR wire codec (canonical on decode as well as encode: non-shortest heads and out-of-order map keys are refused), merge engine. No networking, no `SkrepkaCore` dependency, green on Linux |
| `Sources/SkrepkaCore/` | compiles on Linux: 24 of 34 files. `ClipboardSource`, the `PasteboardAccess` split, the CryptoKit and logging shims, file-scope guards on the ten that cannot |
| `scripts/linux.sh` | runs any command inside the Linux image — Swift 6.3.3 aarch64, the same version the macOS toolchain ships |
| `scripts/doctor-linux.sh` | the Linux quality gate, Phase 4's step 8, delivered early because everything after Phase 1 needs it |
| `Sources/SkrepkaSync/Pairing/` + `Transport/` + `Discovery/` | Phase 2 — self-signed P-256 identity, the short authentication string, pinned-certificate TLS 1.3 over swift-nio, and Bonjour discovery. `LoopbackSyncTests` pairs, exchanges indexes and fetches a payload on **both** platforms |
| `Sources/SkrepkaCore/Store/` | Phase 2 — three-entity schema, tombstones, the sync surface, and the merge apply path |
| `Sources/SkrepkaCore/Store/SQLite/` | Phase 4's storage half — the Linux `HistoryStoring` conformance over raw SQLite (D-3), and `HistoryStoringTests` running one suite against both engines |
| `docker/Dockerfile.linux` | the Linux build image: Swift 6.3.3, SwiftLint 0.65.1, SQLite 3.45.1. Built by `scripts/linux-image.sh` |
| `Sources/Skrepka/Sync/` | Phase 3 — `SyncCoordinator` and its five halves, one `PeerLink` per paired peer, the pairing sheet, the peer row, `LivePushReceiver`. Two listeners: the advertised pinned one, and a pairing one that runs only while the user has asked to pair and whose port is the record's new `pair=` key |
| `Sources/SkrepkaSync/Session/` | Phase 3 — `PeerLink` and `SyncExchange`, in the portable target rather than the app so the probe and the Phase 6 daemon drive the same implementation |
| `Sources/SkrepkaProbe/` + `Sources/skrepka-sync-probe/` | Phase 3 — a headless peer that speaks the whole protocol and never touches a pasteboard. `ProbeStore` is the second `HistoryStoring` conformance the shared contract suite runs against |
| `scripts/probe-runbook.sh` | Phase 3 — two probe peers over loopback, asserting nine of the twelve runbook steps |
| `scripts/doctor.sh` | **435 tests / 57 suites green** |
| `scripts/doctor-linux.sh` | **365 tests / 46 suites green, SwiftLint included** |

Two things the plan assumed and that turned out to be false, both recorded in
[`open-questions.md`](open-questions.md): `SwiftCBOR` is unsuitable and the codec
is hand-rolled ([OQ-8](open-questions.md#oq-8)), and `Network.swiftinterface`
does ship after all, so the installed interface outranks Apple's documentation
for every Network framework signature ([OQ-7](open-questions.md#oq-7)).

This directory is the executable half of
[`docs/linux-sync-consideration.md`](../linux-sync-consideration.md). That
document is the *design* — what the idea is, why it is shaped this way, what was
verified and what was not. This directory is the *plan* — what to build, in what
order, with which files, and how each step proves itself.

Read the design first. The plan does not repeat its reasoning; it references it
by section (`design §7` means section 7 of that document).

Date of this plan: 2026-09-05, against `SkrepkaCore` at 33 files / 2277 lines.
The per-file port analysis in [Phase 4](phase-4-core-on-linux.md) was measured
from that tree and will drift as the tree grows — re-measure before starting it.

---

## The phases

| Phase | Deliverable | Size | Ships to a user? |
|---|---|---|---|
| [0](phase-0-universal-clipboard-spike.md) | Universal Clipboard spike, and possibly a standalone bug fix | ½ day | maybe — a bug fix |
| [1](phase-1-sync-core.md) | `SkrepkaSync` — model, wire, merge, all pure | 2–3 days | no |
| [2](phase-2-plumbing.md) | Storage, identity, transport, discovery | 1 week | no |
| [3](phase-3-macos-sync.md) | macOS sync, proven against `skrepka-sync-probe` | 1 week | **yes — Mac↔Mac history sync** |
| [4](phase-4-core-on-linux.md) | `SkrepkaCore` compiling and passing its tests on Linux | 1–1½ weeks | no |
| [5](phase-5-linux-clipboard.md) | Linux clipboard read/write, headless | 1½ weeks | no |
| [6](phase-6-linux-daemon.md) | **Linux daemon — real Mac ↔ Linux sync** | 1½ weeks | **yes — CLI-driven** |
| [7](phase-7-linux-gui.md) | Linux GUI | 2–3 weeks | yes |
| [8](phase-8-gnome-packaging.md) | GNOME extension and packaging | 1 week + review | yes |

Estimates assume the person doing the work already knows this codebase. They are
working days of focused effort, not calendar time, and Phase 7 has the widest
error bars on the list.

## Dependency order

```
0 ─── (independent; do it first anyway)

1 ─── 2 ─── 3 ─── (macOS sync ships here)
       │
       └─── 4 ─── 5 ─── 6 ─── 7 ─── 8
                         │
                         └── (Mac ↔ Linux sync works here)
```

Phase 4 depends on Phase 2 rather than Phase 3, because what it ports is
`SkrepkaCore` and `SkrepkaSync`, not the app. In practice Phase 3 is worth
finishing first anyway: it is the last chance to find a protocol mistake while
both peers are still on one machine and one language.

## The target, and the two escape hatches

**All eight phases are in scope** ([D-6](open-questions.md#d-6), decided
2026-09-05). **Mac ↔ Linux is the goal**; Mac↔Mac ships because it falls out of
the same code rather than as a headline feature ([D-2](open-questions.md#d-2)).

Two points on the way are real products, and they are worth knowing about as
exits rather than as plans:

**After Phase 3** — macOS users have history sync between their own Macs, with
pins and search crossing devices. Nothing has been spent on Linux. Universal
Clipboard is untouched, because live push stays off for Mac↔Mac pairs
(design §3).

**After Phase 6** — the actual goal is met. A Linux box and a Mac share history
over the LAN, live push bridges the gap Apple leaves, and the interface is a
CLI. Phases 7 and 8 are the expensive half and they buy polish, not capability.

[D-4](open-questions.md#d-4) already routes one failure mode back to Phase 6: if
neither Swift GUI toolkit can express the floating palette within a three-day
budget, the work stops there rather than escalating.

If the project has to stop somewhere, stop at one of those two. Stopping
mid-phase leaves a half-ported target that nothing builds.

## Decisions already taken

Nine, on 2026-09-05, recorded in full in
[`open-questions.md`](open-questions.md):

| # | Decision | Lands in |
|---|---|---|
| D-6 | Build all eight phases | the whole plan |
| D-2 | Mac↔Linux is the goal; Mac↔Mac is incidental | [Phase 3](phase-3-macos-sync.md) |
| D-1 | Continuity clips: fetch on demand, if OQ-2 says promise | [Phase 0](phase-0-universal-clipboard-spike.md) |
| D-3 | Raw SQLite, not GRDB | [Phase 4](phase-4-core-on-linux.md) |
| D-4 | 3-day toolkit budget, then stop at Phase 6 | [Phase 7](phase-7-linux-gui.md) |
| D-5 | Ship the GNOME extension, kept thin | [Phase 8](phase-8-gnome-packaging.md) |
| D-7 | Concealed items never sync; no toggle in v1 | [Phase 2](phase-2-plumbing.md) |
| D-8 | One machine, expendable history — migration is not a constraint | [Phase 2](phase-2-plumbing.md) |
| D-9 | The Mac app stays native; the Linux port never degrades it | [Phase 2](phase-2-plumbing.md), [Phase 4](phase-4-core-on-linux.md) |

Ten of the fourteen research questions were answered on 2026-09-05.

## Gates

Two things gated the plan and neither was a coding task. One is cleared; the
other still needs hardware.

1. **[OQ-10](open-questions.md#oq-10) and [OQ-11](open-questions.md#oq-11) gated
   Phase 4** — both asked whether Swift on Linux can do a thing this plan
   assumes it can, and both came back **yes**. `Observation` works, `@MainActor`
   works, and Avahi is reachable from Swift over D-Bus without shelling out.
   Swift is the right language for the Linux side.
2. **Phase 0 still gates the design's honesty.** If Universal Clipboard hands
   over a promise rather than bytes, Skrepka has a bug today with no sync
   involved — see [OQ-2](open-questions.md#oq-2). It needs a second Apple
   device, so nothing here can close it.

The four questions still open — [OQ-1](open-questions.md#oq-1) to
[OQ-4](open-questions.md#oq-4) — are in
[`open-questions.md`](open-questions.md) alongside the nine decisions, which
are settled, and the ten answers. Nothing is waiting on a judgement call; what
is left is work, verification, and three pieces of hardware.

## The Linux environment

**OrbStack, already installed on the development machine.** Verified 2026-09-05:
Docker engine 29.4.0, `aarch64` Linux, 14 CPUs, ~16 GB. It covers both shapes
this plan needs.

| Need | Mechanism |
|---|---|
| A Swift toolchain from Phase 1 onward | a `swift:6.x` container |
| "A VM pinned to the target distributions" (Phase 4) | `orb create ubuntu` / `orb create fedora` — full machines, not containers |
| Clean-install tests (Phase 8) | one throwaway machine per distribution |
| `x86_64` packaging alongside `arm64` | the `orbstack` buildx builder reports `linux/amd64`, `linux/arm64`, `linux/ppc64le`, `linux/s390x` and more |

Supported versions, from `orb create --help` on 2026-09-05: **ubuntu**
jammy/22.04, noble/24.04, questing/25.10, resolute/26.04; **fedora** 42, 43, 44.
Both Phase 8 targets, covered.

**What it does not solve**, so nobody plans around it:

- **Phases 5 and 7 need a compositor and a display.** An OrbStack machine has
  neither by default. Whether headless Sway works inside one is exactly the
  question Phase 5 leaves open, and it is untested.
- **mDNS across the macOS ↔ OrbStack boundary is unverified.** Phase 6's real
  Mac ↔ Linux discovery may or may not work against an OrbStack machine. Worth
  a spike before assuming it stands in for a second physical box.
- **[OQ-1](open-questions.md#oq-1) and [OQ-2](open-questions.md#oq-2) need a
  second Apple device.** Nothing containerised helps.

One operational note: under Claude Code's default sandbox the Docker socket at
`~/.orbstack/run/docker.sock` is not reachable, so agent-run Linux spikes need
that permission granted first.

**`scripts/linux.sh` is the entry point**, added 2026-09-05, over the image
`scripts/linux-image.sh` builds from `docker/Dockerfile.linux`. It runs any command
inside `swift:6.3-noble` with the repository bind-mounted at the same absolute
path it has on the host, as the host user, building into `.build-linux` rather
than `.build` — the two toolchains produce incompatible module caches and
sharing one scratch directory forces a full rebuild on every switch. The image
is pinned to Swift **6.3.3**, the same version the macOS toolchain ships, because
"compiles on Linux" is only a useful claim when the two compilers agree on the
language.

## Quality gate

`scripts/doctor.sh` stays green on the macOS side throughout — that is the
definition of done in this repo and none of this changes it.
`scripts/doctor-linux.sh` is its Linux equivalent and **already exists**: Phase 4
nominally delivers it, but everything from Phase 1 onward needs it, so it was
written early. It re-enters the container by itself when run from macOS and runs
natively on Linux.

Two findings live inside that script because they are the kind of thing that
gets "simplified" back out:

- **`swift test` has neither `--product` nor `--target`.** It builds the whole
  package, so `--filter` selects what *runs*, never what *compiles*.
  `Package.swift` therefore fences the macOS-only app target out on Linux with a
  `#if os(macOS)` append after the `Package(...)` call — a `#if` is not valid as
  a container-literal element.
- **Repeated `--target` is a false green.** `swift build --target A --target B`
  exits 0 while building only the last one. Any gate written that way lies. The
  `SkrepkaLinux` product covers both portable targets in one invocation, and it
  has to be `type: .static` — `--product` refuses an automatic library product
  and silently falls back to building everything.

## Shape of each phase document

Every phase document has the same seven headings, so they can be read
side by side:

- **Goal** — one sentence.
- **Preconditions** — phases and open questions that must be settled first.
- **Deliverables** — the files that exist when the phase is done.
- **Work** — numbered, ordered, each step a bounded unit.
- **Tests** — named, with what each asserts.
- **Done when** — checks someone else could run to verify the claim.
- **Risks** — what could go wrong, and what to do about it.

## A standing constraint

`Sources/SkrepkaSync/` must compile on Linux from the day it is created, even
though nothing on Linux consumes it until Phase 6. That constraint is the only
thing stopping macOS assumptions accumulating in the one target both platforms
link. It costs nothing in Phase 1 and saves a week in Phase 4.
