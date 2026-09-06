# Open questions — Linux Skrepka and LAN sync

Everything still unsettled about
[the implementation plan](README.md), in two kinds.

**Decisions (D-1 … D-9)** are calls only the project owner can make. Nobody can
research their way to an answer; they are about scope, cost and what the product
is for. **All nine were taken on 2026-09-05** and are recorded below with the
reasoning that was on the table at the time.

**Research questions (OQ-1 … OQ-15)** are answerable by anyone with a machine
and an afternoon. Each says what it blocks, how to answer it, and what changes
under each answer. **Ten of the first fourteen were answered on 2026-09-05**;
four of those need hardware rather than time, and
**[OQ-15](#oq-15) was raised on 2026-09-06** by the Phase 3 review and is
mitigated rather than closed. As they close, edit the entry in place with the
answer, the date, and where it was verified — an unrecorded answer gets
researched twice.

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
| `ClipboardSource` protocol | Linux backends — but `ClipboardWatcher` (then `PasteboardPoller`) constructed a concrete AppKit type in its own default argument, so it was untestable | **Keep.** Improves the Mac side on its own merits |
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

**Ten of the fourteen were answered on 2026-09-05.** Each entry below carries
its answer, the date, and where it was verified.

| # | Question | Status | Blocks |
|---|---|---|---|
| [OQ-1](#oq-1) | Is a Continuity pasteboard change detectable? | **open** — needs a second Apple device | Phase 0 |
| [OQ-2](#oq-2) | Bytes or a promise? | **open** — needs a second Apple device | Phase 0, and a possible shipping bug |
| [OQ-3](#oq-3) | Does GNOME show a sharing indicator for a clipboard-only RemoteDesktop session? | **open** — needs a real GNOME session | nothing — it reopens a rejected option |
| [OQ-4](#oq-4) | Does KWin apply sway's sandbox filter? | **open** — needs a real KWin session | nothing — it changes an explanation |
| [OQ-5](#oq-5) | `NIOSSLCustomVerificationCallback` and `TLSConfiguration` shape | **answered** — `([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResult>) -> Void`, set on the *handler*, and dead unless `certificateVerification` is stronger than `.none` | Phase 2 transport |
| [OQ-6](#oq-6) | `swift-certificates` API, and does it build on Linux? | **answered** — builds on Linux aarch64; DER re-encodes byte-identically on both platforms | Phase 2 identity, Phase 4 |
| [OQ-7](#oq-7) | `NWListener.Service` / `NWBrowser.Descriptor` signatures | **answered** — and `Network.swiftinterface` *does* ship, so there is a ground truth | Phase 2 discovery |
| [OQ-8](#oq-8) | `SwiftCBOR` maturity and malformed-input behaviour | **answered — unsuitable.** Hand-roll the codec | Phase 1 codec |
| [OQ-9](#oq-9) | Is adding properties to a populated `@Model` a lightweight migration? | **answered — yes.** No `SchemaMigrationPlan` | nothing — downgraded by [D-8](#d-8) |
| [OQ-10](#oq-10) | Avahi service registration from Swift | **answered** — Swift talks to `org.freedesktop.Avahi` over D-Bus today; no shelling out needed | Phase 6, spike before Phase 4 |
| [OQ-11](#oq-11) | `Observation` and `@MainActor` on Linux | **answered — works**, with two Linux-only gotchas | Phase 4 |
| [OQ-12](#oq-12) | Are `CGPath` / `CGAffineTransform` available on Linux? | **answered — no**, and neither is the `CoreGraphics` module | Phase 4 exclusion, Phase 7 tray |
| [OQ-13](#oq-13) | swift-format, SwiftLint, Periphery on Linux; SwiftPM multi-target build | **answered** — and `scripts/doctor-linux.sh` now exists | Phase 4's quality gate |
| [OQ-14](#oq-14) | What do CrossPaste / ClipCascade / ClipSync actually do on the wire? | **answered** — only CrossPaste syncs history, and none of the three syncs deletion | nothing, but it was 20 minutes |
| [OQ-15](#oq-15) | The pairing code lets whoever moves second choose its inputs | **mitigated 2026-09-06** — widened to 64 bits; commit-then-reveal still owed | a wire change to make before this ships |

The four still open all need hardware this machine does not have:
**[OQ-1](#oq-1)** and **[OQ-2](#oq-2)** need a second Apple device, and
**[OQ-3](#oq-3)** / **[OQ-4](#oq-4)** need a real GNOME and a real KWin session.
Nothing on the roadmap is blocked on them — OQ-1 and OQ-2 gate Phase 0, which is
its own spike, and OQ-3 and OQ-4 only change how a settled decision is explained.

<a id="oq-1"></a>
### OQ-1 — Is a Universal Clipboard change detectable at all?

**Still open as of 2026-09-05.** It needs a second Apple device signed into
the same iCloud account, which this machine does not have.

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

**Still open as of 2026-09-05**, for the same reason as [OQ-1](#oq-1): a second
Apple device. Nothing in the container work touches it.

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

**Still open as of 2026-09-05.** It needs a real GNOME session on real
hardware; a container cannot answer it.

`org.freedesktop.portal.Clipboard` cannot open its own session; it only extends
a RemoteDesktop or InputCapture session. If GNOME shows a permanent
screen-sharing badge for that, the portal path is unusable for a background
clipboard manager.

**Assume it does until someone checks.** Answering it only matters if the Shell
extension path in Phase 8 is being reconsidered.

<a id="oq-4"></a>
### OQ-4 — Does KWin apply sway's sandbox filter to the data-control globals?

**Still open as of 2026-09-05.** It needs a running KWin session.

Sway's `is_privileged()` refuses both data-control managers to any client with a
security context, which is what rules Flatpak out. KWin's `wayland_server.cpp`
registers `DataControlDeviceManagerV1Interface` unconditionally, but its
`Display` global filter was not traced.

Does not change the packaging decision — Flatpak is out either way, because a
GNOME Shell extension cannot register from a sandbox. It changes how the
decision is explained in `packaging/README.md`.

<a id="oq-5"></a>
### OQ-5 — `NIOSSLCustomVerificationCallback` and `TLSConfiguration`

**Answered 2026-09-05**, by reading `swift-nio-ssl` 2.37.4's own source in a
resolved checkout (`Sources/NIOSSL/SSLCallbacks.swift`,
`Sources/NIOSSL/TLSConfiguration.swift`, `Sources/NIOSSL/NIOSSLServerHandler.swift`,
`Sources/NIOSSL/NIOSSLClientHandler.swift`) and then compiling the resulting
pattern on both macOS 26 and Linux aarch64. `swift-nio` resolved to 2.102.0.

The callback is a plain closure, not a protocol:

```swift
public typealias NIOSSLCustomVerificationCallback = ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResult>) ->
    Void
```

and its result type has exactly two cases:

```swift
public enum NIOSSLVerificationResult: Sendable {
    /// The certificate was successfully verified.
    case certificateVerified

    /// The certificate was not verified.
    case failed
}
```

So **accept is `promise.succeed(.certificateVerified)` and reject is
`promise.succeed(.failed)`** — a rejection is a *fulfilled* promise carrying
`.failed`, not a failed promise and not a thrown error. Failing the promise
instead is the mistake to watch for. The peer chain arrives as the first
argument, unprocessed; the library's own warning on the typealias is *"setting
this callback will override **all** verification logic that BoringSSL
provides"*, so the leaf is a candidate, never a validated certificate.

**The callback is set on the handler, not on `TLSConfiguration`.** There is no
`customVerificationCallback` property anywhere in `TLSConfiguration`:

```swift
public convenience init(
    context: NIOSSLContext,
    customVerificationCallback: @escaping NIOSSLCustomVerificationCallback
)                                                    // NIOSSLServerHandler

public convenience init(
    context: NIOSSLContext,
    serverHostname: String?,
    customVerificationCallback: @escaping NIOSSLCustomVerificationCallback
) throws                                             // NIOSSLClientHandler
```

**The silent-failure trap is documented in the library itself**, and it is not
the one the plan expected. From the doc comment on both handler initialisers:

> The callback will not be used if the `TLSConfiguration` that was used to
> construct the `NIOSSLContext` has `TLSConfiguration/certificateVerification`
> set to `CertificateVerification/none`.

That is the "connects successfully and verifies nothing" shape, verbatim, and
it is reachable by accident: `TLSConfiguration.makeServerConfiguration(certificateChain:privateKey:)`
sets `certificateVerification: .none` and `minimumTLSVersion: .tlsv1`. A server
built from that factory and handed a pinning callback would never call it. Use
`makeServerConfigurationWithMTLS(certificateChain:privateKey:trustRoots:)`
instead — it sets `.noHostnameVerification`, which is the strongest setting a
server can use, since hostname checking cannot succeed against a client.

The rest of the shape, all present on `TLSConfiguration` as `var`s:
`minimumTLSVersion: TLSVersion` and `maximumTLSVersion: TLSVersion?` (the enum
is `case tlsv1, tlsv11, tlsv12, tlsv13`, so `.tlsv13` on both pins TLS 1.3
exactly); `certificateVerification: CertificateVerification`;
`certificateChain: [NIOSSLCertificateSource]` and `privateKey: NIOSSLPrivateKeySource`,
which the client sets too so it can answer the server's mTLS demand;
`trustRoots: NIOSSLTrustRoots?`. `NIOSSLCertificate.toDERBytes() throws -> [UInt8]`
is what turns the peer's leaf into the bytes the pin hashes, which is the same
encoding [OQ-6](#oq-6) settles.

`LoopbackSyncTests.rejectsUnpinnedCertificate` is still the test that catches a
regression here, and it should still be written before the callback. Add a
second one asserting that a configuration with `.none` verification is refused
at construction, because that is the failure this API makes easy.

<a id="oq-6"></a>
### OQ-6 — `apple/swift-certificates`, and Linux

**Answered 2026-09-05. It builds on Linux, and the fallback is not needed.**

`swift-certificates` 1.20.0 resolved and built clean on both macOS 26 (Swift
6.3.3, Xcode 26.6) and `aarch64-unknown-linux-gnu` (Swift 6.3.3, `swift:6.3-noble`),
pulling `swift-asn1` 1.7.2, `swift-crypto` 4.5.2 and `swift-collections` 1.6.0.
The API below was read from the resolved checkout's own source — `Sources/X509/Certificate.swift`,
`CertificatePrivateKey.swift`, `DistinguishedNameBuilder/`, `Extensions.swift` —
and then compiled and run on both platforms.

Generating a self-signed P-256 certificate and taking its DER:

```swift
let p256 = P256.Signing.PrivateKey()
let privateKey = Certificate.PrivateKey(p256)
let name = try DistinguishedName { CommonName("skrepka-device") }

let certificate = try Certificate(
    version: .v3,
    serialNumber: Certificate.SerialNumber(1),
    publicKey: privateKey.publicKey,
    notValidBefore: notBefore,
    notValidAfter: notAfter,
    issuer: name,          // self-signed: issuer == subject,
    subject: name,         // and issuerPrivateKey is our own key
    extensions: try Certificate.Extensions {
        Critical(BasicConstraints.notCertificateAuthority)
        SubjectAlternativeNames([.dnsName("skrepka.local")])
    },
    issuerPrivateKey: privateKey
)

var serializer = DER.Serializer()
try serializer.serialize(certificate)
let der = serializer.serializedBytes   // [UInt8]
```

The overload above omits `signatureAlgorithm:`; it defaults to
`issuerPrivateKey.defaultSignatureAlgorithm`, which for a P-256 key is
`ecdsaWithSHA256` — confirmed by printing it on both platforms. `DER.Serializer`
comes from `SwiftASN1`, not from `X509`: `public init()`, `public mutating func serialize<T: DERSerializable>(_ node: T) throws`,
`public var serializedBytes: [UInt8]`.

**The encoding agrees byte for byte across platforms**, which is what
`SyncDeviceID` depends on. A certificate generated on macOS, written to a file
and re-parsed with `Certificate(derEncoded:)` on Linux re-serialised to
identical bytes — 333 bytes, `SHA256(DER) = eac761606ed0dd93e4b7d6f9ec021bd9ec77f2749b88f03cb9893d622fdc48dc`
on both. Round-tripping is stable in both directions.

**The one trap, and it matters for Phase 1: generation is not deterministic.**
ECDSA signing draws a random nonce, so building a certificate twice from the
*same* private key, serial number and validity window yields different DER and
therefore a different SHA-256 — verified by running the generator twice on one
machine and getting two hashes. `SyncDeviceID` must therefore be derived from
the **stored** certificate, read back from disk, and never recomputed by
regenerating. A device that regenerates its certificate has changed identity and
has to be re-paired; that is correct behaviour, but it has to be deliberate.

<a id="oq-7"></a>
### OQ-7 — Network framework signatures

**Answered 2026-09-05, and the question's own premise was wrong.**

`Network.swiftinterface` **does** ship. It is at
`MacOSX26.5.sdk/System/Library/Frameworks/Network.framework/Versions/A/Modules/Network.swiftmodule/arm64e-apple-macos.swiftinterface`,
2768 lines, alongside `x86_64-apple-macos` and two Catalyst slices — and
`usr/lib/swift/libswiftNetwork.tbd` is there too, so both exist rather than one
standing in for the other. The earlier claim that only the `.tbd` ships was
inconclusive rather than false at the time; it is false now, checked against
Xcode 26.6 / SDK 26.5. That changes the source order: per
[the verify-against-docs rule](../../.claude/rules/verify-against-docs.md) the
installed interface is ground truth and outranks Apple's documentation, so every
signature below is quoted from it rather than from a doc page. There is no
`arm64-apple-macos` slice — read `arm64e-apple-macos`, whose declarations are
the same.

`NWBrowser.Descriptor` is an enum, and the TXT-carrying case is a *separate
case* rather than a parameter:

```swift
public enum Descriptor : Swift.Sendable {
  case bonjour(type: Swift.String, domain: Swift.String?)
  case bonjourWithTXTRecord(type: Swift.String, domain: Swift.String?)
  @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
  case applicationService(name: Swift.String)
}
```

Both take the same two associated values, so choosing wrongly is a one-word
mistake that compiles. It shows up as `NWBrowser.Result.metadata` arriving as
`.none` instead of `.bonjour(NWTXTRecord)` — the browser still works, the TXT
record is simply never there.

`NWListener.Service` attaches a TXT record two ways, and the typed one is the
one to use:

```swift
public let txtRecord: Foundation.Data?
@available(macOS 10.15, *)
public var txtRecordObject: Network.NWTXTRecord? { get set }

public init(name: Swift.String? = nil, type: Swift.String, domain: Swift.String? = nil, txtRecord: Foundation.Data? = nil)
@available(macOS 10.15, *)
public init(name: Swift.String? = nil, type: Swift.String, domain: Swift.String? = nil, txtRecord: Network.NWTXTRecord)
```

`NWTXTRecord` is a `Sendable` struct whose entries are
`case none, empty, string(String), data(Data)`. The service is then handed to
`NWListener.init(service:using:)`, and later changes go through the `service`
property or `txtRecordObject`, with
`serviceRegistrationUpdateHandler` reporting what the daemon actually
registered — names collide and get renamed unless `noAutoRename` is set.

**Amended 2026-09-05: all of the above is correct about the API and inapplicable
to this design.** `NWListener` binds a socket of its own, and swift-nio already
owns the sync port, so it cannot be the thing that advertises it. Measured
against a plain POSIX listener holding port 7311:

```
[noreuse] state = failed(POSIXErrorCode(rawValue: 48): Address already in use)
[reuse]   state = failed(POSIXErrorCode(rawValue: 48): Address already in use)
```

`NWParameters.allowLocalEndpointReuse` does not help. `BonjourDiscovery`
therefore publishes with **`DNSServiceRegister`**, which registers a record for
a port somebody else owns and binds nothing — confirmed working against that
same held port, with a real browse result carrying the TXT record. See
`Sources/SkrepkaSync/Discovery/BonjourDiscovery.swift`.

Two consequences that follow from the same fact, both measured:

- **`NWBrowser` alone cannot feed a NIO connect.** Its results are
  `NWEndpoint.service(name:type:domain:interface:)` — no host, no port. So
  `PeerDiscovery` carries a separate `resolve` step over `DNSServiceResolve`,
  which is also what avahi needs, since its browse signals carry no TXT record
  either. Phase 3 must resolve immediately before connecting rather than once at
  discovery time: `ResolvedPeer.host` is left as a name (`BigMac.local.`) so
  NIO's resolver handles it and a peer that changes network is not pinned to a
  stale address.
- **`mDNSResponder` returns the registered type with a trailing dot**
  (`_skrepka._tcp.`) while a browse result carries it without
  (`_skrepka._tcp`). An equality check against `ServiceDescriptor.serviceType`
  fails without trimming.

**`includePeerToPeer` lives on `NWParameters`, not on the listener or browser,
and it already defaults to `false`** — printed from a live process:
`NWParameters.tcp.includePeerToPeer` and `NWParameters(tls:tcp:).includePeerToPeer`
both read `false`. So the plan's worry is a matter of not switching it on rather
than of switching it off, which is the safer shape to be in. Leave it alone and
AWDL stays out of the way of the Linux peer.

**`NWPathMonitor` does deliver an initial value, and `currentPath` before
`start` does not.** Measured rather than read, because delivery timing is
behaviour the interface cannot state: a fresh `NWPathMonitor()` reports
`currentPath.status == .unsatisfied` before `start(queue:)`, and its
`pathUpdateHandler` then fires within milliseconds of `start(queue:)` with
`.satisfied`, on the queue passed to `start` — with no network change at all.
Reading `currentPath` before starting therefore reads as "no network" on a
perfectly connected machine, which is the trap worth a comment at the call site.

The surface [D-9](#d-9) relies on:

```swift
final public var currentPath: Network.NWPath { get }
@preconcurrency final public var pathUpdateHandler: (@Sendable (_ newPath: Network.NWPath) -> Swift.Void)? { get set }
final public func start(queue: Dispatch.DispatchQueue)
final public func cancel()
public init()
public init(requiredInterfaceType: Network.NWInterface.InterfaceType)
@available(macOS 11.0, *) public init(prohibitedInterfaceTypes: [Network.NWInterface.InterfaceType])
```

Since macOS 14 it also conforms to `AsyncSequence` with `Element == NWPath` and
`Failure == Never`, so reconnect can be a `for await path in monitor` loop
instead of a callback — which suits an `actor` better and is what the transport
should use.

<a id="oq-8"></a>
### OQ-8 — `SwiftCBOR` maturity and malformed input

**Answered 2026-09-05: unsuitable for parsing frames from an unauthenticated
peer.** Verified by reading the library's own source at `master`, the HEAD of
`valpackett/SwiftCBOR`, whose latest tag is `v0.6.0`.

Two defects, and only one of them is a footgun:

- **Unbounded recursion.** `CBOROptions.maximumDepth` defaults to `.max`
  (`Sources/CBOROptions.swift`) and `CBORDecoder.decodeItem()` recurses, so a
  nested-array bomb — `9f 9f 9f …` — overflows the stack. That is a crash, not
  a thrown error. It is mitigable: pass `maximumDepth:` explicitly and the
  problem goes away. A footgun rather than a wall.
- **Unbounded allocation, and this one is not mitigable by configuration.**
  `CBORDecoder.readN(_ n: Int)` does `(0..<n).map { … }`, where `n` comes off
  the wire through `readLength`, which accepts anything up to `Int.max`.
  `Range.map` reserves capacity for `n` elements *before* reading any of them,
  so a nine-byte body that declares an array of 2^44 elements makes the process
  ask for 2^44 × `MemoryLayout<CBOR>.stride` and die before it ever discovers
  the body is empty. **A frame-size cap does not help**, because a tiny body can
  declare a huge length. That is a remote memory-exhaustion crash triggerable by
  an unauthenticated peer, which is precisely the threat this question was asked
  about.

The maintainer knows. The repository carries unmerged branches named
`hc/fix-maximum-depth-not-enforced-dos-vulnerability` and
`hc/fix-unsafe-error-handling-and-allocation-crashes`; neither is released.

Two smaller things that would have argued against it on their own: the manifest
is `swift-tools-version:5.5` with no `Sendable` conformances anywhere, so it
would sit as a Swift 5 island inside a package built in Swift 6 language mode
with strict concurrency; and the public API carries an unfixed typo,
`CBOROptions.init(shouldShortMapKeys:)` for `shouldSortMapKeys`, which is the
kind of thing that does not get fixed because fixing it is a breaking change.

**Consequence: Phase 1 hand-rolls a canonical CBOR subset inside `FrameCodec`**
— the fallback the phase document already pre-authorises at about a day. That
work is done; `CanonicalCBORTests` covers the RFC 8949 Appendix A vectors in
both directions and asserts that malformed and truncated bodies throw rather
than trap.

A small consolation for the Linux side: this removes a dependency rather than
adding one, and the codec is now the one place where the protocol's behaviour on
hostile input is written down and tested.

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

**Answered 2026-09-05: it is a lightweight migration. Phase 2 spends no time on
a `SchemaMigrationPlan`.**

Measured on macOS 26 with a throwaway store, not against
`~/Library/Application Support/dev.soldunov.skrepka/skrepka.store`: one
executable declared today's `ClipRecord` verbatim, opened a fresh store and wrote
five rows, each carrying a 1 KB `@Attribute(.externalStorage)` payload. A second
executable then opened *the same file* under a container declaring
`ClipRecord` with the four new optional properties — `pinnedAt`, `pinnedBy`,
`originDeviceID`, `representationIndex` — plus two new `@Model` entities in the
same `ModelContainer(for:)` call.

It opened. All five rows came back with their text, hash and 1024-byte
external-storage payload intact; the four new properties read `nil`; and rows
inserted into both new entities saved and fetched back. No error, no
`SchemaMigrationPlan`, no `VersionedSchema` — SwiftData migrated the store in
place.

This is the expected result for the shape involved: adding optional properties
and adding entirely new entities are both additive changes SwiftData handles
automatically. What it does *not* license is renaming, retyping or making an
existing property non-optional, none of which Phase 2 does.

<a id="oq-10"></a>
### OQ-10 — Avahi service registration from Swift

**Answered 2026-09-05, and it lands on the top rung: Swift talks to
`org.freedesktop.Avahi` over D-Bus today, with no shelling out and no
hand-written proxies.** This was one of the two questions deciding whether Swift
is the right language for the Linux side. It answers yes.

**`wendylabsinc/dbus` 0.4.1 is the one to use.** It builds clean on Swift 6.3.3
aarch64 Linux. Its product is named **`DBUS`**, not `DBus` — asking for `DBus`
fails resolution with `product 'DBus' … not found in package 'dbus'`. It is a
pure-Swift NIO implementation of the wire protocol, so it needs no `libdbus-1`
and no system library target.

Proof, run end to end in a `swift:6.3-noble` container with `avahi-daemon`
installed: the package's own `AvahiBrowse` example connected to the system bus
over `/var/run/dbus/system_bus_socket` with EXTERNAL authentication, called
`org.freedesktop.Avahi.Server.GetVersionString` — which answered `avahi 0.8` —
created a `ServiceBrowser` through `ServiceBrowserNew`, and received its signals
through to `AllForNow`. Getting avahi running inside a plain container does need
two things done by hand, and neither is obvious: `dbus-daemon --system --fork`
first, then `avahi-daemon --no-drop-root --daemonize --no-chroot`.

**Fallback A is not a fallback; it is how the package already works.** The
`DBusCodegenPlugin` build-tool plugin generates typed Swift proxies from D-Bus
introspection XML at build time — `Sources/AvahiBrowse/avahi.dbus.xml` becomes
`OrgFreedesktopAvahiServerProxy` and `OrgFreedesktopAvahiServiceBrowserProxy`
with no checked-in generated code. And the XML does not have to be captured from
`busctl introspect` either: **`avahi-daemon` installs the canonical interface
definitions itself**, at `/usr/share/dbus-1/interfaces/org.freedesktop.Avahi.*.xml`
— `Server`, `EntryGroup`, `ServiceBrowser`, `ServiceResolver`,
`ServiceTypeBrowser`, `DomainBrowser`, `RecordBrowser`, `AddressResolver`,
`HostNameResolver`. Phase 6 copies the two it needs into the repo and points the
plugin at them.

**Registration was not exercised, only browsing** — label that unverified. The
path is `Server.EntryGroupNew` (present on the live bus; confirmed by
introspecting `org.freedesktop.Avahi /`), then on the returned object path:

```xml
<method name="AddService">
  <arg name="interface" type="i" direction="in"/>
  <arg name="protocol"  type="i" direction="in"/>
  <arg name="flags"     type="u" direction="in"/>
  <arg name="name"      type="s" direction="in"/>
  <arg name="type"      type="s" direction="in"/>
  <arg name="domain"    type="s" direction="in"/>
  <arg name="host"      type="s" direction="in"/>
  <arg name="port"      type="q" direction="in"/>
  <arg name="txt"       type="aay" direction="in"/>
</method>
```

then `Commit`, watching the `StateChanged` signal — `EntryGroup` also carries
`AddRecord`, `AddServiceSubtype`, `UpdateServiceTxt`, `Reset`, `Free`,
`GetState` and `IsEmpty`. Note `txt` is `aay`, an array of byte arrays: each TXT
entry is raw `key=value` bytes, not a string, so the encoding is Skrepka's to
get right rather than avahi's. `interface` and `protocol` take `-1` for
`AVAHI_IF_UNSPEC` / `AVAHI_PROTO_UNSPEC`.

**`PureSwift/DBus` was evaluated and rejected.** It builds on Swift 6.3 Linux,
but only from a branch pin: resolving its latest tag, 0.2.0, fails with
`package 'dbus' is required using a stable-version but 'dbus' depends on an
unstable-version package 'cdbus'`. Pinning a dependency to a moving branch in a
shipped package is not acceptable, and it wraps `libdbus-1` through a C shim,
which adds a system-library build dependency the other one does not need.

**Fallback B — shelling out — is not needed, and is recorded only so it is not
re-derived.** `avahi-publish -s <name> _skrepka._tcp <port> "k=v" …` works, and
`avahi-browse -rpt _skrepka._tcp` emits semicolon-separated records where `+`
lines are discoveries and `=` lines are resolutions:

```
+;eth0;IPv4;skrepka-test;_skrepka._tcp;local
=;eth0;IPv4;skrepka-test;_skrepka._tcp;local;host.local;192.168.215.2;7011;"v=1" "deviceid=abc123"
```

TXT entries arrive as space-separated double-quoted tokens in the last field,
which is parseable but is the part that would break on a value containing a
quote or a space. The D-Bus path avoids the question entirely.

<a id="oq-11"></a>
### OQ-11 — `Observation` and `@MainActor` on Linux

The design document states `Observation` is built for Linux in the stdlib. Two
files depend on it — `Settings/Preferences` and `Diagnostics/CaptureHealth`,
173 lines between them — and both are also `@MainActor`.

**Answered 2026-09-05: `Observation` and `@MainActor` both work on Linux.** This
was the other question deciding whether Swift is the right language for the
Linux side, and it too answers yes. Two Linux-only gotchas came out of it, and
one of them changes what Phase 4 has to do.

`Observation.swiftmodule` and `libswiftObservation.so` ship in `swift:6.3-noble`.
Both files compile there under the repo's exact `sharedSwiftSettings` —
`.swiftLanguageMode(.v6)`, `.treatAllWarnings(as: .error)`, and the three
upcoming features. `@MainActor` behaves: the isolation is enforced, and calling
in from a non-isolated context is the compile error it should be. 86 tests
across 9 suites now pass on Linux against the real targets.

**Gotcha one: Linux needs an explicit `import Observation`, macOS does not.**
`Diagnostics/CaptureHealth.swift` imported only `Foundation` and failed with

```
error: unknown attribute 'Observable'
```

while `Settings/Preferences.swift`, which imports `Observation` explicitly,
compiled unchanged. macOS supplies the macro transitively; Linux does not. The
import has been added, and the rule for Phase 4 is: **every file using
`@Observable` imports `Observation` by name.** It costs nothing on macOS and it
is a hard error on Linux.

**The semantics hold, not just the syntax.** Four tests written specifically to
distinguish "it compiles" from "it works", all passing on Linux: mutating an
observed property and reading it back; `withObservationTracking` firing its
`onChange` when a property the closure *read* is written; and — the one that
would catch a stub implementation — `withObservationTracking` **not** firing when
a different property is written. Tracking is genuinely per-property on Linux, not
an all-or-nothing approximation.

**Gotcha two, and this one is a real behaviour difference:
`UserDefaults` writes do not reach disk on swift-corelibs-foundation unless you
call `synchronize()`.** The plan flagged this as worth a test rather than an
assumption, and it was right. Measured with two separate processes sharing a
suite:

- Write through `Preferences`' `didSet`, exit, read in a fresh process →
  **everything came back as defaults.** Nothing was written; no file appeared
  anywhere on disk.
- Same, with `defaults.synchronize()` before exit → the values survived, and
  `~/.config/<suite>.plist` was on disk.

There is no `cfprefsd` on Linux, and nothing flushes at exit. `synchronize()` is
deprecated on Darwin and load-bearing here, so the Linux `Preferences` will need
it — behind a `#if canImport(Darwin)` split, or by making the persistence a
protocol whose Linux conformance flushes.

**And `UserDefaults.standard` is unusable on Linux for a multi-process app.** The
file it wrote was named after the *executable* — a process called `Writer`
produced `~/.config/Writer.plist` — so a daemon and a CLI that both read
`.standard` read two different files and never see each other's settings. Phase 4
must construct `UserDefaults(suiteName:)` with a fixed suite name on Linux rather
than taking `.standard`, which the existing `Preferences(defaults:)` initialiser
already allows for without any change to its shape.

<a id="oq-12"></a>
### OQ-12 — Core Graphics path types on Linux

**A finding the design document missed.** `Branding/PaperclipPath.swift` is 142
lines and imports `CoreGraphics`, not AppKit, so it does not appear in the
design's list of excluded files. It is the single source of the app icon, the
menu-bar mark and the in-app artwork.

**Answered 2026-09-05, and the answer is broader than the question.** Not only
are the three path types absent — **the `CoreGraphics` module itself does not
exist on Linux.** Verified by compiling each case on its own in a container
(Swift 6.3.3, `aarch64-unknown-linux-gnu`), with the exact diagnostics:

```
error: no such module 'CoreGraphics'
```

for `import CoreGraphics`, and, with only `import Foundation` in scope:

```
error: cannot find 'CGAffineTransform' in scope
error: cannot find 'CGMutablePath' in scope
error: cannot find type 'CGPath' in scope
```

The half the design document got right: `CGFloat`, `CGPoint`, `CGRect` and
`CGSize` **do** come from swift-corelibs-foundation and compile on Linux with
`import Foundation` alone, no `CoreGraphics` anywhere. So the geometry value
types port and the drawing types do not, which is exactly the split a portable
path IR would sit on.

**`Branding/PaperclipPath.swift` is now fenced with `#if canImport(CoreGraphics)`,**
which is the right guard rather than `#if os(macOS)`: it asks the question the
compiler can actually answer, and it is the same guard that would let the file
compile unchanged on any future Apple platform.

The fallback stands as the plan wrote it and is now scheduled rather than
speculative: extract a portable path value type of `move` / `line` / `curve` /
`close`, rendered to `CGPath` on macOS and to Cairo on Linux. Half a day, Phase 7
work, not needed before then — nothing in Phases 4 through 6 draws the mark.
`scripts/paperclip.svg` stays the design source and `scripts/make-icon.sh` keeps
compiling one file, so the icon and the menu bar still cannot drift.

<a id="oq-13"></a>
### OQ-13 — The Linux quality gate's tooling

Four small unknowns that together decide what `scripts/doctor-linux.sh` can
check. **All four answered 2026-09-05, and the script now exists** — it runs
green, with two named skips, from macOS and natively on Linux alike.

**1. `swift-format` is bundled.** It is at `/usr/bin/swift-format` in
`swift:6.3-noble`, version 6.3.3 against the macOS toolchain's 6.3.0, and
`swift format` works as a driver subcommand too. `swift-format lint --help`
declares `--strict`, `--recursive` and `--parallel`, so the Linux gate runs the
macOS gate's command with `xcrun` dropped and nothing else changed. It is a hard
check, not an optional one.

**2. SwiftLint ships a prebuilt Linux aarch64 binary.** Release 0.65.1 carries
`swiftlint_linux_arm64.zip` (and `_amd64`), a dynamically-linked
`ELF 64-bit … ARM aarch64` executable. Downloaded, run in the container against
this repo's `.swiftlint.yml`, `lint --strict --quiet` exits 0. No source build,
no 30-minute budget spent. It is not *in* the stock `swift:6.3-noble` image, so
from macOS the check reports itself skipped; baking it into a derived image and
pointing `SKREPKA_LINUX_IMAGE` at that turns it on.

**3. Periphery ships no Linux binary, but builds from source on Linux.** The
3.8.0 `artifactbundle`'s own `info.json` declares exactly two variants —
`x86_64-apple-macosx` and `arm64-apple-macosx` — and the plain
`periphery-3.8.0.zip` contains a Mach-O `libIndexStore.dylib`. So there is
nothing to install. Its `Package.swift` guards the Xcode-specific pieces with
`#if os(macOS)`, and `swift build -c release --product periphery` in the
container produced a working `periphery` binary that answers `3.8.0` — only a
test-support target fails, on an unrelated `@testable` problem. The gate treats
it as optional and says out loud that the dead-code scan is a macOS check unless
someone has done that source build.

**4. The `swift build` form — and a trap that makes a gate lie.**

`swift build --scratch-path .build-linux --product SkrepkaLinux` is the answer,
and it required a manifest change to become one. `--product` **refuses an
automatic library product**:

```
warning: '--product' cannot be used with the automatic product 'SkrepkaLinux'; building the default target instead
```

and "the default target instead" is the everything-build the product exists to
avoid — app target, `KeyboardShortcuts`, `error: no such module 'SwiftUI'`.
Declaring it `type: .static` fixes it, and that is why the manifest now says
`.library(name: "SkrepkaLinux", type: .static, targets: ["SkrepkaCore", "SkrepkaSync"])`.

**Repeated `--target` is the wrong answer and it fails silently.** `--target` is
singular in `swift build --help` ("Build the specified target"), and SwiftPM
accepts the flag twice without complaint — then builds only the last one and
exits 0. Measured in a fresh scratch directory:
`swift build --target SkrepkaCore --target SkrepkaSync` exited 0 while
`SkrepkaCore` alone failed, because `SkrepkaCore` was never compiled. A gate
written that way is green and worthless.

**`swift test` was the real blocker, and it needed a manifest fix rather than a
flag.** `swift test` has neither `--product` nor `--target`; it builds the whole
package, so `--filter` selects which tests *run*, never what gets *compiled*.
That meant every Linux test run compiled the macOS-only app target and died on
`no such module 'SwiftUI'`. The fix is to fence the app target out of the
manifest on Linux — `Package.swift` is Swift evaluated on the build host, so
`#if os(macOS)` there asks about the machine running SwiftPM, which is the right
question. It has to be an **append after** the `Package(...)` call:

```swift
#if os(macOS)
    package.products.append(.executable(name: "Skrepka", targets: ["Skrepka"]))
    package.dependencies.append(/* KeyboardShortcuts */)
    package.targets.append(.executableTarget(name: "Skrepka", …))
#endif
```

because `#if` is not valid as a container-literal element —
`error: expected expression in container literal`. With that in place
`swift test --scratch-path .build-linux --filter SkrepkaSyncTests` runs 46 tests
in 7 suites green on Linux, and `swift build --product Skrepka` still works on
macOS.

**The scratch path is not shared.** `.build-linux`, never `.build`: the two
toolchains produce incompatible module caches. Worth knowing that a cache built
under a *different mount path* is also poisoned —
`precompiled file '…' was compiled with module cache path '/src/…', but the path
is currently '…'` — which is why `scripts/linux.sh` mounts the repository at the
same absolute path it has on the host.

<a id="oq-14"></a>
### OQ-14 — What do the existing cross-platform clipboard syncers do?

CrossPaste, ClipCascade and ClipSync are the closest existing peers: LAN-only,
mDNS, end-to-end encrypted, cross-platform. All are Kotlin/JVM or Go, so nothing
is reusable as code, but twenty minutes of reading their wire formats before
finalising Phase 1 was the cheapest review available.

**Read 2026-09-05.** The headline: **only one of the three syncs history at all,
and none of them syncs deletion.** Skrepka is doing something the field has
mostly not attempted, which is worth knowing before assuming the design is
over-built.

**CrossPaste** (Kotlin/Compose Multiplatform, LAN-only, end-to-end encrypted —
the nearest neighbour) syncs history. Its wire DTO, read from
`core/src/commonMain/kotlin/com/crosspaste/dto/paste/SyncPasteData.kt`:

```kotlin
data class SyncPasteData(
    val id: String,
    val appInstanceId: String,
    val pasteId: Long,
    val pasteType: Int,
    val source: String?,
    val size: Long,
    val hash: String,
    val favorite: Boolean,
    val pasteAppearItem: PasteItem?,
    val pasteCollection: SyncPasteCollection?,
    val labels: Set<SyncPasteLabel>,
)
```

Three things fall out of that. **There is no timestamp on the wire** — in
`PasteData` the `createTime` field is `@Transient`, so the receiver stamps its
own clock and a peer with a wrong clock cannot corrupt anyone else's ordering.
**There is no deletion field**: `favorite` is the retention flag, the equivalent
of Skrepka's pin, and deleting is a local act that never leaves the machine.
Syncing is pull-based with a per-peer cursor keyed on the sender's create time
(`PastePullCursorManager.getMaxCreateTime(appInstanceId)`, persisted through
`pasteDao.upsertPastePullCursorMaxCreateTime`), so a peer asks "what do you have
newer than X" rather than being pushed at. `SyncInfo` likewise stamps discovered
host addresses with `now = DateUtils.nowEpochMilliseconds()` on the *receiving*
side. The pattern throughout is: trust the peer for content, never for time.

**ClipCascade** (Java/Spring server plus clients) syncs **the live clipboard
only** — "clipboard content updates in real time across all connected devices" —
in either a server-relayed or a peer-to-peer mode, with a shared-password
end-to-end encryption scheme. There is no history and therefore no
retention-versus-deletion question and no clock question. *Read from its README
rather than its source; the wire detail here is unverified.*

**ClipSync** is an ambiguous name with no dominant project. The closest match to
this comparison is `marcopaganini/clipsync` (Go): live clipboard only,
broadcast through an MQTT broker, symmetrically encrypted with a password file
copied to every machine. No history, no deletion, no clock handling — last write
wins by broker arrival order.

**What this changes for Phase 1: nothing, and that is the useful outcome.** The
two design decisions worth checking were the tombstone and the timestamp, and
the field is no help on either — the one project that syncs history simply does
not sync deletion, which is a smaller product rather than a better answer. The
one habit worth borrowing is CrossPaste's: **prefer the receiver's clock for
anything stored**, and treat a sender's timestamp as data to order by rather
than as truth. Skrepka's LWW register already breaks ties on device identifier
rather than on the clock alone, which is the same instinct.

<a id="oq-15"></a>
### OQ-15 — The short authentication string lets whoever moves second choose its inputs

**Raised 2026-09-06 during the Phase 3 review. Mitigated, not closed.**
`ShortAuthString.hexDigitCount` went from 8 to 16 — 32 bits to 64 — which makes
the search below infeasible inside the freshness window. The structural fix is a
protocol change and has not been made.

**The problem.** `ShortAuthString.derive` is
`SHA256(sort(K_a, K_b) ‖ bigendian_millis(pairedAt))`, truncated. Nothing in the
exchange commits either side's contribution before the other's is known, and an
attacker relaying a pairing is second on both legs:

- On the leg where the honest device dials it, the attacker is the **responder**.
  It reads the `pairRequest` — which carries the honest device's certificate and
  its chosen `pairedAt` — before it has to answer with anything.
- On the leg where it dials the honest peer, the attacker is the **initiator**,
  and `SyncInitiator.pair(at:)` lets it choose *both* a fresh keypair, of which
  there are unlimited, and any `pairedAt` that `PairingSession.verify` accepts —
  600,000 millisecond values inside `SyncLimits.pairingFreshnessWindow`.

So the attacker is not guessing a fixed string once. It is searching for a second
preimage of a digest it already knows, with two free variables and no
commitment, and the only thing bounding that search is the number of bits it has
to hit. At 32 that was roughly 2³² hashes of a short input: seconds on one GPU,
against a 300-second window. The comment that used to sit on `hexDigitCount` —
that the freshness window "keeps it to a single attempt" — was false, and is the
specific reasoning this entry exists to correct. The window bounds the
*timestamp* dimension. The keypair dimension is free.

**Why the width was raised rather than the window cut.** The attack is online:
the target digest is not known until the honest device sends its `pairRequest`,
and `SyncChannelWiring.pairingReadTimeout` — which is defined as
`pairingFreshnessWindow` — is how long that device will wait to be answered. So
there is a time bound as well as a width. But **the width is the one doing the
work**: 2⁶⁴ is ~1.8 × 10¹⁹, about 58 years at ten billion hashes a second, so
even an attacker who could hold the honest side open indefinitely or grind
offline for a week does not get there. Nothing on the *initiator's* side refuses
a stale `pairRequest` — only the responder's `PairingSession.verify` does — so
the socket timeout is the only thing bounding that leg, and it is worth knowing
that 64 bits does not depend on it.

Cutting `pairingFreshnessWindow` from 300 s to 30 s would therefore buy very
little, and would pay for it with a real failure on two machines whose clocks
were never synchronised against NTP — which is the case that constant's own
comment was written for. The two constants are **not** jointly load-bearing:
do not shorten one because the other looks generous.

**The structural fix, not done: commit-then-reveal on both legs.** The initiator
sends `H(nonce_i)` in the `pairRequest`; the responder replies with `nonce_r` in
the clear; the initiator then reveals `nonce_i`, and both derive over
`sort(K_a, K_b) ‖ nonce_i ‖ nonce_r`. Neither side can choose its contribution
after seeing the other's, which is what ZRTP and Bluetooth Secure Simple Pairing
do and what lets them get away with a six-digit code. A responder nonce alone
does **not** fix it: the attacker is second on the responder leg too, so it would
still be choosing after seeing.

**Why it was not done here.** It turns a two-message first contact into four, and
`PinPolicy.pairingMessages` carries a written argument that exactly two messages
is what makes "does an unauthenticated peer see anything of mine" checkable by
eye. It rewrites the wire format, both roles, the probe and the sheet flow, in
the most security-critical file in the repository. A botched commitment is worse
than a wide code, so widening bought the room to do it deliberately.

**What it blocks.** Nothing today; 64 bits is a sound mitigation. It should be
done **before this ships to anyone**, not after, because it is a wire change and
`ProtocolVersion` would have to carry it — which is cheap while the installed
base is one machine ([D-8](#d-8)) and expensive once it is not.
