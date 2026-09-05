# Phase 1 — `SkrepkaSync`, the portable protocol core

**Two to three days. Nothing here touches a network, a pasteboard or a
database.**

## Goal

A new target holding the sync model, the wire codec and the merge engine —
pure, synchronous, fully tested, and compiling on Linux on the day it is
created.

## Preconditions

- **A Linux toolchain in the loop.** Not optional, and the design document
  understates it: "must compile on Linux from day one" is unverifiable without
  a Linux box. A `swift:6.x` container is enough, and
  **OrbStack on the development machine already provides one** — see
  [the Linux environment](README.md#the-linux-environment). Establish it now, in
  the cheapest phase, rather than discovering the toolchain gap in Phase 4.
- Phase 0 need not be finished. Nothing here depends on its answer.

## Deliverables

```
Sources/SkrepkaSync/
  Model/
    SyncDeviceID.swift
    PeerPlatform.swift
    LWWRegister.swift
    RepresentationKey.swift
    RepresentationKeyMap.swift
    SyncClipMeta.swift
    Tombstone.swift
    SyncLimits.swift
  Wire/
    ProtocolVersion.swift
    SyncMessageType.swift
    Frame.swift
    FrameCodec.swift
    FrameError.swift
    SyncMessage.swift
    WireTimestamp.swift
  Merge/
    MergeEngine.swift
    MergeAction.swift

Tests/SkrepkaSyncTests/
  FrameCodecTests.swift
  MergeEngineTests.swift
  LWWRegisterTests.swift
  RepresentationKeyTests.swift
  PeerPlatformTests.swift

Tests/SkrepkaCoreTests/
  SyncLimitsTests.swift          # the only file that links both targets
```

Plus edits to `Package.swift`.

## Work

### 1. Add the target

`Package.swift` gains `SkrepkaSync` on `sharedSwiftSettings` — **not**
`appSwiftSettings`, because this target must not default to the main actor.
Dependencies: `apple/swift-crypto` and `valpackett/SwiftCBOR`. `swift-nio` and
`swift-nio-ssl` arrive in Phase 2; adding them now buys nothing and slows every
resolve.

Two things to check the moment the target exists, both of which are cheap now
and expensive later:

- `swift build --target SkrepkaSync` succeeds inside the Linux container. Note
  the `--target`: a bare `swift build` on Linux tries to build the `Skrepka`
  app target and its macOS-only `KeyboardShortcuts` dependency, and fails. That
  is expected and is not a problem to solve until Phase 4.
- `SkrepkaSync` does not depend on `SkrepkaCore`. It cannot: `SkrepkaCore` does
  not build on Linux until Phase 4, and this target has to build there today.
  Everything `SkrepkaSync` needs from the core is copied as a primitive —
  `kind` travels as a `String`, not as a `ClipKind` — and Phase 4 is where the
  two are allowed to meet.

### 2. `Model/`

Sketches, not specifications. Types are `struct` with `let` properties per the
repo's immutability rule, `Sendable` and `Codable`.

**`SyncDeviceID`** — and a deliberate deviation from design §9, which describes
*two* identifiers for one device: a UUID in `id=` and a certificate fingerprint
in `fp=`. Two identities for one device means an attacker gets to pick which one
you check. Syncthing's answer is the right one: make the device ID *be* the
certificate hash, so the two cannot disagree.

```swift
/// Stable identity of one device: lowercase hex of SHA-256 over its
/// certificate's DER encoding.
///
/// Derived rather than random on purpose. A separate random id would be a
/// second identity for the same device, and two identities that can disagree
/// are an authentication hole rather than a redundancy.
public struct SyncDeviceID: Sendable, Hashable, Codable, CustomStringConvertible
```

The TXT record's `fp=` then becomes a *prefix* of `id=` rather than a second
field, and design §9's record loses one key. Say so in the commit; the design
document is the thing being corrected.

**`PeerPlatform`** — `macos`, `linux`, `unknown`, and the one rule that makes
design §3 enforceable rather than aspirational:

```swift
/// Whether live clipboard push should default on between these two platforms.
///
/// Never between two Apple devices — Universal Clipboard already does that,
/// and two systems owning one pasteboard race non-deterministically. Live push
/// exists to bridge the gap Apple leaves.
public static func livePushDefaultsOn(local: PeerPlatform, remote: PeerPlatform) -> Bool
```

`unknown` defaults live push **off**. An unrecognised platform is more likely a
future Apple device than a future Linux one, and the failure mode of guessing
wrong in that direction is a feature that has to be switched on rather than a
collision the user cannot diagnose.

**`LWWRegister<Value>`** — `(value, timestamp, deviceID)` with a `merged(with:)`
that is commutative and associative. Timestamp wins; `SyncDeviceID` breaks a
tie by lexicographic order. Both properties are asserted by test, because a
merge that is not commutative converges to whichever side spoke last, which is
the bug this whole model exists to avoid.

**`RepresentationKey`** — canonical IANA media type on the wire, with the
originating platform's own key carried alongside as opaque passthrough:

```swift
public struct RepresentationKey: Sendable, Hashable, Codable {
    /// IANA media type. The vocabulary a GTK app and a JavaScript extension
    /// can both speak.
    public let canonical: String
    /// The originating platform's own key — a macOS UTI, a Linux MIME target.
    /// Carried so a Mac↔Mac round trip is lossless; ignored by anyone else.
    public let origin: String?
}
```

**`RepresentationKeyMap`** — the table in design §8, in one place. macOS UTI ↔
canonical, and the Linux direction, with the lossy cases named rather than
silently dropped. `com.apple.flat-rtfd` maps to nothing and the map says so;
flattening it to HTML + PNG is Phase 3's job, not the map's.

**`SyncClipMeta`** — a few hundred bytes, per design §7: `contentHash`, `kind`
as a raw string, a preview capped by `SyncLimits.previewByteLimit`, `createdAt`,
an `LWWRegister<Bool>` for the pin, `isConcealed`, image dimensions,
`sourceBundleID`, `originDeviceID`, and a list of
`RepresentationDescriptor { key, byteCount }`. No payload bytes.

**`Tombstone`** — `{contentHash, deletedAt, deviceID}`.

**`SyncLimits`** — the numbers, so no call site invents one:

```swift
public enum SyncLimits {
    /// Largest payload that may cross the wire, in bytes.
    ///
    /// The same number as `CaptureRules.maximumItemBytes`: an item too large to
    /// capture is too large to receive, and two limits that can drift is one
    /// limit and one bug.
    public static let maximumPayloadBytes = 32 * 1024 * 1024
    public static let maximumFrameBodyBytes = maximumPayloadBytes + 64 * 1024
    public static let payloadChunkBytes = 256 * 1024
    public static let livePushInlineLimit = 256 * 1024
    public static let previewByteLimit = 4 * 1024
    public static let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 90
}
```

`SkrepkaSync` cannot import `SkrepkaCore` to derive that first number, so it
restates it — and `Tests/SkrepkaCoreTests/SyncLimitsTests.swift` links both
targets and fails if the two ever disagree. That test is the whole reason the
duplication is acceptable.

Add `public static let defaultMaximumItemBytes = 32 * 1024 * 1024` to
`CaptureRules` so the test has something to compare against;
`Sources/SkrepkaCore/Clipboard/CaptureRules.swift:14` currently spells the
number inline in the initialiser default.

### 3. `Wire/`

**Framing** is `[u32 big-endian length][u8 message type][CBOR body]`, per design
§7, with `length` covering the type byte and the body.

**`FrameCodec`** is the only place CBOR is named. Everything above it speaks
`SyncMessage`, everything below it speaks `Data`. That isolation is not
fastidiousness — [OQ-8](open-questions.md#oq-8) asks whether `SwiftCBOR` is
mature enough and how it behaves on malformed input, and if the answer is bad,
this is the one file that changes.

```swift
/// Decodes what it can from `buffer`, consuming the bytes it used.
/// Returns nil when the buffer holds less than one whole frame.
public static func decode(from buffer: inout Data) throws -> Frame?
```

Streaming-shaped from the start. A codec that assumes whole frames arrive
whole is a codec that works on loopback and fails on a real TCP connection.

**`WireTimestamp`** — every time on the wire is `Int64` milliseconds since the
Unix epoch, converted at the codec boundary. Not `Date`'s `Codable`
representation, which is a `Double` of seconds since 2001, and not a CBOR tag-1
value, whose handling in `SwiftCBOR` is part of OQ-8. An integer millisecond
count is unambiguous in every language that has to read this, including the
JavaScript in Phase 8.

**Rejection is explicit.** `FrameError` distinguishes `bodyTooLarge`,
`unknownMessageType` and `truncated`, because a peer speaking a newer protocol
version sends message types this build has never heard of, and dropping that
frame is correct while dropping the connection is not.

### 4. `Merge/`

`MergeEngine.plan(_:) -> [MergeAction]` — pure, synchronous, no clock, no
storage. The same shape as `CaptureRules.decide` and
`RetentionPolicy.idsToEvict`, which is exactly why those two are testable today.

```swift
public enum MergeAction: Sendable, Hashable {
    case insert(SyncClipMeta)
    case bumpCreatedAt(contentHash: String, to: Date)
    case applyPin(contentHash: String, register: LWWRegister<Bool>)
    case deleteLocally(contentHash: String)
    case recordTombstone(Tombstone)
}
```

No `fetchPayload` case. Payload transfer is lazy and demand-driven per design
§7, so it is the transport's business and not the merge's — putting it here
would make a pure function decide when to spend bandwidth.

Three rules the engine encodes, and each gets its own test:

1. **Identity is `contentHash`, never `id`.** Two machines copying the same
   string must converge, and a locally generated `UUID` cannot.
   `HistoryStore.recordMatching(contentHash:)` already exists for the lookup.
2. **A tombstone beats an insert**, regardless of arrival order, until it
   expires.
3. **Retention is not deletion.** The engine never emits `recordTombstone` for
   an item that is merely absent locally. Absence means "evicted here", and
   re-learning an evicted clip from a peer is correct behaviour — the local cap
   simply re-evicts it. This is the single most important line in the model:
   conflating the two verbs is how a sync feature quietly destroys history.

## Tests

| Test | Asserts |
|---|---|
| `FrameCodecTests.roundTripsEveryMessageType` | every `SyncMessageType` encodes and decodes to an equal value |
| `FrameCodecTests.rejectsOversizedBody` | a body one byte over `maximumFrameBodyBytes` throws `bodyTooLarge` and does not allocate it |
| `FrameCodecTests.returnsNilOnPartialFrame` | a buffer holding half a frame yields nil and consumes nothing |
| `FrameCodecTests.decodesTwoFramesFromOneBuffer` | the streaming case, which loopback would otherwise hide |
| `FrameCodecTests.rejectsUnknownMessageType` | throws `unknownMessageType`, not a crash and not silence |
| `FrameCodecTests.survivesMalformedBody` | truncated and corrupted CBOR bodies throw rather than trap — this is [OQ-8](open-questions.md#oq-8) turned into a regression test |
| `MergeEngineTests.convergesRegardlessOfOrder` | two divergent histories applied in both orders produce identical results |
| `MergeEngineTests.tombstoneBeatsInsert` | in both arrival orders |
| `MergeEngineTests.evictionEmitsNoTombstone` | an item absent locally but present remotely is re-inserted, never tombstoned |
| `MergeEngineTests.createdAtTakesTheMaximum` | commutative under clock skew in either direction |
| `LWWRegisterTests.mergeIsCommutativeAndAssociative` | over generated triples, including equal timestamps |
| `LWWRegisterTests.deviceIDBreaksTies` | deterministically, and the same way on both peers |
| `RepresentationKeyTests.utiRoundTripsThroughCanonical` | every entry in the map, both directions |
| `RepresentationKeyTests.rtfdHasNoCanonicalForm` | the lossy case is explicit, not a silent nil |
| `PeerPlatformTests.livePushDefaultsOffBetweenApplePeers` | and on for macOS↔Linux, and off for `unknown` |
| `SyncLimitsTests.matchesCaptureRules` | the cross-target drift guard |

Concealed content never reaching the wire is enforced at the storage boundary
in Phase 2, not here — `SkrepkaSync` never sees a payload it was not handed.
The test for it belongs where the decision is made.

## Done when

- `swift build --target SkrepkaSync` is green on macOS **and** inside the Linux
  container.
- `swift test --filter SkrepkaSyncTests` is green on both.
- `scripts/doctor.sh` is green.
- Not one line of networking exists.

## Risks

**`SwiftCBOR` turns out to be unsuitable.** [OQ-8](open-questions.md#oq-8).
Contained by design — `FrameCodec` is the only file that names it, and the
malformed-input tests are written before anything depends on the answer. The
fallback is a hand-rolled subset of CBOR covering the handful of types this
protocol uses, which is a day of work and not a crisis.

**The merge model turns out to need more than a grow-only set.** Unlikely:
`ClipItem` is immutable except for `isPinned`, `createdAt` and deletion, which
is exactly a grow-only set plus two LWW registers. If a mutable field is added
to `ClipItem` later, this is the phase whose assumptions it breaks — put a note
in `MergeEngine`'s doc comment saying so.

**`Observation` on Linux.** Not a risk here — nothing in this target uses it.
It becomes [OQ-11](open-questions.md#oq-11) in Phase 4.
