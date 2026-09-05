# Linux Skrepka and LAN sync — implementation plan

**Status: committed to, and not started.** All eight phases are in scope
([D-6](open-questions.md#d-6), 2026-09-05) and no code exists for any of it yet.
Nine decisions are settled; fourteen research questions are open.

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

The fourteen research questions are all still open.

## Gates

Two things gate the plan and neither is a coding task.

1. **Phase 0 gates the whole design's honesty.** If Universal Clipboard hands
   over a promise rather than bytes, Skrepka has a bug today with no sync
   involved — see [OQ-2](open-questions.md#oq-2).
2. **[OQ-10](open-questions.md#oq-10) and [OQ-11](open-questions.md#oq-11) gate
   Phase 4.** Both ask whether Swift on Linux can do a thing this plan assumes
   it can. Spike them *before* Phase 4 commits a month to that answer.

The fourteen research questions are in
[`open-questions.md`](open-questions.md) alongside the nine decisions, which
are settled. Nothing else is waiting on a judgement call — what is left is
work and verification.

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

## Quality gate

`scripts/doctor.sh` stays green on the macOS side throughout — that is the
definition of done in this repo and none of this changes it. Phase 4 establishes
`scripts/doctor-linux.sh` as its equivalent, and Phases 5 through 8 are held to
it.

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
