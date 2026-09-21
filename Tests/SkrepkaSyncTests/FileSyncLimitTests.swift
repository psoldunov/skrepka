import Foundation
import Testing

@testable import SkrepkaSync

/// The "sync files up to" limit, and the filter that applies it where history
/// leaves a device.
@Suite("The file-size limit")
struct FileSyncLimitTests {
    private static let fileHash = String(repeating: "a", count: 64)

    @Test("Out-of-range limits are clamped into zero through the ceiling")
    func clamping() {
        #expect(FileSyncLimit.clamped(-1) == 0)
        #expect(FileSyncLimit.clamped(FileSyncLimit.ceiling + 1) == FileSyncLimit.ceiling)
        #expect(FileSyncLimit.clamped(5 * FileSyncLimit.megabyte) == 5 * FileSyncLimit.megabyte)
    }

    @Test("A limit of zero admits nothing, not even an empty bundle")
    func zeroAdmitsNothing() {
        #expect(!FileSyncLimit.admits(0, under: 0))
        #expect(FileSyncLimit.admits(10, under: 10))
        #expect(!FileSyncLimit.admits(11, under: 10))
    }

    @Test("Only a bundle is ever measured against the limit")
    func onlyBundlesAreMeasured() {
        let bundle = RepresentationDescriptor(key: FileBundle.key, byteCount: 2_000)
        let path = RepresentationDescriptor(key: FileSyncFixtures.fileURLKey, byteCount: 2_000)
        #expect(!FileSyncLimit.admits(bundle, under: 1_000))
        #expect(FileSyncLimit.admits(bundle, under: 2_000))
        #expect(FileSyncLimit.admits(path, under: 0))
    }

    @Test("The choices run from off to the ceiling, smallest first, and the default is the ceiling")
    func choices() {
        #expect(FileSyncLimit.choices.first == 0)
        #expect(FileSyncLimit.choices.last == FileSyncLimit.ceiling)
        #expect(FileSyncLimit.choices == FileSyncLimit.choices.sorted())
        #expect(FileSyncLimit.defaultBytes == FileSyncLimit.ceiling)
        #expect(FileSyncLimit.ceiling == SyncLimits.maximumPayloadBytes)
    }

    @Test("A policy clamps what it is given")
    func policyClamps() async {
        let policy = FileSyncPolicy(maximumBytes: -5)
        #expect(await policy.maximumBytes == 0)
        await policy.setMaximumBytes(.max)
        #expect(await policy.maximumBytes == FileSyncLimit.ceiling)
    }

    @Test("A capable peer is not offered a bundle over this device's own limit")
    func filterWithholdsOverLimit() throws {
        let bundle = try FileSyncFixtures.bundle(byteCount: 4_096)
        let item = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: SyncFixtures.deviceA, at: SyncFixtures.epoch)
        let capable = CapabilityFilter(capabilities: SyncCapability.local)

        let small = capable.limitingFiles(to: 1_024)
        #expect(small.meta(item.meta).representations.map(\.key) == [FileSyncFixtures.fileURLKey])
        #expect(small.payloads(item.payloads).keys.sorted() == [FileSyncFixtures.fileURLKey])
        #expect(!small.offers(FileBundle.key, byteCount: bundle.count))
        #expect(small.offers(FileSyncFixtures.fileURLKey, byteCount: 1 << 20))

        let roomy = capable.limitingFiles(to: bundle.count)
        #expect(roomy.meta(item.meta) == item.meta)
        #expect(roomy.payloads(item.payloads) == item.payloads)
    }

    @Test("Off withholds every bundle, however small")
    func offWithholdsEverything() throws {
        let bundle = try FileSyncFixtures.bundle(byteCount: 1)
        let item = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: SyncFixtures.deviceA, at: SyncFixtures.epoch)
        let off = CapabilityFilter(capabilities: SyncCapability.local).limitingFiles(to: 0)
        #expect(!off.meta(item.meta).representations.contains { $0.key == FileBundle.key })
    }
}
