# A Linux Clippy, and LAN sync between the two

**Status: consideration. Nothing here is committed to and no code exists for
any of it.** This is the written-down version of a design investigation, kept
so the next person to pick the idea up does not repeat the research. Claims are
sourced where they were verified and labelled where they were not.

Date of investigation: 2026-09-04. Anything about a third-party project's
support matrix rots; re-check before relying on it.

---

## 1. What the idea is

A native Linux Clippy — its own history, its own picker, its own capture — that
finds the macOS Clippy on the local network, pairs with it once, and shares
history with it from then on.

Explicitly not a cloud service, not an account, not a relay. Two or three of
one person's own machines on one LAN.

## 2. Why it is worth doing, given Universal Clipboard exists

Apple already moves the clipboard between Apple devices. Anything built here has
to be honest about what it adds:

| | Universal Clipboard | Clippy sync |
|---|---|---|
| Items retained | one, overwritten by the next copy | full history |
| Pins | no | yes |
| Search across devices | no | yes |
| Non-Apple devices | no | the entire point |
| Setup | zero-config, same Apple ID | explicit pairing |

So the value is in two non-overlapping places: **history** (which Apple does not
do at all, even between two Macs) and **Linux** (which Apple will never do).

The part that *does* overlap — moving the live clipboard between two Macs — is
the part to stay out of. Section 3.

## 3. Universal Clipboard coexistence

Building a macOS peer that writes the pasteboard puts two systems in one seat.
Four distinct collisions, worst first.

**3.1 — The lazy-fetch trap, which is a bug already shipping.** If Universal
Clipboard populates the receiving Mac's pasteboard with a *promise* rather than
bytes, then `PasteboardReader.read` calling `item.data(forType:)` on every
`changeCount` bump forces a Continuity fetch over the air. Clippy polls at
200 ms and reads unconditionally, so every copy made on any of the user's Apple
devices — the iPhone included — would silently pull data into this Mac in the
background.

This is true of the app as it stands today, with no sync involved. It is the
single most useful thing in this document and it should be settled whether or
not any of the rest happens. See the spike in §12.

**3.2 — Ownership race.** Both systems try to own the receiving pasteboard for
the same logical copy. Last write wins, non-deterministically.

**3.3 — Duplicate transfer.** The same bytes cross the network twice for one
copy. De-duplication by `contentHash` collapses the row, so it costs nothing
visible — just wasted work.

**3.4 — Cross-system loops.** A copies → Universal Clipboard delivers to B →
B's poller captures → B pushes back to A. Echo suppression catches this only
while its window is warm; Continuity latency can be seconds. Bounded by
de-duplication, but it is churn with no upside.

### The rule this produces

> **Live push is scoped by platform. Never push the live clipboard between two
> Apple devices — that is Universal Clipboard's job. Live push exists to bridge
> the gap Apple leaves: macOS ↔ Linux.**

The mDNS TXT record carries `plat=macos|linux` anyway (§8), so this costs no
extra protocol surface. Live push defaults on for cross-platform pairs, off for
macOS↔macOS pairs, overridable per peer.

**History sync stays on for every pair, including Mac↔Mac**, because that is
the half with no competitor.

---

## 4. Linux platform reality

The load-bearing question is whether a background daemon can observe every
clipboard change without being the focused window. The answer differs per
compositor and it is not uniformly yes.

| Environment | Mechanism | Background daemon sees every change? |
|---|---|---|
| X11 (incl. XWayland) | `XFixesSelectSelectionInput` + `XFixesSelectionNotify` | **Yes**, event-driven |
| Sway, Hyprland, niri, labwc, COSMIC, Mir | `ext-data-control-v1` (+ legacy `wlr-data-control` v2) | **Yes** |
| KDE Plasma / KWin 6.6+ | `ext-data-control-v1` only | **Yes** |
| Wayfire, river | `wlr-data-control` only | Yes, legacy path |
| **GNOME / Mutter** | **neither** | **No** |
| Weston, Muffin (Cinnamon), Cage, gamescope | neither | No |

`ext-data-control-v1` is a **staging** protocol, first shipped in
`wayland-protocols` 1.39. The wlroots protocol's own XML now describes itself as
deprecated and not intended for production use.

**GNOME verified directly:** `src/meson.build` on Mutter `main` enumerates its
Wayland protocols; fetched and grepped, it contains **zero** occurrences of
`data-control`. There is no external-client path.

Note the irony worth writing down: X11 is *better* than macOS here. XFixes
delivers real selection-change events, so the Linux side needs no polling at
all, while macOS is stuck at 200 ms because `NSPasteboard.h` declares no change
notification of any kind.

### What real clipboard managers do about GNOME

Three options, all of them used in the wild:

1. **Run inside gnome-shell.** GPaste ships two backends; the privileged one
   talks to Mutter's server-side selection tracker directly, reachable only
   from inside the gnome-shell process. Its own source comments note this sees
   every selection change globally, with no focus gating — unlike a plain
   `GdkClipboard` client, which *is* focus-gated on Wayland.
2. **Ship a GNOME Shell extension.** CopyQ does exactly this. Costs a second
   codebase in JavaScript, plus extensions.gnome.org review, and it cannot be
   Flatpak'd — the extension cannot register with the shell from a sandbox.
3. **Fall back to XWayland** (`QT_QPA_PLATFORM=xcb`), which CopyQ documents as
   lossy.

There is a fourth, uglier path: `org.freedesktop.portal.Clipboard` exists and
`xdg-desktop-portal-gnome` implements it, but the interface cannot open its own
session — it only extends a **RemoteDesktop** or **InputCapture** session. So
GNOME clipboard monitoring through the portal means holding an open
remote-desktop grant. *Unverified: whether GNOME shows a persistent
screen-sharing indicator for a clipboard-only RemoteDesktop session.* Assume it
does until someone checks.

**Working assumption:** GNOME is in scope via a Shell extension (option 2),
accepted as a second codebase.

### Packaging consequence

**Flatpak is out for the daemon.** Sway's `is_privileged()` lists both
`wlr_data_control_manager_v1` and `ext_data_control_manager_v1`, and its global
filter returns them only for clients with no security context — the comment says
so outright: *restrict usage of privileged protocols to unsandboxed clients.*
Flatpak sets a security context. *Unverified: whether KWin applies the same
filter; its `wayland_server.cpp` registers `DataControlDeviceManagerV1Interface`
unconditionally, but the `Display` global filter was not traced.*

`.deb` / `.rpm` is the right target. AppImage works for a plain binary but not
for a GNOME extension. The Static Linux SDK (musl, fully static) suits a
headless daemon and is unusable for a GTK GUI, which needs glibc, GL and D-Bus.

---

## 5. Swift on Linux — what actually ports

`Sources/ClippyCore/` is 2141 lines across 31 files. Excluding the eight files
that import AppKit or SwiftData leaves **1294 lines / 23 files — 60% by line,
74% by file** — and it is the load-bearing 60%: `CaptureRules`,
`PrivacyMarkers`, `Matcher`, `ClipItem` hashing, `Preferences`,
`RetentionPolicy`, the whole `Models/` and `Diagnostics/` tree.

| API | Linux (Swift 6.2) | Replacement, and how invasive |
|---|---|---|
| `Foundation`, `FoundationEssentials` | yes | — |
| `Observation` | yes, built for Linux in the stdlib | — |
| `UserDefaults` | yes, swift-corelibs-foundation | — |
| `CryptoKit` | no | **swift-crypto, source-identical** — it compiles its API surface down to nothing on Apple platforms and re-exports CryptoKit. `import CryptoKit` → `import Crypto`; `SHA256.hash(data:)` unchanged. One line. |
| `SwiftData` | no | SQLite directly, or GRDB. `ClipRecord` + `HistoryStore` is ~260 lines to rewrite. |
| `os.Logger` | no | swift-log. `ClippyLog.swift` is 13 lines. |
| `AppKit`, `ImageIO`, `UniformTypeIdentifiers` | no | GTK / GdkPixbuf / shared-mime-info |

### GUI toolkit

Ranked, bluntly. A half-dead binding is a finding, not an option.

1. **`stackotter/swift-cross-ui`** — alive (1739★, commit the day this was
   written), GTK backend. No tray icon and no floating-palette window role, both
   of which Clippy needs.
2. **`rhx/SwiftGtk`** — raw GTK4 bindings, alive but thin.
3. **`AparokshaUI/adwaita-swift` — DEAD.** Archived 2024-10-17, along with every
   other repo in that organisation. Verified via the GitHub API. Do not build on
   it.
4. Qt through C++ interop — technically possible, no prior art for a Swift app.

**Global hotkey is the one Wayland story that is genuinely fine.** The
`org.freedesktop.portal.GlobalShortcuts` portal (v2) is implemented by both
`xdg-desktop-portal-gnome` and `xdg-desktop-portal-kde`. GPaste's README
confirms the approach: shortcuts through the XDG portal work the same on
Wayland and X11.

**Tray:** KDE has StatusNotifierItem natively. GNOME Shell ships no SNI host and
needs the AppIndicator extension, which distributions package but do not install
by default.

**Working assumption:** Swift + GTK4, so the 60% of `ClippyCore` that ports is
actually reused and there is one language across both platforms.

---

## 6. Shape of the code

```
Sources/
  ClippyCore/            phase 4 splits its storage behind a HistoryStoring
                         protocol and shims CryptoKit/os.Logger; otherwise
                         unchanged, and must stay Linux-clean
  ClippySync/            phase 1 — portable. No AppKit, no SwiftData, no
                         Network. Compiles on Linux from day one. Depends on
                         swift-crypto, swift-nio, swift-nio-ssl, SwiftCBOR.
  Clippy/                macOS app; phase 3 adds Sources/Clippy/Sync/
  clippy-sync-probe/     phase 3 — headless test peer, never touches NSPasteboard
  ClippyLinuxPlatform/   phase 5 — ext-data-control-v1 and XFixes backends
  clippyd/               phase 6 — daemon, Avahi discovery, D-Bus, CLI
  ClippyLinuxUI/         phase 7 — GTK4 picker, tray, portal hotkey
```

Phase numbers are §12. `ClippySync` is the only target both platforms link, and
it is deliberately the one with the fewest dependencies.

`ClippySync` layout, following the repo's group-by-feature rule:

```
Sources/ClippySync/
  Model/      PeerIdentity, SyncDeviceID, PeerPlatform, RepresentationKey,
              SyncClipMeta, Tombstone, LWWRegister
  Wire/       Frame, FrameCodec, SyncMessage, ProtocolVersion
  Merge/      MergeEngine, MergeAction
  Pairing/    DeviceCertificate, ShortAuthString, PairingSession, TrustStore
  Transport/  SyncServer, SyncClient, SyncConnection, TLSConfiguration+Clippy
  Discovery/  PeerDiscovery (protocol), ServiceDescriptor,
              BonjourDiscovery (#if canImport(Network))
```

Two seams matter more than the rest:

- **`MergeEngine` is pure and synchronous.** It takes a local index, a remote
  index and a tombstone set, and returns `[MergeAction]`. Same shape as
  `CaptureRules.decide` and `RetentionPolicy.idsToEvict`, which is exactly why
  those are testable today.
- **`PeerDiscovery` is a protocol.** `BonjourDiscovery` on macOS,
  `AvahiDiscovery` on Linux. Discovery is the only genuinely platform-specific
  part; transport is one implementation on both.

---

## 7. Wire protocol v1

Frames are length-prefixed, body is CBOR:

```
[u32 big-endian length][u8 message type][CBOR body]
```

Length capped at 33 MB — one byte over `CaptureRules.maximumItemBytes`, so the
wire limit and the capture limit are the same limit.

Message types:

| Type | Direction | Purpose |
|---|---|---|
| `hello` | both | protocol version, device id, platform, capabilities |
| `pairRequest` / `pairConfirm` | both | first-contact pairing, §9 |
| `indexOffer` | both | list of `SyncClipMeta`, no payload bytes |
| `indexRequest` | both | ask for an index since a cursor |
| `itemMeta` | both | one item's metadata |
| `payloadRequest` | both | `{contentHash, repKey, offset}` |
| `payloadChunk` | both | 256 KB slices, resumable |
| `tombstone` | both | deletion records |
| `livePush` | both | live clipboard handoff, §11 |
| `ping` | both | liveness |

**Why CBOR (RFC 8949):** self-describing like JSON, binary like protobuf, no
`.proto` toolchain in the build, and no base64 tax — JSON would add 33% to every
screenshot. `valpackett/SwiftCBOR` works on both platforms. Protobuf is the
fallback if a schema registry is ever wanted.

**Why not Swift `Codable`'s own encoding:** the GNOME Shell extension is
JavaScript. The wire format has to be parseable by something that is not Swift.

### Metadata eager, payload lazy

`SyncClipMeta` is a few hundred bytes: `contentHash`, `kind`, a text preview
capped at 4 KB, `createdAt`, `isPinned`, `imageSize`, the representation keys
and their sizes. Payload bytes are fetched only when an item is pasted or
previewed.

The arithmetic is the argument: 500 items × a 32 MB ceiling is 16 GB of eager
transfer, and nobody pastes 500 screenshots.

---

## 8. Representation keys — MIME on the wire, not UTIs

`public.utf8-plain-text` is a macOS identifier. It does not belong in a protocol
a GTK app and a JavaScript extension have to speak. The canonical vocabulary is
IANA media types, mapped at each boundary; the original key rides along as an
opaque `origKey` so a Mac↔Mac round trip stays lossless.

| Canonical wire key | macOS UTI | Linux target | Loss |
|---|---|---|---|
| `text/plain;charset=utf-8` | `public.utf8-plain-text` | same | none |
| `text/html` | `public.html` | same | none |
| `image/png` | `public.png` | same | none |
| `image/tiff` | `public.tiff` | same | none |
| `application/pdf` | `com.adobe.pdf` | same | none, but nothing on Linux puts PDF on the clipboard |
| `text/rtf` | `public.rtf` | `text/rtf` | **heavy.** GTK4 registers no RTF serializer; only LibreOffice and Qt apps offer it. In practice Linux rich text *is* `text/html`. |
| — | `com.apple.flat-rtfd` | **nothing** | **total.** RTFD is an Apple bundle — RTF plus embedded attachments. Must be flattened to HTML + PNG before it crosses. |
| `text/uri-list` | `public.file-url` | `text/uri-list` (+ GNOME's internal `x-special/gnome-copied-files`) | cardinality mismatch — macOS carries one, `text/uri-list` is a list. The cut-vs-copy verb has no macOS equivalent. |

GTK4's built-in serializers, for reference: `image/png`, `image/tiff`,
`image/jpeg`, `text/plain;charset=utf-8`, `text/plain`, `text/uri-list`,
`application/x-color`.

**Where it is lossy, stated plainly:**

- **File URLs.** The path exists only on the origin machine. Sync the URI as
  *text*; do not pretend it is a live file reference. Actual file transfer is a
  different feature and should not be smuggled in here.
- **`sourceBundleID`** has no Linux analogue. Carry it, display it only where it
  means something.
- **Pasteboard promises** (lazy providers) cannot cross the wire at all. Resolve
  before capture or drop the representation.
- **Never transcode images.** `contentHash` is defined over representation
  bytes, so re-encoding a PNG silently breaks de-duplication. KDE Connect
  transcodes; do not copy that.

---

## 9. Discovery, pairing, transport

### Discovery

Bonjour / DNS-SD, service type `_clippy._tcp` (11 characters; RFC 6763 §7.2
caps the service name at 15 bytes).

TXT record, each string under the 255-byte limit of RFC 6763 §6.1:

```
txtvers=1  id=<device UUID>  name=<host label>  proto=1
fp=<first 16 hex of SHA-256(cert DER)>  plat=macos|linux
```

`fp` lets a peer skip a full handshake against a device it has not pinned.
`plat` is load-bearing rather than decorative — it is what §11 reads to decide
the live-push default.

**macOS:** Network framework. Use `NWBrowser.Descriptor.bonjourWithTXTRecord`,
not plain `.bonjour` — TXT arrives only on the former. Set
`includePeerToPeer = false`; AWDL is Apple-only and useless for a Linux peer.

**Linux:** Network framework is Apple-only. KDE Connect's approach is worth
copying wholesale — use Avahi over D-Bus when `avahi-daemon` is running,
otherwise fall back to a vendored mDNS responder (`mdns.h`, mjansson, public
domain).

The reason for that fallback ordering: `mdns.h` sets `SO_REUSEADDR` and
`SO_REUSEPORT`, so co-binding works for *multicast*, but only one process
receives **unicast** replies on port 5353 — the documented conflict with Avahi
and `systemd-resolved`. Prefer the running daemon; embed only as a fallback.

*Unverified and worth a spike before committing to Swift on Linux:* Avahi
service registration from Swift. It is clearly possible — KDE Connect does it
from C++ over the same bus API — but the Swift D-Bus bindings are thin
(`wendylabsinc/dbus`, `PureSwift/DBus`, both tiny) and none has been compiled
against it here. Generating proxies from `busctl introspect org.freedesktop.Avahi`
or shelling out to `avahi-publish` are the fallbacks.

### Transport: TLS 1.3, mutual auth, pinned self-signed certs

Each device generates a self-signed P-256 certificate once. Both ends pin the
other's fingerprint at pairing. `minimumTLSVersion = .tlsv13`, mutual auth, and
a custom verification callback that accepts only the pinned fingerprint —
`sec_protocol_options_set_verify_block` on macOS, `NIOSSLCustomVerificationCallback`
on Linux.

**swift-nio + swift-nio-ssl on both platforms**, rather than Network framework
on macOS. One transport implementation, and it avoids the C-block dance.

Two alternatives were considered and rejected:

- **TLS-PSK is not available.** `swift-nio-ssl` wires PSK through BoringSSL's
  `SSL_CTX_set_psk_client_callback` / `_server_callback`, which its vendored
  header documents as RFC 4279 PSK cipher suites — TLS 1.2 and below — with no
  `psk_use_session` equivalent. macOS exposes
  `sec_protocol_options_add_pre_shared_key` and would happily do TLS 1.3, so a
  PSK design would silently downgrade only the Linux side. That asymmetry is
  the reason to rule it out.
- **Noise.** No maintained Swift implementation on both sides — the candidates
  have single-digit stars and no commits since 2023. Adopting it means owning a
  crypto stack.

Libraries that genuinely exist on both platforms: **swift-crypto** (SHA-256,
HKDF, Curve25519, ChaChaPoly), **swift-nio**, **swift-nio-ssl**.

### Pairing: trust on first use, confirmed by a short authentication string

Both devices display eight hex characters — `A3F2-91BC` — derived as
`SHA-256(sorted DER public keys ‖ pairing timestamp)`, and the user confirms
they match. The timestamp in the hash is what kills replay of a stale key;
lifted from KDE Connect's `pairinghandler.cpp`.

A PAKE (SPAKE2, as Magic Wormhole uses) was considered and is not needed: its
job is to authenticate over an untrusted rendezvous server, and there is no
server here. The SAS gets the same MITM protection for free. QR codes are a
later nicety — the Linux box may have no camera.

**Anti-downgrade, also from KDE Connect:** after the handshake completes,
re-send the identity record *inside* the tunnel and abort if `deviceId` or
`proto` differs from the pre-TLS values. Refuse a peer whose advertised `proto`
is lower than the last one seen from it.

---

## 10. Merge model

`ClipItem` is immutable except for `isPinned`, `createdAt` and deletion. That is
a **grow-only set plus two last-writer-wins registers**, not a general CRDT. No
text merging, no vector clocks.

- **Identity is `contentHash`, not `id`.** Two machines copying the same string
  must converge, and a locally generated `id: UUID` cannot. `id` stays local.
  The store already fetches by content hash — `recordMatching(contentHash:)` —
  so the lookup exists.
- **`createdAt`** — LWW by `max()`. Commutative, so clock skew cannot corrupt
  it, and it matches the existing rule that a repeat copy bumps the row.
- **`isPinned`** — LWW register of `(value, wallClockTimestamp, deviceID)`, with
  deviceID breaking ties. Seconds of skew are harmless for a manual toggle.
- **Deletes are tombstones** — `{contentHash, deletedAt, deviceID}`, replicated,
  retained ~90 days, then dropped. Without them, any re-sync resurrects
  everything the user deleted. `clear(keepingPinned:)` emits a batch.

### Retention is local and is not deletion

**The single most important distinction in the model.** A 500-item cap on the
Mac must not wipe a Linux machine configured to keep 5000. So:

> Eviction drops the local row and writes **no tombstone**. Deletion writes one.

Re-learning an evicted clip from a peer is correct behaviour, not a bug — the
local cap simply re-evicts it. Retention and deletion are different verbs and
conflating them is how a sync feature quietly destroys history.

### Concealed items do not sync

Default: `isConcealed` content never crosses the wire, behind an off-by-default
toggle for anyone who insists. Replicating password-manager content across a
network is a different risk class from storing it locally, and the app's
existing posture — never rendered in the clear, never matches search — should
extend outward rather than stop at the NIC.

---

## 11. Live push

Copy on one machine, and the content lands directly in the other's clipboard.

**Scoped by platform per §3:** on by default for cross-platform pairs, off by
default for macOS↔macOS pairs, overridable per peer. The toggle belongs on the
paired-device record, not on a global preference, and a macOS peer should show
it off *with the reason stated in the row* — "Universal Clipboard already does
this" — rather than as an unexplained disabled switch.

**Echo suppression uses a primitive that already exists.**
`PasteboardPoller.pause()` / `resume()` is used today so that pasting an entry
is not re-recorded, and `resume()` re-reads `changeCount` to discard whatever
happened while paused. Receiving a live push does the same dance: pause → write
to the pasteboard → resume. On top of that, keep a short-lived set of recently
received content hashes so a hash just accepted is never re-broadcast.

**Size discipline:** inline the bytes for payloads under 256 KB; above that push
metadata and let the peer fetch lazily, so a 20 MB screenshot never blocks the
live channel.

**Wayland caveat:** owning a selection on Wayland requires an active
`ext-data-control-v1` binding, so live push on Linux inherits every constraint
in §4 — including that it cannot work on GNOME without the Shell extension.

---

## 12. If this were built — all phases

Eight phases. Each ends somewhere testable, and the ordering is chosen so the
riskiest unknowns are answered before anything expensive is built on them:
Universal Clipboard behaviour first, then a protocol proven without Linux in the
loop, then Linux from the bottom up — core, clipboard, daemon, GUI.

`scripts/doctor.sh` stays green throughout on the macOS side; that is the
definition of done in this repo. Phases 3 onward need an equivalent gate for
Linux, which Phase 2 has to establish.

The size estimates are rough and assume the person doing the work already knows
the codebase.

---

### Phase 0 — The Universal Clipboard spike

**Independent of everything else and worth doing regardless of whether sync
ever ships.** Phase 3.1 describes a bug in the app as it stands today.

On a Mac with a second Apple device on the same Apple ID: copy on the other
device, then dump `NSPasteboard.general.pasteboardItems?.first?.types` and
compare `changeCount` before and after touching `data(forType:)`.

Answers both open questions — is there a marker, and is the payload a promise.
Throwaway code; findings get recorded in §14 of this document.

**Done when:** items 1 and 2 in §14 are struck out, and if the promise
behaviour is confirmed, a fix for the eager read lands on its own, unblocked by
anything else here.

*Half a day.*

---

### Phase 1 — `ClippySync`: the portable protocol core

New target, `sharedSwiftSettings` (no `.defaultIsolation`), depending on
swift-crypto and SwiftCBOR. No AppKit, no SwiftData, no Network. **This target
must compile on Linux from the day it is created**, even though nothing on
Linux consumes it yet — that constraint is what stops macOS assumptions
accumulating in it.

Build `Model/`, `Wire/` and `Merge/` per §6. Everything here is pure and
synchronous.

**Tests** (`Tests/ClippySyncTests/`): frame codec round-trips including a 33 MB
rejection; merge convergence, by applying two divergent histories in both orders
and asserting identical results; tombstone-beats-insert; retention-emits-no-
tombstone; UTI↔MIME round-trip; `PeerPlatform` defaulting live push off for
macOS↔macOS.

**Done when:** the merge engine converges under test and the codec round-trips,
with no networking written at all.

*Two to three days.*

---

### Phase 2 — Storage, identity, transport, discovery

Four pieces of plumbing, grouped because none of them is independently
demonstrable.

**Storage.** `ClipRecord` gains `pinnedAt`, `pinnedBy`, `originDeviceID`; new
`TombstoneRecord` and `PairedDeviceRecord`; `HistoryStore` gains `syncIndex()`,
`applyRemote(_:)`, `tombstones()`, `recordTombstone(_:)`. `delete()` and
`clear()` start writing tombstones; `applyRetention()` deliberately does not.
Reuse `recordMatching(contentHash:)`.

⚠️ §14 item 9 gates this — existing users have a populated `clippy.store`, and
this is the one place on the whole roadmap that can destroy data.

**Identity and pairing.** Certificate generation, SAS derivation, trust store
protocol with a Keychain-backed implementation in the app target.

**Transport.** NIO server and client, TLS 1.3 mutual auth, pinned verification,
in-tunnel identity re-send.

**Discovery.** Bonjour on macOS behind the `PeerDiscovery` protocol.

**Done when:** two `SyncConnection`s in one process complete a full pair →
index → payload fetch over loopback, as an integration test.

*A week.*

---

### Phase 3 — macOS app wiring, and the probe peer

**App side:** `SyncCoordinator`, a Sync settings tab, pairing sheet with the
SAS, per-peer rows carrying the live-push toggle. Live push plumbed through the
existing `PasteboardPoller.pause()` / `resume()` seam plus the recently-received
hash set.

**`clippy-sync-probe`:** an executable second peer with a file-backed store,
advertising `plat=linux`, speaking the full protocol and **never touching
`NSPasteboard`**.

The probe is the right proving ground precisely because it stands in for the
Linux client and keeps Universal Clipboard out of the test loop. Two Mac desktop
sessions would re-introduce the collision this whole design exists to avoid.

**Done when**, manually, with the app launched via `scripts/run.sh`: pairing
shows a matching SAS on both sides; a copy on the Mac reaches the probe; live
push is on for this pair because the probe advertises `plat=linux`; no echo
loop; pins propagate; deletes do not resurrect; retention eviction on the Mac
leaves the probe's copy alone; password-manager content never crosses. Then flip
the probe to `plat=macos` and confirm live push defaults off with the reason
shown in the row.

**This is the last phase that ships anything to a macOS user.** Everything after
it is Linux.

*A week.*

---

### Phase 4 — `ClippyCore` on Linux

The first phase with no macOS deliverable. Goal: `swift build` succeeds on
Linux for `ClippyCore` and `ClippySync`, and their tests pass there.

- `import CryptoKit` → `import Crypto` behind `#if canImport(CryptoKit)`. One
  line, source-identical API.
- `ClippyLog` → swift-log behind the same kind of shim. Thirteen lines.
- **Storage rewrite.** `HistoryStore`'s SwiftData implementation becomes one
  conformance of a `HistoryStoring` protocol; a SQLite/GRDB implementation
  becomes the other. ~260 lines, and the mapping layer
  (`ClipRecordMapping`) already exists to model it on.
- Exclude the AppKit files (`ThumbnailMaker`, `ImageFileThumbnail`,
  `PasteboardReader`, `StatusItemIcon`, `ShortcutSymbols`, `PasteboardAccess`)
  from the Linux build and define the seams they sit behind.
- **Establish `scripts/doctor-linux.sh`** — the Linux quality gate. Without it
  the next four phases have no definition of done.

**Done when:** `Tests/ClippyCoreTests` and `Tests/ClippySyncTests` pass on
Linux, unchanged. They are the same tests; that is the point of the 60%.

⚠️ Do this in a container or VM pinned to the target distributions, not on
whatever Linux box is nearest.

*A week to ten days, most of it the storage rewrite.*

---

### Phase 5 — Linux clipboard backends

The capture and paste half, headless. No GUI yet.

New target `ClippyLinuxPlatform`:

- **`ExtDataControlReader`** — `ext-data-control-v1`. Covers KDE Plasma 6.6+,
  Sway, Hyprland, niri, COSMIC. Falls back to `wlr-data-control` v2 where only
  that is offered (Wayfire, river).
- **`XFixesReader`** — `XFixesSelectSelectionInput` on X11 and XWayland.
  **Event-driven, so no polling** — better than the macOS side, which has no
  choice.
- **`ClipboardBackend`** protocol, chosen at runtime from `WAYLAND_DISPLAY`,
  `XDG_SESSION_TYPE` and which globals the compositor actually advertises.
- **MIME ↔ canonical key mapping**, reusing `RepresentationKey` from Phase 1
  rather than defining a second table.
- A clear, reportable failure when the session is GNOME Wayland and the Shell
  extension (Phase 7) is absent. The `Diagnostics/` tree already models exactly
  this kind of "why is nothing being captured" reporting — extend
  `CaptureHealth` and `DiagnosticsProblem` rather than inventing a parallel
  mechanism.

**Done when:** a headless binary on Sway, on KDE Wayland and on X11 logs every
clipboard change with correct kinds and representations, and can write a
selection back.

*A week and a half. The Wayland protocol code is the least familiar territory on
the roadmap.*

---

### Phase 6 — The Linux daemon

Phases 4 and 5 joined together and put on the network.

- **`AvahiDiscovery`** implementing `PeerDiscovery` — Avahi over D-Bus when
  `avahi-daemon` is running, vendored mDNS responder otherwise, per §9.
  ⚠️ §14 item 10 gates this and is worth spiking *before* Phase 4 commits the
  project to Swift on Linux.
- Wire `ClipboardBackend` → `CaptureRules` → `HistoryStoring` → `SyncCoordinator`.
  The middle two are the ported code from Phase 4; only the ends are new.
- **`clippyd`** with a systemd user unit.
- A `clippy` CLI — `list`, `copy <n>`, `pair`, `peers`, `doctor` — which is both
  a usable interface and the thing that makes the daemon testable without a GUI.
- **D-Bus interface** on the session bus. Not optional: it is how the GNOME
  Shell extension talks to the daemon in Phase 7, and designing it now avoids
  retrofitting.

**Done when:** a Mac and a Linux box pair over the LAN, history flows both ways,
live push works Mac → Linux and Linux → Mac, and everything Phase 3 verified
against the probe now holds against a real second machine.

**This is the milestone the whole idea is for.** Everything after it is
interface and distribution.

*A week and a half.*

---

### Phase 7 — The Linux GUI

GTK4, and the phase with the most schedule risk, because §5 ranks no option
better than "alive but thin".

- **Toolkit decision, made with code rather than on paper.** Before building
  the real picker, prototype the floating palette on both `swift-cross-ui` and
  raw `rhx/SwiftGtk`. The palette is the hardest widget — an undecorated,
  centred, non-activating, keyboard-driven overlay — so whichever toolkit can
  express it is the answer. `adwaita-swift` is archived and not a candidate.
- **The picker**: search field, rows with thumbnails, keyboard navigation,
  ⌘1–⌘9 equivalents. `Matcher` and `ClipSummary` port unchanged from Phase 4,
  so this is a view layer over logic that is already tested.
- **Global hotkey** via `org.freedesktop.portal.GlobalShortcuts` v2 — the one
  Wayland story that is genuinely fine, implemented by both the GNOME and KDE
  portal backends.
- **Tray icon** via StatusNotifierItem. Native on KDE; on GNOME it needs the
  AppIndicator extension, which distributions package but do not install by
  default — so detect its absence and say so rather than showing nothing.
- **Settings**: retention, exclusions, paired devices, per-peer live push.

**Done when:** hotkey → picker → select → pasted, on KDE and on Sway, with the
tray icon working on both.

*Two to three weeks, and the widest error bars on the roadmap. If a phase slips,
it is this one.*

---

### Phase 8 — GNOME support, and packaging

**The GNOME Shell extension.** JavaScript, talking over the Phase 6 D-Bus
interface. It uses Mutter's server-side selection tracker from inside the
gnome-shell process — the only path that sees every selection change without
focus gating, which is exactly what GPaste's privileged backend does and what
CopyQ ships an extension for.

Budget for extensions.gnome.org review as calendar time, not effort. The
extension must degrade honestly: if it is not installed, the daemon says so in
`clippy doctor` and in the Settings UI, rather than silently capturing nothing.

**Packaging.** `.deb` and `.rpm`, per §4:

- **Flatpak is out** and the reason should be stated in the docs rather than
  rediscovered — sway's global filter refuses the data-control protocols to any
  client with a security context, and a GNOME Shell extension cannot register
  from a sandbox either.
- **AppImage** is possible for the binary alone but cannot carry the extension.
- **Static Linux SDK** (musl, fully static) suits `clippyd` and is unusable for
  the GTK GUI, which needs glibc, GL and D-Bus. If a headless-only package is
  ever wanted, that is the tool for it.

**Done when:** a package installs on Ubuntu and Fedora, the daemon starts under
systemd, and a fresh machine can pair with the Mac from a clean install.

*A week, plus review latency outside anyone's control.*

---

### Summary

| Phase | Deliverable | Rough size |
|---|---|---|
| 0 | Universal Clipboard spike, and possibly a standalone bug fix | ½ day |
| 1 | `ClippySync` — model, wire, merge, all pure | 2–3 days |
| 2 | Storage, identity, transport, discovery | 1 week |
| 3 | macOS sync shipping, proven against `clippy-sync-probe` | 1 week |
| 4 | `ClippyCore` compiling and passing its tests on Linux | 1–1½ weeks |
| 5 | Linux clipboard read/write, headless | 1½ weeks |
| 6 | **Linux daemon — real Mac ↔ Linux sync** | 1½ weeks |
| 7 | Linux GUI | 2–3 weeks |
| 8 | GNOME extension and packaging | 1 week + review |

Two natural stopping points, and it is worth knowing where they are before
starting. **After Phase 3**, macOS users have history sync between Macs and
nothing has been risked on Linux. **After Phase 6**, the actual goal is met and
what remains is interface polish — a CLI-driven Linux daemon that syncs with the
Mac is already the useful thing, and Phase 7 is the expensive one.

---

## 13. Prior art

| Project | Worth stealing | Worth avoiding |
|---|---|---|
| **KDE Connect** | Pinned self-signed certs; SAS with a timestamp in the hash; in-tunnel identity re-send; the password-manager hint gate and its `sendPassword` toggle | `_kdeconnect._udp` for a TCP service; near-inline 50 MB file packets; the extra UDP broadcast path running alongside mDNS; image transcoding |
| **Syncthing** | Device ID as a hash of the certificate; an instance id to detect restarts; index-then-request-blocks | Its hand-rolled UDP broadcast — Bonjour already does this |
| **Magic Wormhole** | HKDF-SHA256 off the shared secret; per-phase key derivation | SPAKE2 with a nameplate and mailbox — needs a rendezvous server, which is ruled out |
| **GPaste / CopyQ** | The only two honest answers to GNOME | Both accept a second codebase to get there |
| **Universal Clipboard** | Zero-config pairing is the bar for setup UX | One item, no history — and it is a competitor for live push specifically |
| **CrossPaste, ClipCascade, ClipSync** | Closest existing peers: LAN-only, mDNS, end-to-end encrypted, cross-platform | All Kotlin/JVM or Rust, so nothing reusable. **Their protocol internals were not read** — worth ~20 minutes before finalising anything here. |

---

## 14. Unverified claims

Collected so nothing here reads as settled when it is not. Per
`.claude/rules/verify-against-docs.md`, these must be confirmed against the
installed interface before any code depends on them.

**Platform behaviour, needs an experiment:**

1. Whether a Universal Clipboard–originated pasteboard change is detectable at
   all. `NSPasteboard.h` in the Xcode 26.5 SDK declares no remote-clipboard or
   Continuity marker — AppKit and Foundation headers were grepped and contain
   nothing. A `strings` pass over the on-disk AppKit binary also found nothing,
   but that is **inconclusive**: the dyld shared cache means the on-disk binary
   is a stub.
2. Whether Universal Clipboard delivers bytes or a promise (§3.1).
3. Whether GNOME shows a persistent screen-sharing indicator for a
   clipboard-only RemoteDesktop session.
4. Whether KWin applies sway's sandbox filter to the data-control globals.

**APIs, needs the installed interface read:**

5. `NIOSSLCustomVerificationCallback` signature and `TLSConfiguration` shape in
   whatever `swift-nio-ssl` resolves to.
6. `apple/swift-certificates` API for generating a self-signed certificate, and
   whether it builds on Linux.
7. `NWListener.Service` and `NWBrowser.Descriptor` signatures against the
   macOS 26 SDK. Note that no `Network.swiftinterface` ships in the SDK — only
   `libswiftNetwork.tbd` — so the documentation is the only source.
8. `SwiftCBOR` maturity and its behaviour on malformed input.
9. Whether adding optional properties to an existing `@Model` is a lightweight
   SwiftData migration on macOS 26, or needs a `SchemaMigrationPlan`. Existing
   users have a populated `clippy.store` and this is the one item on the list
   that can destroy data.
10. Avahi service registration from Swift (§9).

**Project state, rots quickly:** every support-matrix claim in §4 and §5.
