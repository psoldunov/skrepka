# Phase 6 — The Linux daemon

**A week and a half. This is the milestone the whole idea is for.**

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

## Deliverables

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

Every step of the Phase 3 runbook re-run with a real Linux machine in place of
the probe, and recorded. Specifically:

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
are all the same bug.

**The GUI is now the only thing left, and it is the expensive part.** This is a
good place to stop and take stock. A CLI-driven Linux daemon that syncs with the
Mac is already the useful thing.
