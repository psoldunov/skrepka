# Phase 2 — Storage, identity, transport, discovery

**A week. Four pieces of plumbing, grouped because none of them is
independently demonstrable.**

## Goal

Two `SyncConnection`s in one process pair over loopback, exchange indexes,
merge, and fetch a payload — with everything persisted.

## Preconditions

- Phase 1 done.
- Nothing else blocking. [OQ-9](open-questions.md#oq-9) used to gate this phase;
  [D-8](open-questions.md#d-8) downgraded it to a twenty-minute check with
  `rm skrepka.store` as the fallback.
- [OQ-5](open-questions.md#oq-5), [OQ-6](open-questions.md#oq-6) and
  [OQ-7](open-questions.md#oq-7) answered before the transport and discovery
  work starts. They are interface reads, not experiments — an hour each.

## Deliverables

```
Sources/SkrepkaCore/Store/
  ClipRecord.swift               # + pinnedAt, pinnedBy, originDeviceID,
                                 #   representationIndex
  TombstoneRecord.swift          # new @Model
  PairedDeviceRecord.swift       # new @Model
  HistoryStore.swift             # + syncIndex, applyRemote, tombstones,
                                 #   recordTombstone
  HistoryStore+Sync.swift        # the sync surface, kept out of the main file
  SyncMetaMapping.swift          # ClipRecord ↔ SyncClipMeta

Sources/SkrepkaSync/
  Pairing/
    DeviceCertificate.swift
    ShortAuthString.swift
    PairingSession.swift
    TrustStore.swift             # protocol + an in-memory conformance
  Transport/
    SyncServer.swift
    SyncClient.swift
    SyncConnection.swift
    SyncTLS.swift
    FrameDecoder.swift           # NIO ByteToMessageDecoder over FrameCodec
  Discovery/
    PeerDiscovery.swift          # protocol
    ServiceDescriptor.swift
    BonjourDiscovery.swift       # #if canImport(Network)

Sources/Skrepka/Sync/
  KeychainTrustStore.swift       # the app target's TrustStore conformance

Tests/SkrepkaSyncTests/
  ShortAuthStringTests.swift
  PairingSessionTests.swift
  LoopbackSyncTests.swift        # the phase's proof
Tests/SkrepkaCoreTests/
  HistoryStoreSyncTests.swift
```

## Work

### 1. Storage

**Why there is a migration question at all.** Nothing about sync makes the app
leave SwiftData; macOS keeps it (see
[Phase 4](phase-4-core-on-linux.md)). The question exists because *sync adds
fields*, and a schema change against a store that already holds history has to be
reconciled with what is on disk. There is currently nothing to reconcile it
with: the codebase contains **no `VersionedSchema`, no `SchemaMigrationPlan`,
no migration scaffolding of any kind** — verified 2026-09-05 — and
`HistoryStore.swift:38` builds a single-entity container,
`ModelContainer(for: ClipRecord.self, ...)`.

**That question is small, because the install base is one machine**
([D-8](open-questions.md#d-8)). Back the store up, make the change, and if
SwiftData refuses it, delete the file and start fresh. So: add the properties
directly, and do not build machinery to avoid a migration nobody is exposed to.

`ClipRecord` gains four properties, all optional or defaulted so the existing
shape stays readable:

| Property | Type | Why |
|---|---|---|
| `pinnedAt` | `Date?` | the timestamp half of the pin's LWW register |
| `pinnedBy` | `String?` | the `SyncDeviceID` half, for tie-breaking |
| `originDeviceID` | `String?` | which device first captured this |
| `representationIndex` | `Data?` | see below |

Two new `@Model` types, `TombstoneRecord` and `PairedDeviceRecord`, join
`ClipRecord` in the container, making it a three-entity schema.

**`representationIndex` is not optional cleverness.** `syncIndex()` has to
report each item's representation keys and their byte counts, and the only place
those live today is inside `ClipRecord.payloadData` — which is
`@Attribute(.externalStorage)`, so reading it pulls a separate file off disk. A
500-item index offer would mean 500 external reads and 500 property-list decodes
to produce a few kilobytes of metadata. Denormalise it: a small encoded
`[String: Int]` written once at capture, alongside the payload it describes.

**Considered and rejected: a sidecar container.** Putting every sync field in a
second store keyed by `contentHash` would leave `skrepka.store` untouched
forever, at the cost of two independently-failing `save()` calls, an in-memory
join on every index, and a sweep to stop the sidecar leaking rows. That is a
reasonable trade when a schema change threatens other people's data. It is not
one now. **Revisit it if the install base grows before Phase 2 ships** — the
reasoning is preserved here so it does not have to be re-derived.

**`HistoryStore` gains a sync surface**, in a new
`HistoryStore+Sync.swift` rather than in the 204-line main file:

```swift
/// Metadata for every syncable item. Never includes concealed content.
public func syncIndex(since cursor: Date?) throws -> [SyncClipMeta]

/// Applies a merge plan. Atomic per batch, one reload.
/// (SQLite holds one transaction for the plan; SwiftData saves every
/// `syncBatchSize` actions, because one save over 500 was a third of a
/// second on the main actor. A plan is idempotent, so a partial apply is
/// re-derivable — but do not advance the cursor on a throw.)
public func applyRemote(_ actions: [MergeAction]) throws

public func tombstones(since: Date?) throws -> [Tombstone]
public func recordTombstone(_ tombstone: Tombstone) throws
```

**Concealed content is filtered here**, in `syncIndex`, not in `SkrepkaSync`.
The sync target never sees a payload it was not handed, so the storage boundary
is the only honest place for the rule.

**No toggle** ([D-7](open-questions.md#d-7)): concealed items never cross the
wire in v1, and there is no preference to change that. So the filter is
unconditional and `syncIndex` needs no parameter for it — which is also what
makes `HistoryStoreSyncTests.syncIndexOmitsConcealed` a one-case test rather
than a two-case one.

If the feature is ever wanted, D-7 records why encrypting them and syncing
anyway was not the answer, and which version to revisit first.

**`delete()` and `clear(keepingPinned:)` start writing tombstones.**
`applyRetention()` deliberately does not, and it needs a comment saying so
loudly, because it is one line away from `delete()` in the same file and the
distinction is invisible to a reader who does not already know it matters.

**Reuse `recordMatching(contentHash:)`** at `HistoryStore.swift:171`. It is
private today and becomes the lookup `applyRemote` runs for every action.

### 2. The main-actor problem, which is real

`HistoryStore` is `@MainActor` because it owns `ModelContainer.mainContext` and
publishes `items` straight to the picker. That is right for capture — one item
arrives at a time from the watcher's stream. It is wrong for a merge: applying a
500-action plan on the main actor, with a `reload()` and a full re-sort at the
end, is a visible hitch on the machine that is merely *receiving*.

Three options, in the order they should be tried:

1. **Batch and yield.** `applyRemote` chunks the plan, saves once per chunk, and
   reloads once at the end rather than per action. Cheapest, and probably
   enough: the plan is metadata only, no payload bytes.
2. **A background `ModelContext`** for merges, with the main context reloading
   after. More correct, more moving parts, and it means two contexts can now
   disagree.
3. **Take `HistoryStore` off the main actor entirely.** Correct, and the largest
   change on this list — every call site in `AppCoordinator` and `PickerModel`
   moves with it.

Start with 1, measure with a 5,000-item store, and only escalate if it hitches.
Do not start with 3 because it is architecturally tidier; it is a week that buys
nothing if 1 works.

**Superseded 2026-09-05 — and none of the three options was the answer.**
Measured, then fixed; see `Sources/SkrepkaCore/Store/HistoryStore+Projection.swift`
and the numbers recorded in `HistoryStore+Merge.swift`.

Option 1 was tried and helped (304 → 172 ms for a 500-action plan at 5,000
items), but the breakdown showed **79% of what remained was the
`FetchDescriptor` round trip inside `reload()`** — SwiftData materialising every
row to republish a list. Options 2 and 3 relocate the merge work and leave that
untouched, so neither would have fixed it.

The real defect was that `reload()` recomputed the whole projection from scratch
on every mutation, discarding the delta each caller already knew. `items` is now
maintained incrementally by `ClipProjection`, with a DEBUG-only invariant that
re-derives the list from the database and records the first mismatch. **That
invariant found a real bug during development** — a pin flip moved its row past
entries sharing its `createdAt` — which is the argument for having it.

It was never only a merge problem: `reload()` ran on **every `capture()`** too,
so the cost was paid on every copy the user made and grew with their history.

| | 500 items | 5,000 items |
|---|---|---|
| `capture()` before | 11.4 ms | 106.1 ms |
| `capture()` after | 0.7 ms | 3.7 ms |
| `applyRemote(500)` before | 70.4 ms | 167.9 ms |
| `applyRemote(500)` after | 51.4 ms | 55.2 ms |

`applyRemote` no longer scales with store size; the ~50 ms left is the merge
itself. `ClipSummary` also stopped carrying thumbnail bytes — that was 41–123 MB
held resident and copied on every keystroke through `Matcher.filter` — and the
picker reads them per row through `HistoryStore.thumbnail(for:)`.

### 3. Identity and pairing

**`DeviceCertificate`** — generate a self-signed P-256 certificate once per
device, and derive `SyncDeviceID` from its DER encoding. Confirm the
`apple/swift-certificates` API against the resolved version before writing this
([OQ-6](open-questions.md#oq-6)), including whether it builds on Linux at all —
if it does not, this phase's design changes and Phase 4 inherits the problem.

**Where the private key lives** is platform-specific and belongs behind
`TrustStore`:

- macOS: the Keychain, via `KeychainTrustStore` in the app target.
- Linux: a file at `$XDG_DATA_HOME/skrepka/device.key`, mode `0600`, created
  with those permissions rather than chmod'ed afterwards. Phase 6 writes it.
- Tests: an in-memory conformance, which is why `TrustStore` is a protocol.

**`ShortAuthString`** — eight hex characters, `A3F2-91BC`, derived as
`SHA-256(sorted DER public keys ‖ pairing timestamp)`. Sorting the keys is what
makes both ends compute the same string without agreeing who is "first"; the
timestamp is what kills replay of a stale key. Both are lifted from KDE
Connect's `pairinghandler.cpp` and both need a test.

**Anti-downgrade.** After the handshake completes, each side re-sends its
identity record *inside* the tunnel and aborts if `deviceId` or `proto` differs
from the pre-TLS values, and refuses a peer whose advertised `proto` is lower
than the last one seen from it. That last rule needs somewhere to remember the
high-water mark: `PairedDeviceRecord`.

### 4. Transport

`swift-nio` + `swift-nio-ssl` on both platforms, rather than Network framework
on macOS. One implementation of a security-critical handshake, and it avoids the
C-block dance at the verification callback.

**This is the one place the plan trades native-on-macOS for portability**, and
[D-9](open-questions.md#d-9) flags it deliberately rather than letting it pass.
The trade is accepted because writing pinned-certificate verification twice is
the worst duplication available — a callback that silently verifies nothing
looks identical to one that works.

**What Network framework would have given, and how to get it anyway:** the real
gap is not TLS, it is that Network framework notices sleep, wake, Wi-Fi changes
and VPN transitions while NIO does not. A laptop doing LAN sync hits all four
daily. So **add `NWPathMonitor` on macOS** — native path monitoring driving
reconnect, with one NIO transport underneath. `NWBrowser`/`NWListener` are
already in use here for discovery, so the framework is linked regardless.
Confirm `NWPathMonitor` alongside the rest of
[OQ-7](open-questions.md#oq-7).

- `minimumTLSVersion = .tlsv13`, mutual auth, and a custom verification callback
  that accepts **only** the pinned fingerprint. Confirm
  `NIOSSLCustomVerificationCallback`'s signature and the `TLSConfiguration`
  shape against the resolved `swift-nio-ssl` before writing it
  ([OQ-5](open-questions.md#oq-5)) — this is precisely the kind of API the
  repo's verify-against-docs rule exists for, and getting it subtly wrong
  produces code that connects successfully while verifying nothing.
- `FrameDecoder` is a `ByteToMessageDecoder` wrapping `FrameCodec.decode`, which
  was written streaming-shaped in Phase 1 for this reason.
- The frame size cap is enforced in the decoder, before allocation. A peer
  claiming a 4 GB body must not be able to make this process ask for 4 GB.

### 5. Discovery

`PeerDiscovery` is a protocol with two conformances across the project's life;
this phase writes one.

`BonjourDiscovery` uses the Network framework behind `#if canImport(Network)`.
Two details from design §9 that are easy to get wrong and silent when wrong:
use `NWBrowser.Descriptor.bonjourWithTXTRecord`, because TXT records do not
arrive on plain `.bonjour`; and set `includePeerToPeer = false`, because AWDL is
Apple-only and useless for a Linux peer. Confirm both signatures against the
macOS 26 SDK ([OQ-7](open-questions.md#oq-7)) — note that no
`Network.swiftinterface` ships, only `libswiftNetwork.tbd`, so documentation is
the only source and that fact belongs in the commit message.

Service type `_skrepka._tcp`. TXT record per design §9, minus the `fp=` key that
Phase 1 folded into `id=`.

## Tests

| Test | Asserts |
|---|---|
| `HistoryStoreSyncTests.syncIndexOmitsConcealed` | unconditionally — there is no preference that lets them through (D-7) |
| `HistoryStoreSyncTests.deleteWritesATombstone` | and `clear(keepingPinned:)` writes a batch |
| `HistoryStoreSyncTests.retentionWritesNoTombstone` | the most important test in the phase |
| `HistoryStoreSyncTests.applyRemoteIsIdempotent` | applying the same plan twice changes nothing the second time |
| `ShortAuthStringTests.bothSidesDeriveTheSameString` | with the key order swapped |
| `ShortAuthStringTests.timestampChangesTheString` | replay protection, asserted rather than assumed |
| `PairingSessionTests.rejectsMismatchedInTunnelIdentity` | the anti-downgrade rule |
| `PairingSessionTests.refusesProtocolDowngrade` | against a remembered high-water mark |
| `LoopbackSyncTests.pairsIndexesAndFetches` | the phase's proof, end to end, in one process |
| `LoopbackSyncTests.rejectsUnpinnedCertificate` | a peer with a valid but unpinned certificate is refused |
| `LoopbackSyncTests.rejectsOversizedFrameBeforeAllocating` | the 4 GB-body case |

## Done when

- `LoopbackSyncTests.pairsIndexesAndFetches` passes: two connections in one
  process complete pair → index → payload fetch.
- The existing `skrepka.store` opens under the new schema. If it does not,
  deleting it is an acceptable outcome ([D-8](open-questions.md#d-8)) — do not
  spend the phase building migration machinery.
- `scripts/doctor.sh` green; `swift build --target SkrepkaSync` green on Linux.

## Two limits the review added

Both live in `SyncLimits` and both bound something a peer controls.

**`maximumWireItemCount`** (2^20) bounds the *number of decoded values* in one
CBOR body, not just their declared lengths. Bounding each length against the
bytes remaining does not bound their product: a 33 MB body of one-byte nulls is
33.5M `CBORValue`s, half a gigabyte resident and near a gigabyte at the peak of
the array's growth, and it passes every other check because the bytes really are
there. The frame ceiling is about transfer; this one is about what decoding it
costs. Sized from the largest legitimate message — a 5000-item `indexOffer` with
its tombstones decodes to roughly 675,000 values.

Note `SyncResponder.answerIndexRequest` returns `syncIndex(since:)` whole and
does not page, so a history far past 5000 items would hit this budget before it
hit the frame limit. If that becomes real, page the offer rather than raise the
constant.

**`maximumClockSkew`** (5 minutes, mirroring `pairingFreshnessWindow`) bounds how
far ahead of the receiver's clock an inbound timestamp may sit. `InboundClock`
refuses `SyncClipMeta.createdAt`, `LWWRegister.timestamp` and
`Tombstone.deletedAt` past it, on receipt, before `MergeEngine` sees them —
because the engine is pure and `MergeInput.now` is one instant rather than a
second opinion. Without it a peer whose clock is an hour fast writes values no
honest write outranks: its pin beats every later unpin from the other machine,
for the whole hour.

Refused rather than clamped, and the reasoning matters. Clamping does not fix it
— the fast peer keeps its original timestamp and re-offers it every sync, landing
on a *new* receipt instant each time, so it still beats whatever the user did in
between, just on a shorter cycle. Refusing costs the other thing: a clipping made
on the fast machine does not arrive until its clock is fixed. That is bounded,
visible as a missing item, and self-healing. It is also currently **silent** —
`SkrepkaSync` has no logger — which is the weakest part of the fix and should be
surfaced when one arrives.

## Risks

**The migration destroys history.** No longer a real risk
([D-8](open-questions.md#d-8)): one machine, expendable data. Worth thirty
seconds of `cp skrepka.store skrepka.store.bak` before the first run under the
new schema, and nothing more. If the install base grows before this phase ships,
reinstate the mitigations D-8 lists.

**The transport verifies nothing.** A pinned-certificate callback that returns
"trusted" on the wrong branch produces code that works perfectly and protects
nothing. `LoopbackSyncTests.rejectsUnpinnedCertificate` is the test that catches
it, and it should be written *before* the callback.

**`swift-certificates` does not build on Linux.** [OQ-6](open-questions.md#oq-6).
If so, the fallback is generating the certificate with the platform's own
tooling and parsing only what is needed — but find out now, not in Phase 4.
