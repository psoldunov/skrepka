# Open questions — Linux Skrepka and LAN sync

Everything still unsettled about
[the implementation plan](README.md), in two kinds.

**Decisions (D-1 … D-9)** are calls only the project owner can make. Nobody can
research their way to an answer; they are about scope, cost and what the product
is for. **All nine were taken on 2026-09-05** and are recorded below with the
reasoning that was on the table at the time.

**Research questions (OQ-1 … OQ-14)** are answerable by anyone with a machine
and an afternoon. Each says what it blocks, how to answer it, and what changes
under each answer. **None is answered yet.** As they close, edit the entry in
place with the answer, the date, and where it was verified — an unrecorded
answer gets researched twice.

---

## Decisions

Taken 2026-09-05. Summary:

| # | Decision |
|---|---|
| [D-6](#d-6) | **Build all eight phases.** Phases 3 and 6 stay as escape hatches, not plans. |
| [D-2](#d-2) | Mac↔Mac ships because it falls out of the same code — **Mac↔Linux is the goal**, and the positioning follows that. |
| [D-1](#d-1) | If Continuity delivers a promise: **fetch on demand.** |
| [D-3](#d-3) | **Raw SQLite** for the Linux store. No GRDB. |
| [D-4](#d-4) | Bake-off capped at 3 days; **if both toolkits fail, stop at Phase 6.** |
| [D-5](#d-5) | **Ship the GNOME Shell extension**, kept as thin as possible. |
| [D-7](#d-7) | **Concealed items never sync**, and no toggle in v1. |
| [D-8](#d-8) | **Install base is one machine, and the history on it is expendable.** Migration is not a constraint. |
| [D-9](#d-9) | **The Mac app stays native.** The Linux port never gets to degrade it. |

<a id="d-9"></a>
### D-9 — May the Linux port change how the Mac app is built?

**Decided 2026-09-05: no. macOS stays native, and the Linux port does not get a
vote on it.**

The repo already carries a rule in this shape, but only pointing backwards:
`CONTRIBUTING.md:18` and `.claude/rules/swift-conventions.md:137` both say
Skrepka targets exactly one OS and that anything the macOS 26 SDK ships is fair
game. That rule exists to refuse *compatibility shims for older macOS*. This
plan is the first thing to create the opposite pressure — **shims for another
platform** — and the answer is the same: the Mac app is built the way a Mac app
is built.

Concretely, what this settles:

- **SwiftData stays** ([D-3](#d-3)). It is the platform's persistence framework,
  it works, and "one engine everywhere" is a Linux convenience.
- **`@Model`, `@Observable`, Liquid Glass, `NSPanel`, the Keychain** — all stay.
  None of it is up for renegotiation because a GTK app cannot do it.
- **A seam introduced only for Linux is a cost, and has to earn its place.** The
  test: would this change be worth making if Linux did not exist? If not, it
  needs a second reason.

### The audit

Every place the plan currently asks the macOS side to change for Linux's sake,
and whether it survives D-9:

| Change | Whose benefit | Verdict |
|---|---|---|
| `HistoryStoring` protocol | Phase 3's probe peer needs a second conformance regardless | **Keep.** Not a Linux tax |
| `ClipboardSource` protocol | Linux backends — but `PasteboardPoller` currently constructs a concrete AppKit type in its own default argument, so it is untestable today | **Keep.** Improves the Mac side on its own merits |
| `PasteboardAccess` split behind `#if canImport(AppKit)` | Linux | **Keep.** Two lines, no macOS behaviour change |
| `SkrepkaSync` restating `maximumPayloadBytes` | keeps the sync target Linux-clean | **Keep.** Guarded by a cross-target drift test |
| Canonical MIME on the wire instead of UTIs | the protocol, not Linux specifically — a JavaScript extension has to read it too | **Keep.** UTIs ride along as `origin`, so Mac↔Mac stays lossless |
| `ThumbnailProducing` protocol | purely Linux; macOS would get a protocol with one real conformance and one nil-returning stub | **Defer.** Do not introduce it in Phase 4. Wait until Phase 7 has a real GdkPixbuf conformance to put behind it |
| SwiftData → SQLite on macOS | Linux convenience | **Rejected.** This is what D-9 is for |
| **swift-nio instead of Network framework on macOS** | one transport implementation across platforms | **Flagged — see below** |

### The one real violation: transport

Phase 2 currently specifies swift-nio + swift-nio-ssl on *both* platforms,
explicitly rejecting Network framework on macOS to avoid maintaining two
transports. Under D-9 that is the wrong default: Network framework is the native
answer, and it is already being used on macOS for discovery
(`NWBrowser`/`NWListener`), so the framework is linked either way.

**But writing the pinned-certificate verification twice is a security-critical
duplication**, and a callback that silently verifies nothing is the worst failure
shape on the roadmap.

**Recommendation, which satisfies both: keep one NIO transport, and add
`NWPathMonitor` on macOS for network-path changes.** The genuine functional gap
between the two stacks is not TLS — it is that Network framework notices sleep,
wake, Wi-Fi changes and VPN transitions, and NIO does not. A laptop doing LAN
sync hits all four constantly. `NWPathMonitor` closes that gap natively without a
second TLS implementation.

Confirm `NWPathMonitor`'s shape alongside the rest of [OQ-7](#oq-7) before
relying on it. If the split still feels wrong once the transport exists, moving
macOS to a full Network framework implementation is a contained change — it is
one conformance behind the same interface.

<a id="d-8"></a>
### D-8 — How much does existing data constrain the design?

**Decided 2026-09-05: not at all.** The install base is one machine — the
developer's — and losing the clipboard history on it is acceptable.

This is the most load-bearing decision on the list after [D-6](#d-6), because
several parts of the plan were shaped around protecting data that turns out not
to need protecting:

- **[OQ-9](#oq-9) stops being a gate.** It was "the only question that can
  destroy a user's data". Now the answer to "does SwiftData accept this schema
  change?" is worth twenty minutes of curiosity, and the fallback is deleting
  `skrepka.store`.
- **No fixture store, no `StoreMigrationTests`, no developing against a copy.**
  All three were mitigations for a risk that no longer exists.
- **A sidecar container was considered and dropped.** Keeping sync fields in a
  second store would have left `skrepka.store` untouched forever, at the cost of
  two independently-failing saves and an in-memory join. Worth it to protect
  other people's history; not worth it to protect none.
- **[D-3](#d-3) had to be re-argued**, because "migrating every user's store
  between engines" was one of its supporting reasons and that reason is void.

**Revisit the moment the install base grows.** Skrepka ships through a Homebrew
tap and notarized releases, so "one user" is a fact about today rather than a
property of the project. The reasoning behind each dropped mitigation is
preserved in place so it can be reinstated rather than re-derived.

<a id="d-6"></a>
### D-6 — Where do you want to stop?

**Decided 2026-09-05: build all eight phases — the full product.** Linux GUI,
GNOME support, `.deb` and `.rpm`. Roughly eleven weeks of focused work.

The roadmap has three defensible endings and they cost very different amounts:

| Stop at | You get | Rough cost from today |
|---|---|---|
| **Phase 3** | macOS users get history sync between their own Macs — pins, search, deletes — and Universal Clipboard is untouched | ~2.5 weeks |
| **Phase 6** | The actual goal: Mac ↔ Linux history sync and live push, driven by a CLI | ~7 weeks |
| **Phase 8** | The full product: Linux GUI, GNOME support, `.deb` and `.rpm` | ~11 weeks |

The recommendation on the table was to commit to Phase 3 and reassess; the call
went the other way, which is a legitimate reading of the same facts — the Linux
half is the point of the exercise ([D-2](#d-2)) and stopping at Phase 3 delivers
none of it.

**Phases 3 and 6 remain escape hatches rather than plans.** Both are real
products and both are points where the work can stop without leaving anything
half-built. [D-4](#d-4) already routes one failure mode back to Phase 6. Nothing
about choosing Phase 8 requires pretending those exits are closed.

Stopping *mid-phase* is the one thing to avoid — it leaves a half-ported target
that nothing builds.

<a id="d-1"></a>
### D-1 — Should Skrepka record Continuity-delivered clips at all?

**Decided 2026-09-05: fetch on demand.** Store the metadata, resolve the bytes
only when the user picks that row. Keeps iPhone copies in the history and
removes the background traffic.

Conditional on [OQ-2](#oq-2) finding that Universal Clipboard hands over a
promise rather than bytes. If it delivers bytes eagerly there is no bug and
nothing to decide.

**The fallback, if the pasteboard API cannot express deferred resolution, is
"never fetch a Continuity clip"** — an iPhone copy stops appearing in the Mac's
history, which some users will read as a bug, and that is the cost of the safe
answer. Do not fall back to today's behaviour with a disclosure; the decision
here is that background network traffic the user did not ask for is not
acceptable, disclosed or otherwise.

<a id="d-2"></a>
### D-2 — Is Mac↔Mac sync a shipped feature or an internal proving ground?

**Decided 2026-09-05: Mac ↔ Linux is the goal. Mac↔Mac ships because it falls
out of the same code, not as a headline feature.**

Consequences, which are about positioning rather than about what gets built:

- Phase 3 stays exactly as planned. Its job is to prove the protocol against
  `skrepka-sync-probe` before Linux is in the loop, and it happens to leave
  Mac↔Mac working.
- Release notes, the Settings copy and any marketing lead with Linux. Mac↔Mac
  is mentioned, not sold.
- **Version the protocol from day one anyway.** Once Phase 3 is in a release it
  has paired users, whatever it was sold as, and every later protocol change has
  to migrate them. Being able to refuse a peer on an incompatible version is
  what keeps that from becoming a forever-compatibility promise.

One factual note, since it cuts the other way and is worth having on record:
**Universal Clipboard does not cover Mac↔Mac history.** It carries one item,
overwritten by the next copy, with no pins and no cross-device search — design
§2 lays the comparison out. So Mac↔Mac history sync is not redundant with Apple;
it is simply not the reason this project exists. The prioritisation stands on
its own without needing the redundancy claim.

<a id="d-3"></a>
### D-3 — SQLite directly, or GRDB, for the Linux store?

**Decided 2026-09-05: raw SQLite through the C library.** No GRDB.

**This question is only about Linux. macOS keeps SwiftData.** `HistoryStore`
becomes the first conformance of `HistoryStoring`, unchanged, still `@Model`,
still reading the same `skrepka.store` it wrote. Phase 4 adds a *second*
conformance for Linux, where SwiftData does not exist.

Moving macOS to SQLite too was considered twice and rejected twice. First on
migration risk, which [D-8](#d-8) then voided. Re-argued, and **settled by
[D-9](#d-9): the Mac app stays native.** SwiftData is the platform's persistence
framework and "one engine everywhere" is a Linux convenience, which is exactly
the trade D-9 refuses.

Two supporting reasons that survive on their own: `@Attribute(.externalStorage)`
is doing real work keeping multi-megabyte payload blobs out of the row and would
have to be reimplemented, and the divergence risk two engines create is already
held down by `HistoryStoringTests` running against every conformance.

For the Linux side itself, the store's needs are genuinely small — one table, a
hash lookup, a sorted fetch, a delete-where — so there is no ORM-shaped problem,
and the narrow `HistoryStoring` surface keeps it that way. Raw SQLite costs more
code and carries no dependency risk on Linux.

**Revisit if the schema grows**, and note that Phase 2 already grows it: three
entities rather than one, plus tombstones with their own retention. If the
Linux store starts needing joins or migrations of its own, that is the signal.

<a id="d-4"></a>
### D-4 — Toolkit strategy for the Linux GUI, and the fallback

**Decided 2026-09-05: cap the bake-off at three days. If both toolkits fail to
express the floating palette, stop at Phase 6.**

Not "escalate to Qt", not "fall back to XWayland". A CLI-driven daemon that
syncs with the Mac is already the useful thing, and Qt through C++ interop is a
different project with no prior art for a Swift app.

This is the one hard exit condition on the roadmap, and it is worth treating as
such: **three days is a budget, not an estimate.** If day three ends with a
palette that almost works, that is a failure, not an argument for day four.
Write the outcome into
[`phase-7-linux-gui.md`](phase-7-linux-gui.md) either way, so the next person
does not re-run the bake-off.

Rejected, with reasons on record: an XWayland-only picker works and CopyQ
documents it as lossy, and it abandons the Wayland-native story on exactly the
compositors where Phase 5 works best.

<a id="d-5"></a>
### D-5 — Is GNOME in scope, accepting a second codebase?

**Decided 2026-09-05: in scope. Ship the Shell extension, kept as thin as
possible, and last — exactly where Phase 8 puts it.**

GNOME/Mutter implements no external clipboard-monitoring protocol — verified
against Mutter's own `src/meson.build`, which contains zero occurrences of
`data-control`. The only path that sees every selection change is code running
inside gnome-shell, which means a JavaScript extension: a second language, a
review queue, and breakage on GNOME releases, forever. GNOME is the most common
Linux desktop, so excluding it excludes most of the audience, and that is the
trade being accepted.

**"Thin" is the load-bearing word and it needs enforcing, not just intending.**
Capture rules, privacy markers, de-duplication and every decision about what to
keep stay in `SkrepkaCore`, where they are tested. The extension forwards
selection changes to the daemon over D-Bus and accepts set-selection calls back.
Anything that ends up in `extension.js` and could have lived in the daemon is a
future GNOME release's breakage, bought voluntarily.

The D-Bus interface is versioned from its first commit, because the extension
ships through a review queue and will lag the daemon by weeks.

<a id="d-7"></a>
### D-7 — Should the "sync concealed items" toggle exist at all?

**Decided 2026-09-05: concealed content never syncs, and there is no toggle in
v1.** A security default that was never available cannot be turned on by
accident, and it can always be added later with a real design behind it.

### The encryption option, and why it was not taken

The question that came up was whether concealed items could simply be encrypted
and synced. They can, but only one version of that is coherent, and it is
expensive. Recorded here so it is not re-derived.

**Transit is already encrypted.** TLS 1.3, mutual auth, pinned self-signed
certificates. Encrypting the payload again buys nothing against a network
attacker; that threat is already handled.

**The real exposure is at rest.** Syncing puts a password on two or three disks
instead of one. And today concealed items are already stored *plaintext* in
`~/Library/Application Support/dev.soldunov.skrepka/skrepka.store` — so
encrypting them for the wire while leaving them plaintext locally protects
nothing, it just looks like it does.

**The key has to live somewhere the database does not.** macOS Keychain, Linux
Secret Service or the kernel keyring. A key sitting next to the data means disk
access gets both, which is the failure mode the whole feature would exist to
prevent.

That makes the honest versions of "yes, encrypt them":

| Version | Cost |
|---|---|
| Memory-only on the receiving peer with a TTL — never written to disk, evicted after N seconds | ~2 days on top of Phase 2. Matches what the content actually is: a password you are about to paste |
| Encrypt concealed items at rest on both ends, key in the platform secret store, covering local storage too | ~1 week, plus key rotation on unpair |
| Encrypt the whole store at rest on both platforms | ~1.5 weeks. Most defensible; a lost key means lost history |

None was taken for v1. **The memory-with-TTL version is the one to revisit
first** if the feature is ever wanted — it is the cheapest coherent answer and
it does not require solving key management for the whole store.

---

## Research questions

| # | Question | Blocks | Cost |
|---|---|---|---|
| [OQ-1](#oq-1) | Is a Continuity pasteboard change detectable? | Phase 0 | ½ day, with the spike |
| [OQ-2](#oq-2) | Bytes or a promise? | Phase 0, and a possible shipping bug | same spike |
| [OQ-3](#oq-3) | Does GNOME show a sharing indicator for a clipboard-only RemoteDesktop session? | nothing — it reopens a rejected option | 1 hour |
| [OQ-4](#oq-4) | Does KWin apply sway's sandbox filter? | nothing — it changes an explanation | 1 hour |
| [OQ-5](#oq-5) | `NIOSSLCustomVerificationCallback` and `TLSConfiguration` shape | Phase 2 transport | 1 hour |
| [OQ-6](#oq-6) | `swift-certificates` API, and does it build on Linux? | Phase 2 identity, Phase 4 | 1–2 hours |
| [OQ-7](#oq-7) | `NWListener.Service` / `NWBrowser.Descriptor` signatures | Phase 2 discovery | 1 hour |
| [OQ-8](#oq-8) | `SwiftCBOR` maturity and malformed-input behaviour | Phase 1 codec | 2 hours |
| [OQ-9](#oq-9) | Is adding properties to a populated `@Model` a lightweight migration? | nothing — downgraded by [D-8](#d-8) | 20 min |
| [OQ-10](#oq-10) | Avahi service registration from Swift | Phase 6, spike before Phase 4 | 1 day |
| [OQ-11](#oq-11) | `Observation` and `@MainActor` on Linux | Phase 4 | ½ day |
| [OQ-12](#oq-12) | Are `CGPath` / `CGAffineTransform` available on Linux? | Phase 4 exclusion, Phase 7 tray | 1 hour |
| [OQ-13](#oq-13) | swift-format, SwiftLint, Periphery on Linux; SwiftPM multi-target build | Phase 4's quality gate | ½ day |
| [OQ-14](#oq-14) | What do CrossPaste / ClipCascade / ClipSync actually do on the wire? | nothing, but it is 20 minutes | 20 min |

**Answerable today, on the development machine.** OrbStack is installed and
working (see [the Linux environment](README.md#the-linux-environment)), which
turns six of these from "needs a Linux box" into an afternoon:

- **[OQ-11](#oq-11)** — compile `Preferences` and `CaptureHealth` in a
  `swift:6.x` container.
- **[OQ-12](#oq-12)** — compile `PaperclipPath` in the same container.
- **[OQ-13](#oq-13)** — check the toolchain for `swift-format`, try SwiftLint
  and Periphery, settle the `swift build` form.
- **[OQ-6](#oq-6)** — resolve `swift-certificates` in the container and see
  whether it builds.
- **[OQ-9](#oq-9)** — not a Linux question at all; testable on macOS today, and
  it is the only item here that can destroy user data.
- **[OQ-10](#oq-10)** — partially. Avahi runs fine inside a machine; whether
  mDNS crosses the macOS ↔ OrbStack boundary is its own unknown.

Not helped by any of it: **[OQ-1](#oq-1)** and **[OQ-2](#oq-2)** need a second
Apple device, and **[OQ-3](#oq-3)** / **[OQ-4](#oq-4)** need a real GNOME and a
real KWin session.

<a id="oq-1"></a>
### OQ-1 — Is a Universal Clipboard change detectable at all?

`NSPasteboard.h` in the Xcode 26.5 SDK declares no remote-clipboard or
Continuity marker. AppKit and Foundation headers were grepped and contain
nothing. A `strings` pass over the on-disk AppKit binary also found nothing, but
that is **inconclusive** — the dyld shared cache means the on-disk binary is a
stub.

**How to answer:** the Phase 0 spike. Dump the full declared type list on a
remote-originated change and compare it against a local copy of the same
content.

**If there is a marker:** live push can be suppressed precisely for Continuity
clips, and the cross-system loop in design §3.4 becomes closable rather than
merely bounded. **If there is not:** the platform rule stands as written — live
push never runs between two Apple devices.

<a id="oq-2"></a>
### OQ-2 — Bytes, or a promise?

**The most consequential question in this document**, because one answer means
Skrepka has a bug today with no sync involved.

`PasteboardReader.read` calls `item.data(forType:)` on every `changeCount`
bump. If the receiving pasteboard holds a promise, that read forces a Continuity
fetch over the air — for every copy made on any Apple device the user owns.

**How to answer:** the Phase 0 spike, with a multi-megabyte payload so the
resolution is measurable.

**If a promise:** a fix ships on its own, ahead of everything else here, and
[D-1](#d-1) becomes live.

<a id="oq-3"></a>
### OQ-3 — Does GNOME badge a clipboard-only RemoteDesktop session?

`org.freedesktop.portal.Clipboard` cannot open its own session; it only extends
a RemoteDesktop or InputCapture session. If GNOME shows a permanent
screen-sharing badge for that, the portal path is unusable for a background
clipboard manager.

**Assume it does until someone checks.** Answering it only matters if the Shell
extension path in Phase 8 is being reconsidered.

<a id="oq-4"></a>
### OQ-4 — Does KWin apply sway's sandbox filter to the data-control globals?

Sway's `is_privileged()` refuses both data-control managers to any client with a
security context, which is what rules Flatpak out. KWin's `wayland_server.cpp`
registers `DataControlDeviceManagerV1Interface` unconditionally, but its
`Display` global filter was not traced.

Does not change the packaging decision — Flatpak is out either way, because a
GNOME Shell extension cannot register from a sandbox. It changes how the
decision is explained in `packaging/README.md`.

<a id="oq-5"></a>
### OQ-5 — `NIOSSLCustomVerificationCallback` and `TLSConfiguration`

Read the resolved `swift-nio-ssl`'s own interface before writing the pinned-
certificate verification. Getting this subtly wrong produces code that connects
successfully and verifies nothing, which is the worst possible failure shape.

`LoopbackSyncTests.rejectsUnpinnedCertificate` is the test that catches it, and
it should be written before the callback.

<a id="oq-6"></a>
### OQ-6 — `apple/swift-certificates`, and Linux

Two questions in one: the API for generating a self-signed P-256 certificate,
and whether the package builds on Linux at all.

**If it does not build on Linux:** Phase 2's identity design changes and Phase 4
inherits the problem. Find out before Phase 2, not during Phase 4. The fallback
is generating the certificate with the platform's own tooling and parsing only
the fields the pinning needs.

<a id="oq-7"></a>
### OQ-7 — Network framework signatures

`NWListener.Service` and `NWBrowser.Descriptor` against the macOS 26 SDK. Note
that **no `Network.swiftinterface` ships** — only `libswiftNetwork.tbd` — so
documentation is the only source, and that fact belongs in the commit message
per the repo's verify-against-docs rule.

Two specifics that are silent when wrong: `bonjourWithTXTRecord` rather than
plain `.bonjour`, because TXT records do not arrive on the latter; and
`includePeerToPeer = false`, because AWDL is Apple-only and useless for a Linux
peer.

**Also confirm `NWPathMonitor`** while in the same headers. [D-9](#d-9) routes
macOS network-path changes — sleep, wake, Wi-Fi, VPN — through it rather than
through a second NIO-side implementation, so its shape and its update semantics
are load-bearing for reconnect.

<a id="oq-8"></a>
### OQ-8 — `SwiftCBOR` maturity and malformed input

What does it do with a truncated body, a corrupted one, a deeply nested one, a
declared length that exceeds the buffer? A codec that traps on malformed input
is a remote crash, and the peer sending it is not necessarily friendly.

**How to answer:** read the source, then write the `FrameCodecTests`
malformed-input cases against it before anything depends on the answer.

**If it is unsuitable:** `FrameCodec` is the only file that names CBOR, so the
blast radius is one file. A hand-rolled subset covering the handful of types
this protocol uses is about a day.

<a id="oq-9"></a>
### OQ-9 — SwiftData migration

**Downgraded 2026-09-05 by [D-8](#d-8).** This was the only question on the list
that could destroy a user's data. With an install base of one machine and an
expendable history, it is now a twenty-minute curiosity with a one-line
fallback.

Phase 2 adds four optional properties to `ClipRecord` and two new `@Model`
entities to the container. Is that a lightweight migration on macOS 26, or does
it need a `SchemaMigrationPlan`? Worth knowing, because the answer decides
whether Phase 2 spends a day writing one.

Relevant context, verified 2026-09-05: the codebase has **no migration
scaffolding at all** — no `VersionedSchema`, no `SchemaMigrationPlan`, no
`MigrationStage` — and every stored property on `ClipRecord` is either optional
or defaulted, which is the shape most likely to migrate automatically.

**How to answer:** open the existing store under the new schema and see. No
fixture, no copy, no ceremony.

**If it refuses:** delete `skrepka.store` and move on, or write the
`SchemaMigrationPlan` if it turns out to be an hour rather than a day. Both are
acceptable outcomes now.

<a id="oq-10"></a>
### OQ-10 — Avahi service registration from Swift

Clearly possible — KDE Connect does it from C++ over the same bus API. What is
unverified is doing it from Swift, whose D-Bus bindings are thin
(`wendylabsinc/dbus`, `PureSwift/DBus`, both small) and neither of which has
been compiled against it here.

**Spike this before Phase 4**, not before Phase 6. It is one of two questions
that decide whether Swift is the right language for the Linux side at all, and
Phase 4 is a week-plus commitment to that answer.

**Fallbacks, in order:** generate proxies from
`busctl introspect org.freedesktop.Avahi`; or shell out to `avahi-publish` and
`avahi-browse`. The second is ugly and it works.

<a id="oq-11"></a>
### OQ-11 — `Observation` and `@MainActor` on Linux

The design document states `Observation` is built for Linux in the stdlib. Two
files depend on it — `Settings/Preferences` and `Diagnostics/CaptureHealth`,
173 lines between them — and both are also `@MainActor`.

**How to answer:** compile both files in the Linux container in the smallest
possible harness, and run one test that mutates an observed property and reads
it back. Half a day, and it is the other question that decides whether Swift is
the right language for the Linux side.

**If `Observation` is absent or broken:** both types are small enough to be
rewritten without it, so this is a cost rather than a blocker — but knowing that
before Phase 4 rather than during it is worth the half day.

<a id="oq-12"></a>
### OQ-12 — Core Graphics path types on Linux

**A finding the design document missed.** `Branding/PaperclipPath.swift` is 142
lines and imports `CoreGraphics`, not AppKit, so it does not appear in the
design's list of excluded files. It is the single source of the app icon, the
menu-bar mark and the in-app artwork.

swift-corelibs-foundation provides `CGFloat`, `CGPoint`, `CGRect` and `CGSize`
on Linux. `CGPath`, `CGMutablePath` and `CGAffineTransform` are Core Graphics
types and their availability has to be checked, not assumed.

**How to answer:** compile the file in the Linux container. One hour.

**If they are absent:** extract a portable path IR — a value type of
`move`/`line`/`curve`/`close` — rendered to `CGPath` on macOS and to Cairo on
Linux. Half a day, and it is Phase 7 work. `scripts/paperclip.svg` stays the
design source either way, and `scripts/make-icon.sh` keeps compiling one file,
so the icon and the menu bar still cannot drift.

<a id="oq-13"></a>
### OQ-13 — The Linux quality gate's tooling

Four small unknowns that together decide what `scripts/doctor-linux.sh` can
check:

1. Is `swift-format` bundled in the Linux toolchain? The macOS gate runs
   `xcrun swift-format`, which does not exist there.
2. Is SwiftLint installable, or built from source?
3. Does Periphery support Linux? If not, the dead-code scan stays a macOS check
   and the Linux gate says so out loud.
4. What is the right form of `swift build` on Linux, given a bare one tries to
   build the macOS-only app target and its `KeyboardShortcuts` dependency —
   repeated `--target` invocations, or a `SkrepkaLinux` library product?

`doctor.sh`'s existing `optional` helper already handles "the tool is absent"
gracefully, so a missing tool is a note rather than a redesign.

<a id="oq-14"></a>
### OQ-14 — What do the existing cross-platform clipboard syncers do?

CrossPaste, ClipCascade and ClipSync are the closest existing peers: LAN-only,
mDNS, end-to-end encrypted, cross-platform. **Their protocol internals were not
read.** All are Kotlin/JVM or Rust so nothing is reusable as code, but twenty
minutes of reading their wire formats before finalising Phase 1 is the cheapest
review available.

Specifically worth looking for: how they handle the retention-versus-deletion
distinction, whether they sync history or only the live clipboard, and what they
do about a peer whose clock is wrong.
