# Linux Skrepka and LAN sync — implementation plan

**Status, 2026-09-08: Phases 1, 2, 3, 5 and 6 built, Phase 4 done bar its
`doctor-linux` polish, ten of the fourteen research questions answered.** All
eight phases are in scope ([D-6](open-questions.md#d-6)). Ten decisions are
settled. The four questions still open ([OQ-1](open-questions.md#oq-1) to
[OQ-4](open-questions.md#oq-4)) need hardware — a second Apple device, a real
GNOME session, a real KWin session — rather than time.

**Amended 2026-09-07:** one of those three pieces of hardware now exists. A
**Steam Deck OLED** is the Linux test rig ([D-10](open-questions.md#d-10)) — a
real KWin session, a real display and a real LAN neighbour for the Mac. It is a
*stand-in for a proper Linux machine, not a shipping target*: Ubuntu and Fedora
remain what Phase 8 packages for. **Desktop Mode only**; Game Mode is out of
scope in every phase. GNOME work still gets built as planned — only its
*testing* is deferred until a GNOME machine exists. See
[the test hardware](#the-test-hardware).

[Phase 3](phase-3-macos-sync.md) is built and its automatable half is verified:
`SyncCoordinator`, live push both ways, the pairing sheet, the Sync settings pane
and `skrepka-sync-probe`. Nine of its twelve runbook steps are now driven by
[`scripts/probe-runbook.sh`](../../scripts/probe-runbook.sh) — two probe peers
over loopback — and the three that are not need a pasteboard, a password manager
or a second physical machine. **What has not been done is the last inch into
macOS**: nothing has run the app against a live pasteboard, a real Local Network
prompt or a second machine over Wi-Fi. [`phase-3-runbook.md`](phase-3-runbook.md)
records each of the twelve steps and what was actually run against it.

[Phase 5](phase-5-linux-clipboard.md) is built. It needed a real compositor and
it got two, inside the build image: a headless **Sway 1.9** advertising
`zwlr_data_control_manager_v1`, and an **Xvfb** carrying XFIXES. So two of its
three backends are integration-tested against live protocol traffic rather than
demonstrated — 17 tests, with `wl-copy`, `wl-paste` and `xclip` as the other
end. `ExtDataControlBinding` has no compositor anywhere on this project and stays
unit-tested only; the Steam Deck is the first thing to run it against.

[Phase 6](phase-6-linux-daemon.md) is built: `AvahiDiscovery` over D-Bus,
`skrepkad`, the `skrepka` CLI, the `dev.soldunov.Skrepka1` session-bus interface
the Phase 8 GNOME extension will call, and a systemd user unit with a
user-scope `install.sh` beside it. **Its hardware verification is deferred by
decision rather than blocked**: the owner decided on 2026-09-08 that the Steam
Deck is not worth setting up until Phase 7's GUI exists, so the twelve-step
runbook against a real second machine waits for that. Two of its deliverables
were deliberately not built and are recorded at the top of that document — the
vendored `EmbeddedMDNSDiscovery` fallback, and the peer-clock-offset half of the
skew check, which needs a timestamp the wire does not carry.

Next is [Phase 7](phase-7-linux-gui.md) — the Linux GUI, and the widest error
bars on the list. [D-4](open-questions.md#d-4) already routes one failure mode
back here: if neither Swift GUI toolkit can express the floating palette within
a three-day budget, the work stops at Phase 6 rather than escalating.

What is left of [Phase 4](phase-4-core-on-linux.md) is small: its storage week is
done and `scripts/doctor-linux.sh` exists, so only the tooling notes in its
step 8 remain.

What exists today, and both quality gates are green over it:

| | |
|---|---|
| `Sources/SkrepkaSync/` | Phase 1 complete — 96 files, model, canonical-CBOR wire codec (canonical on decode as well as encode: non-shortest heads and out-of-order map keys are refused), merge engine. No networking, no `SkrepkaCore` dependency, green on Linux |
| `Sources/SkrepkaCore/` | compiles on Linux: 71 of 79 files. `ClipboardSource`, the `PasteboardAccess` split, the CryptoKit and logging shims, whole-file guards on the eight that cannot — `PasteboardAccess` is not among them, since only its AppKit initialiser is fenced and the enum itself ports |
| `scripts/linux.sh` | runs any command inside the Linux image — Swift 6.3.3 aarch64, the same version the macOS toolchain ships |
| `scripts/doctor-linux.sh` | the Linux quality gate, Phase 4's step 8, delivered early because everything after Phase 1 needs it |
| `Sources/SkrepkaSync/Pairing/` + `Transport/` + `Discovery/` | Phase 2 — self-signed P-256 identity, the short authentication string, pinned-certificate TLS 1.3 over swift-nio, and Bonjour discovery. `LoopbackSyncTests` pairs, exchanges indexes and fetches a payload on **both** platforms |
| `Sources/SkrepkaCore/Store/` | Phase 2 — three-entity schema, tombstones, the sync surface, and the merge apply path |
| `Sources/SkrepkaCore/Store/SQLite/` | Phase 4's storage half — the Linux `HistoryStoring` conformance over raw SQLite (D-3), and `HistoryStoringTests` running one suite against both engines |
| `docker/Dockerfile.linux` | the Linux build image: Swift 6.3.3, SwiftLint 0.65.1, SQLite 3.45.1, and — from Phase 5 — libwayland, libX11, libXfixes, `wayland-scanner`, and a headless Sway, Xvfb, `wl-clipboard` and `xclip` so the clipboard backends can be *tested* rather than only compiled. Built by `scripts/linux-image.sh` |
| `Sources/Skrepka/Sync/` | Phase 3 — `SyncCoordinator`, split across the extensions that own its lifecycle, its listeners, discovery, pairing, live push and the rows the pane reads; one `PeerLink` per paired peer, the pairing sheet, the peer row, `LivePushReceiver`. Two listeners: the advertised pinned one, and a pairing one that runs only while the user has asked to pair and whose port is the record's new `pair=` key |
| `Sources/SkrepkaSync/Session/` | Phase 3 — `PeerLink` and `SyncExchange`, in the portable target rather than the app so the probe and the Phase 6 daemon drive the same implementation |
| `Sources/SkrepkaProbe/` + `Sources/skrepka-sync-probe/` | Phase 3 — a headless peer that speaks the whole protocol and never touches a pasteboard. `ProbeStore` is the second `HistoryStoring` conformance the shared contract suite runs against |
| `scripts/probe-runbook.sh` | Phase 3 — two probe peers over loopback, asserting nine of the twelve runbook steps |
| `Sources/CWaylandProtocols/` | Phase 5 — both data-control protocols as C, generated by `wayland-scanner` from the XML vendored beside it. Both XML files are checked in: one is packaged by no distribution at all, the other is absent from every LTS older than noble. `scripts/regenerate-wayland-protocols.sh` reproduces every generated file |
| `Sources/SkrepkaLinuxPlatform/` | Phase 5 — `SessionProbe`, one data-control engine behind two protocol bindings, the XFIXES backend with a full ICCCM selection owner, the representation mapping and the diagnostics. The two Wayland readers the plan named collapsed into one: normalising the prefixes off the two protocol XML files leaves 37 identical entries each |
| `Sources/skrepka-clip-probe/` | Phase 5 — the headless proof. `report`, `watch`, `copy` |
| `Sources/SkrepkaIPC/` | Phase 6 — the D-Bus layer: `dev.soldunov.Skrepka1`, the versioned JSON documents both the CLI and the Phase 8 GNOME extension read, the client, and `BusSession`, which is how a scoped `DBusClient` connection outlives the call that opened it |
| `Sources/SkrepkaLinuxPlatform/Discovery/` | Phase 6 — `AvahiDiscovery`, the `PeerDiscovery` conformance over `org.freedesktop.Avahi`. Here rather than beside `BonjourDiscovery` because the *dependency* is what macOS must not carry, not the code. Every signature confirmed against avahi 0.8's own interface XML; its signals are directed at the client's unique name, so no `AddMatch` rule is needed |
| `Sources/SkrepkaDaemon/` | Phase 6 — the composition root, `FileTrustStore` (the `0600`-at-creation identity file), the session-loss rebuild, and the D-Bus service |
| `Sources/SkrepkaCLI/` + `Sources/skrepka-cli/` | Phase 6 — `list`, `copy`, `pair`, `peers`, `doctor`, with `--json` from the start |
| `packaging/systemd/` + `scripts/install.sh` | Phase 6 — the user unit and the no-root installer [D-10](open-questions.md#d-10) forces. Phase 8 hardens both rather than inventing a second layout |
| `scripts/doctor.sh` | **538 tests / 71 suites green** |
| `scripts/doctor-linux.sh` | **659 tests / 90 suites green, SwiftLint included** — 17 of them driving a headless Sway and an Xvfb started by the test |

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
| [8](phase-8-gnome-packaging.md) | GNOME extension, `install.sh`, and packaging | 1 week + review | yes |

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

Nine on 2026-09-05 and one on 2026-09-07, recorded in full in
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
| D-10 | A Steam Deck OLED is the test rig, Desktop Mode only; a user-scope `install.sh` is how builds reach it | [Phase 5](phase-5-linux-clipboard.md), [Phase 6](phase-6-linux-daemon.md), [Phase 7](phase-7-linux-gui.md), [Phase 8](phase-8-gnome-packaging.md) |

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
[`open-questions.md`](open-questions.md) alongside the ten decisions, which
are settled, and the ten answers. Nothing is waiting on a judgement call; what
is left is work, verification, and hardware. One of the three missing pieces
arrived on 2026-09-07: [OQ-4](open-questions.md#oq-4) needed a real KWin session
and [the Steam Deck](#the-test-hardware) is one. Still missing: a second Apple
device ([OQ-1](open-questions.md#oq-1), [OQ-2](open-questions.md#oq-2)) and a
GNOME session ([OQ-3](open-questions.md#oq-3)).

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

- **Phases 5 and 7 need a compositor and a display.** ~~An OrbStack machine has
  neither by default.~~ **Answered 2026-09-07, for Phase 5.** A container needs
  no display: `sway` with `WLR_BACKENDS=headless` runs with no DRM device at
  all, advertises `zwlr_data_control_manager_v1`, and `Xvfb` supplies a real X
  server with XFIXES. Both are in the build image and the Phase 5 integration
  tests drive them. Phase 7 is a different question — a GUI needs pixels
  somebody can look at — and **that is what the Steam Deck is for**, see below.
- **mDNS across the macOS ↔ OrbStack boundary is unverified.** Phase 6's real
  Mac ↔ Linux discovery may or may not work against an OrbStack machine. Worth
  a spike before assuming it stands in for a second physical box. The Deck is on
  the same Wi-Fi as the Mac and settles this by being a second physical box.
- **[OQ-1](open-questions.md#oq-1) and [OQ-2](open-questions.md#oq-2) need a
  second Apple device.** Nothing containerised helps.

One operational note: under Claude Code's default sandbox the Docker socket at
`~/.orbstack/run/docker.sock` is not reachable, so agent-run Linux spikes need
that permission granted first.

### The test hardware

**A Steam Deck OLED, in Desktop Mode**, decided 2026-09-07
([D-10](open-questions.md#d-10)). It is the only real Linux hardware this
project has, and it is a **stand-in for a proper Linux machine rather than a
target the product ships to**. Nothing in the plan gets shaped around SteamOS;
Ubuntu and Fedora stay the Phase 8 packaging targets, and a finding that is true
only of SteamOS is a finding about the rig, not about Skrepka.

What it is, verified 2026-09-07 against Valve's tech specs and the SteamOS 3.8
and 3.9 release coverage:

| | |
|---|---|
| CPU | AMD Zen 2 APU — **`x86_64` only**. No `arm64` hardware exists on this project |
| OS | SteamOS 3.x, Arch-based, **immutable root** with A/B atomic updates |
| Desktop | KDE Plasma in Desktop Mode. **Plasma 6.4.3** on the installed SteamOS 3.8 stable; SteamOS 3.9 preview moves it to 6.7.3 |
| Session | Wayland by default since SteamOS 3.8, with an X11 session still available |
| Screen | 1280×800 at 90 Hz — small, and the picker has to look right on it |

**Game Mode is out of scope.** Everything here happens in Desktop Mode.
gamescope implements no data-control protocol at all (design §4's matrix already
says so), so a clipboard manager has nothing to observe there, and no phase
should spend a line on it.

**Which clipboard backend the rig exercises — corrected 2026-09-07.** This
table used to say the installed channel exercised the `wlr` binding, on the
belief that KWin's port landed in Plasma 6.6. It landed in Plasma **6.4** (merge
request !6606, merged 2025-04-12), and 6.4 advertises **both** globals from one
implementation; 6.5 dropped the legacy one.

| Channel | Plasma | Globals advertised | Binding under test |
|---|---|---|---|
| SteamOS 3.8 stable — **what is installed today** | 6.4.3 | **both** | `ExtDataControlBinding` |
| SteamOS 3.9 preview | 6.7.3 | ext only | `ExtDataControlBinding` |
| Either, X11 session | — | — | `XFixesReader` |

So switching the Deck's channel exercises **one** Wayland reader, not two, and
the deprecated path needed a compositor of its own. It has one: a headless
**Sway 1.9** — wlroots 0.17, `zwlr_data_control_manager_v1` v2 and nothing newer
— in the Linux build image, where the Phase 5 tests drive it directly. That also
answers the "second compositor" worry below, for the legacy protocol at least: a
reader that works against KWin can still be wrong about wlroots, and now both
are checked.

The former *unverified* note here — whether KWin kept the legacy global — is
answered: Plasma 6.4 keeps both, 6.5 and 6.6 keep only `ext`. Which is why
`SessionProbe` prefers `ext` and ignores `wlr` when both appear; binding the
first recognised global would record every copy twice on a 6.4 session.

**What the Deck does not answer:** anything GNOME. [OQ-3](open-questions.md#oq-3)
and the Phase 8 Shell extension still need a GNOME session, so that work gets
**built** on schedule and **tested later** — the extension is written and
submitted against the documented interfaces, and the honest-degradation path
([Phase 5](phase-5-linux-clipboard.md#5-diagnostics)) is what covers users until
someone can run it.

**Getting a build onto it is not `.deb` or `.rpm`.** SteamOS's root filesystem is
read-only, `steamos-readonly disable` is undone by the next OS update, and with
systemd-sysext extensions merged `/usr` stays read-only even then. So the rig is
fed by a **user-scope installer** — a `curl`-able shell script that puts binaries
under `~/.local/bin`, desktop entries under `~/.local/share/applications` and the
systemd user unit under `~/.config/systemd/user`, all of which survive an OS
update because `/home` does. That script is a
[Phase 8](phase-8-gnome-packaging.md#0-the-user-scope-installer) deliverable and
it is useful well beyond the Deck: it is the no-root install path for any
distribution, including the ones nobody packages for.

Flatpak would be the SteamOS-native answer and it stays **out**, for the reason
Phase 8 already records: a sandboxed client is refused the data-control globals.
The immutable-distribution case makes that ruling more consequential, not less.

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
