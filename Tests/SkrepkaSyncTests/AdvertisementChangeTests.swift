import Foundation
import Testing

@testable import SkrepkaSync

/// How much of a live advertisement has to change for it to describe a new
/// descriptor.
///
/// The case that matters is the one pairing exercises: opening the pairing
/// window adds `pair=` to the TXT record and closing it takes the key away
/// again, and neither touches the port or the instance name. Withdrawing the
/// registration for that takes the device off every peer's browse list and puts
/// it back — twice per pairing, while the user is looking at the other machine's
/// device list waiting for it to appear.
@Suite("Advertisement change")
struct AdvertisementChangeTests {
    private static func descriptor(
        name: String = "desktop",
        port: UInt16 = 7311,
        deviceID: SyncDeviceID = SyncFixtures.deviceA,
        platform: PeerPlatform = .macos,
        pairingPort: UInt16? = nil
    ) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: name,
            port: port,
            deviceID: deviceID,
            platform: platform,
            pairingPort: pairingPort
        )
    }

    @Test("An identical descriptor changes nothing at all")
    func identicalDescriptorIsUnchanged() {
        let published = Self.descriptor()
        #expect(
            AdvertisementChange.between(published: published, wanted: Self.descriptor())
                == .unchanged
        )
    }

    /// The pairing window, in both directions.
    @Test("Opening and closing the pairing window is a record change")
    func pairingWindowIsARecordChange() {
        let closed = Self.descriptor(pairingPort: nil)
        let open = Self.descriptor(pairingPort: 7312)
        #expect(AdvertisementChange.between(published: closed, wanted: open) == .record)
        #expect(AdvertisementChange.between(published: open, wanted: closed) == .record)
    }

    /// Everything else in the record is reachable the same way: `id=`, `plat=`
    /// and `proto=` are all TXT keys, so none of them needs the registration
    /// withdrawn.
    @Test("Any other record-only difference is a record change")
    func otherRecordDifferencesAreRecordChanges() {
        let published = Self.descriptor()
        #expect(
            AdvertisementChange.between(
                published: published,
                wanted: Self.descriptor(deviceID: SyncFixtures.deviceB)
            ) == .record
        )
        #expect(
            AdvertisementChange.between(
                published: published,
                wanted: Self.descriptor(platform: .linux)
            ) == .record
        )
    }

    /// The port is the SRV record and the display name is the DNS-SD service
    /// instance name — the first argument `DNSServiceRegister` takes. Neither is
    /// something `DNSServiceUpdateRecord` can reach, so both need the whole
    /// registration made again.
    @Test("A new port or a new name needs the registration made again")
    func srvDifferencesNeedARepublish() {
        let published = Self.descriptor()
        #expect(
            AdvertisementChange.between(published: published, wanted: Self.descriptor(port: 7400))
                == .republish
        )
        #expect(
            AdvertisementChange.between(
                published: published,
                wanted: Self.descriptor(name: "laptop")
            ) == .republish
        )
    }

    /// A port change that also changes the record is still a republish: the
    /// re-registration carries the new TXT record with it, so there is nothing
    /// left for an update to do.
    @Test("A republish wins over a record change when both apply")
    func republishWinsOverRecord() {
        #expect(
            AdvertisementChange.between(
                published: Self.descriptor(port: 7311, pairingPort: nil),
                wanted: Self.descriptor(port: 7400, pairingPort: 7312)
            ) == .republish
        )
    }
}
