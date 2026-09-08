# Phase 6 — The Linux daemon

**A week and a half. This is the milestone the whole idea is for.**

**Status, 2026-09-08: built, and its hardware verification is deferred by
decision rather than blocked.** `AvahiDiscovery`, `skrepkad`, `skrepka`, the
D-Bus interface and the systemd user unit all exist and both quality gates are
green over them — `scripts/doctor.sh` at 538 tests / 71 suites,
`scripts/doctor-linux.sh` at 572 tests / 75 suites. What has *not* happened is
the twelve-step runbook against a real second machine, which is what the "done
when" below is written as: **the owner decided on 2026-09-08 that the Steam Deck
is not worth setting up until Phase 7's GUI exists**, so those steps wait for
that rather than for this phase. Nothing here is blocked on them; Phase 7 can
start.

Two things in the deliverables below were **not** built, both deliberately and
both recorded here rather than quietly dropped:

- **`EmbeddedMDNSDiscovery` and `Sources/CmDNS/`.** The vendored responder is
  this plan's own last resort — work item 1 says the ordering "is not a
  preference, it is forced", and every distribution the project targets
  (Ubuntu, Fedora, SteamOS) ships `avahi-daemon`. It would be dead code
  everywhere it can currently run, with a real hazard attached: `mdns.h` sets
  `SO_REUSEADDR` and `SO_REUSEPORT` so co-binding works for *multicast*, while
  only one process receives **unicast** replies on 5353, so an embedded
  responder started beside a live avahi breaks discovery for both. What exists
  instead is the seam: `AvahiDiscovery.probe()` answers
  `DiscoveryError.responderUnavailable` with a reason, the daemon steps over it
  rather than refusing to start, and `skrepka doctor` reports
  `network.responder: none` with that reason. A second conformance drops in
  behind `PeerDiscovery` without a redesign, and
  `AvahiDiscoveryTests.exactlyOneResponderExists` is the assertion whoever adds
  it has to change deliberately.
- **The clock-skew check the Risks section asks for**, in the form it asks for
  it. "Reporting the offset against a paired peer" needs a timestamp on the
  wire, and there is none: `PeerIdentity`'s `hello` carries a device
  identifier, a name, a platform and a protocol version. A `clockOffsetSeconds`
  field was written, found to be structurally always nil, and removed — a field
  that reads as "no skew" when it means "never measured" is worse than an
  absent one. What replaced it is `ClockCheck`, which asks
  `org.freedesktop.timedate1` whether *this* machine's clock has been set by a
  time server and puts the answer in `skrepka doctor`'s problems. That covers
  the case the risk names — "a Linux box that has not run NTP" — and does not
  cover a peer that is wrong. Closing the rest needs a protocol change, and
  belongs to whichever phase next opens the wire.

Two gaps found in review and shipped deliberately, both recorded where the code
is as well as here:

- **`BusSession` does not notice a bus connection that has died.** An
  `avahi-daemon` restart *is* handled — `AvahiDiscovery+Reconnect.swift` watches
  `Server.StateChanged`, and that is the common case — but a `dbus-daemon`
  restart is not, so `skrepkad` would stay running with a bus name nothing can
  reach until it is restarted. The obvious mechanism does not work and this is
  worth writing down so it is not tried again: `DBusClient.withConnection` runs
  its reply loop in a *separate* task and awaits the handler beside it
  (`DBusClient.swift:398-431`), and the body runs under
  `asyncChannel.executeThenClose`, which does not cancel the body when the
  channel closes — so the parked task never unwinds on transport death, and the
  signal-stream route fails identically because those streams end only in
  `Connection.deinit` and two live references keep it alive. What would work is
  invalidating the session when a *call* fails in a transport-shaped way, which
  the now-wired `callTimeout` and `probeTimeout` already surface. That touches
  error handling across three modules and was judged too wide to take at the
  end of this phase. The consequence is bounded: a `dbus-daemon` restart ends
  the graphical session on every platform this targets, and the workaround is
  `systemctl --user restart skrepkad`.
- **`HistorySchema` has three concurrency windows, and they are Phase 4's rather
  than this phase's.** Found while checking that two daemons racing one database
  is safe. `installedVersion` is read outside the `BEGIN IMMEDIATE`, so two
  processes upgrading one file both compute from a stale version and the loser
  re-runs `ALTER TABLE`; the four `CREATE` scripts run autocommitted, so a
  concurrent reader can see `clip` present and `paired_device` absent; and
  `journal_mode = WAL` is set before `busy_timeout` in the same pragma string,
  so the one statement needing an exclusive lock runs with no busy timeout.
  **None is reachable in production as this phase leaves it**, because
  `DaemonRunner` claims the D-Bus name before anything opens the store, so a
  second `skrepkad` exits before it touches a file. Reported rather than fixed:
  the fix belongs beside the schema, not in a Phase 6 diff.

## Goal

A Mac and a Linux box pair over the LAN and share history both ways, with live
push bridging the gap Apple leaves. The interface is a CLI, and that is enough
to be useful.

## Preconditions

- Phases 4 and 5 done.
- **[OQ-10](open-questions.md#oq-10) already answered** — it was spiked before
  Phase 4 precisely so this phase is not where Avahi-from-Swift is discovered to
  be a problem.
- Phase 3's runbook results to hand. Every numbered step there gets re-run here
  against a real second machine, and the results should be comparable.
- **The real second machine is the Steam Deck**, on the same Wi-Fi as the Mac
  ([D-10](open-questions.md#d-10)). That is what closes the gap the README's
  Linux-environment section flags: mDNS across the macOS ↔ OrbStack boundary was
  never verified, and now it does not have to be. Desktop Mode only.
- **The daemon gets onto it through `install.sh`, not a package** — SteamOS has
  an immutable root, so the user unit lands in `~/.config/systemd/user` and the
  binaries in `~/.local/bin`. The installer is a
  [Phase 8](phase-8-gnome-packaging.md#0-the-user-scope-installer) deliverable;
  if Phase 6 is being run before it exists, write the throwaway version of it
  here and let Phase 8 harden it rather than inventing a second layout.

## Deliverables

Planned:

```
Sources/SkrepkaSync/Discovery/
  AvahiDiscovery.swift              # D-Bus path
  EmbeddedMDNSDiscovery.swift       # vendored responder fallback
Sources/CmDNS/                      # vendored mjansson mdns.h + module map

Sources/skrepkad/
  main.swift
  Daemon.swift                      # the composition root
  DBusInterface.swift
  SessionPaths.swift                # XDG directories

Sources/skrepka/                    # the CLI
  main.swift
  Commands/{List,Copy,Pair,Peers,Doctor}.swift

packaging/systemd/skrepkad.service  # user unit
```

Built, 2026-09-08:

```
Sources/SkrepkaIPC/                 # the D-Bus layer: interface, documents, client
Sources/SkrepkaLinuxPlatform/Discovery/
  AvahiDiscovery{,+Advertising,+Browsing,+Resolution}.swift
  AvahiNames.swift AvahiSignals.swift
Sources/SkrepkaLinuxPlatform/Diagnostics/ClockCheck.swift
Sources/SkrepkaDaemon/              # the daemon, as a library so it can be tested
Sources/skrepkad/main.swift
Sources/SkrepkaCLI/                 # the CLI, likewise
Sources/skrepka-cli/main.swift
packaging/systemd/skrepkad.service  scripts/install.sh
```

Four differences from the plan, each with a reason:

- **`AvahiDiscovery` is in `SkrepkaLinuxPlatform`, not `SkrepkaSync`.** The
  `wendylabsinc/dbus` package resolves on macOS perfectly well, so leaving the
  dependency unconditional would pull D-Bus, swift-nio-extras and
  swift-algorithms into the Mac app's graph to compile nothing — the Linux tax
  [D-9](open-questions.md#d-9) exists to refuse. `SkrepkaLinuxPlatform` is
  already Linux-only and already depends on `SkrepkaSync`.
- **Hand-written D-Bus proxies, not the `DBusCodegenPlugin`**, which
  [OQ-10](open-questions.md#oq-10) recommends. The surface needed is eight
  method calls and six signals; written by hand it is ~150 lines that sit under
  this repository's own quality bar, and the decoding splits into
  `AvahiSignals` — pure functions over a `[DBusValue]` body, which is exactly
  what makes `AvahiSignalsTests` able to drive captured payloads with no live
  daemon, as the Tests table asks. Generated proxies would have had to live in
  a target with `treatAllWarnings(as: .error)` relaxed. Every signature was
  confirmed against avahi 0.8's own interface XML rather than written from
  memory.
- **The daemon and the CLI are each a library plus a thin executable**, the
  split `SkrepkaProbe`/`skrepka-sync-probe` already makes: `swift test` cannot
  import an executable target, and a composition root with no tests is where a
  wiring mistake hides longest. The CLI's entry point is at
  `Sources/skrepka-cli/` rather than `Sources/skrepka/` because macOS
  filesystems are case-insensitive and `Sources/Skrepka/` is the app target —
  the two are one directory there. The target is still named `skrepka`, via an
  explicit `path:`.
- **`skrepka doctor` reads a `DiagnosticsDocument`, not `DiagnosticsSnapshot`.**
  Work item 3 asks for the shared shape so the CLI and the Phase 7 GUI cannot
  drift, and that is what this is — one document, both readers. It is not
  `DiagnosticsSnapshot` because that type answers macOS questions (a login-item
  approval state, an accessibility grant) and carries none of the Linux ones
  the same work item asks `doctor` to report plainly: which backend was chosen,
  whether the GNOME extension is needed and missing, whether a responder is
  running. Filling the macOS fields with constants would have been inventing
  facts.

## Work

### 1. `AvahiDiscovery`

Avahi over D-Bus when `avahi-daemon` is running; the vendored responder only as
a fallback. That ordering is not a preference, it is forced: `mdns.h` sets
`SO_REUSEADDR` and `SO_REUSEPORT` so co-binding works for *multicast*, but only
one process receives **unicast** replies on port 5353 — the documented conflict
with Avahi and `systemd-resolved`. Running the embedded responder alongside a
live `avahi-daemon` breaks discovery for both.

KDE Connect does this from C++ over the same bus API, so it is clearly possible;
what is unverified is doing it from Swift, whose D-Bus bindings are thin. The
fallbacks, in order, are: generate proxies from
`busctl introspect org.freedesktop.Avahi`, or shell out to `avahi-publish` and
`avahi-browse` and parse them. Shelling out is ugly and it works, and a working
ugly path beats a blocked elegant one — but decide deliberately and write down
why.

Advertise `_skrepka._tcp` with the same TXT record the Mac side publishes, minus
the `fp=` key Phase 1 folded into `id=`.

### 2. Compose the daemon

```
ClipboardBackend (Phase 5)
   → CaptureRules          ported, unchanged
   → HistoryStoring        the SQLite conformance, Phase 4
   → SyncCoordinator       SkrepkaSync, Phases 1–2
   → AvahiDiscovery        this phase
```

The middle two are the ported code. Only the ends are new, and that is the
payoff for Phase 4.

`skrepkad` is the composition root and holds no logic — the same job
`AppCoordinator` does on macOS, and worth reading that file first so the two
stay recognisably the same program.

**Paths follow the XDG basedir spec**, not `~/.skrepka`: the database under
`$XDG_DATA_HOME/skrepka/`, the device key under the same with mode `0600`,
config under `$XDG_CONFIG_HOME/skrepka/`. Create the key file *with* those
permissions rather than chmod'ing it afterwards; the window between the two is
small and real.

### 3. `skrepka`, the CLI

Not a convenience. It is the only interface until Phase 7, and it is what makes
the daemon testable without a window server — which is also what makes it
useful in CI and over SSH.

| Command | Does |
|---|---|
| `skrepka list [--limit n] [--json]` | history, newest first, pinned hoisted |
| `skrepka copy <n\|hash>` | put an entry on the clipboard |
| `skrepka pair [--peer id]` | run pairing, print the SAS, wait for confirmation |
| `skrepka peers` | paired and discovered peers, with live-push state |
| `skrepka doctor` | the Linux equivalent of the Status pane |

`skrepka doctor` reads the same `DiagnosticsSnapshot` the GUI will, so the two
cannot drift. It must report the Phase 5 cases plainly: which backend was
chosen, whether the GNOME extension is present when it is needed, whether
`avahi-daemon` is running or the embedded responder is in use.

`--json` on `list` and `doctor` from the start. It costs nothing and it is what
makes the Phase 8 packaging tests scriptable.

### 4. The D-Bus interface

**Not optional, and not deferrable.** It is how the Phase 8 GNOME Shell
extension talks to the daemon, and designing it now avoids retrofitting an
interface around a JavaScript client written later.

On the session bus, `dev.soldunov.Skrepka`. Minimum surface: submit a captured
clip, request the current selection be set, query history, subscribe to
history-changed. Version it from the first commit — the extension ships through
a review queue and will lag the daemon.

### 5. systemd

A **user** unit, not a system one. It needs the session bus and the Wayland or
X11 display, neither of which a system unit has. `WantedBy=default.target`,
restart on failure, and a `doctor`-shaped failure message in the journal rather
than a stack trace.

## Tests

| Test | Asserts |
|---|---|
| `AvahiDiscoveryTests.parsesServiceRecords` | against captured D-Bus payloads, no live daemon |
| `AvahiDiscoveryTests.fallsBackWhenDaemonAbsent` | and does **not** run both responders at once |
| `SessionPathsTests.honoursXDGVariables` | and the defaults when they are unset |
| `DaemonTests.keyFileIsCreated0600` | at creation, not after |
| `HistoryStoringTests` | the SQLite conformance, again, now under the daemon's real paths |
| CLI golden tests | `list --json` and `doctor --json` output shapes |

The pairing and sync paths are covered by `LoopbackSyncTests` from Phase 2,
which now also runs on Linux. That is worth checking explicitly: the same
integration test, same assertions, on both platforms.

## Done when

Every step of the Phase 3 runbook re-run with a real Linux machine — the Steam
Deck ([D-10](open-questions.md#d-10)) — in place of the probe, and recorded.
Specifically:

1. Mac and Linux box discover each other over the LAN and pair, with matching
   SAS on both.
2. History flows both ways, including pins and deletes.
3. Live push works Mac → Linux **and** Linux → Mac, and is on by default
   because the platforms differ.
4. Retention on one side does not delete on the other.
5. Concealed content does not cross.
6. Killing the network mid-transfer resumes rather than corrupts.
7. `systemctl --user restart skrepkad` reconnects without re-pairing.
8. `skrepka doctor` tells the truth on a machine with something wrong with it —
   test it by breaking something deliberately.
9. The daemon survives the compositor restarting under it: log out and back in,
   or restart KWin or Sway in place, and capture resumes without the user
   touching anything.

Point 9 is [Phase 5](phase-5-linux-clipboard.md#done-when)'s third criterion,
moved here rather than dropped. Phase 5 proves a backend can read and write a
session; noticing that the session has gone and building a new one is a
lifetime question, and the daemon is the thing with a lifetime long enough to
ask it. Concretely: the Wayland `finished` event and a `wl_display` read error
both mean the session is dead, as does the X11 display connection closing, and
the backend has to surface that rather than sit in a loop against a dead file
descriptor. The daemon then re-runs `SessionProbe` — the compositor that comes
back may not be the one that went away, and may not advertise the same globals
— and starts whichever backend that now implies, with a bounded retry so a
session that never returns does not spin. `skrepka doctor` reports the current
backend, so a reconnection that picked a different one is visible rather than
silent.

Both quality gates green.

## Risks

**Avahi from Swift.** [OQ-10](open-questions.md#oq-10), and it is the reason
that question is spiked two phases early. The escape hatch is shelling out to
`avahi-publish`.

**Clock skew between the two machines.** The merge model tolerates it by design
— `createdAt` is `max()` and therefore commutative — but the pin register's LWW
is only as good as the two clocks. A Linux box that has not run NTP can hold a
pin state hostage. Worth a `skrepka doctor` check reporting the offset against a
paired peer, which is cheap and turns a baffling bug into a line of output.

**Firewalls.** Ubuntu ships `ufw` inactive and Fedora ships `firewalld` active,
which blocks mDNS and the sync port by default. The daemon cannot fix that and
must not try; it must *notice* and say so, or Phase 8 collects bug reports that
are all the same bug. *Unverified: what SteamOS runs.* Check on the device
before concluding a discovery failure is a Skrepka bug — the test rig's firewall
posture is not something this plan has established.

**The GUI is now the only thing left, and it is the expensive part.** This is a
good place to stop and take stock. A CLI-driven Linux daemon that syncs with the
Mac is already the useful thing.
