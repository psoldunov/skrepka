import Foundation
import NIOCore

/// One network interface the announcer answers on, with the IPv4 addresses it
/// holds.
///
/// IPv4 only. RFC 6762 §6.2 asks for every address of the interface, and
/// IPv6 is left out on purpose rather than for want of a line: a link-local
/// IPv6 address is useless to a peer without the scope the SRV answer cannot
/// carry, and the sync listener is reached over IPv4 on every LAN this has to
/// work on. The host name's NSEC says so explicitly (RFC 6762 §6.1), so a
/// querier asking for AAAA is told "none" at once rather than timing out.
struct MDNSInterface: Sendable, Hashable {
    let index: Int
    let name: String
    /// Four bytes each, sorted so two readings of the same interface compare
    /// equal.
    let addresses: [[UInt8]]
    /// What `joinGroup(_:device:)` wants. Any device of this interface carries
    /// the index the membership is taken on.
    let device: NIONetworkDevice

    /// The interfaces worth answering on right now.
    static func current() throws -> [MDNSInterface] {
        grouped(try System.enumerateDevices())
    }

    /// Multicast-capable, IPv4, not loopback — grouped by interface, because
    /// `getifaddrs` lists one entry per address.
    static func grouped(_ devices: [NIONetworkDevice]) -> [MDNSInterface] {
        var byIndex: [Int: (device: NIONetworkDevice, addresses: [[UInt8]])] = [:]
        for device in devices where device.multicastSupported {
            guard let address = ipv4Bytes(device.address), address.first != 127 else { continue }
            let entry = byIndex[device.interfaceIndex] ?? (device, [])
            byIndex[device.interfaceIndex] = (entry.device, entry.addresses + [address])
        }
        return byIndex.map { index, entry in
            MDNSInterface(
                index: index,
                name: entry.device.name,
                addresses: entry.addresses.sorted { $0.lexicographicallyPrecedes($1) },
                device: entry.device
            )
        }
        .sorted { $0.index < $1.index }
    }

    static func ipv4Bytes(_ address: SocketAddress?) -> [UInt8]? {
        guard case .v4 = address, let text = address?.ipAddress else { return nil }
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}
