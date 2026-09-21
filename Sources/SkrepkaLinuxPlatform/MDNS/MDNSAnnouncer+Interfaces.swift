import Foundation
import Logging
import NIOCore

/// Which interfaces the announcer has a socket on, kept in step with the
/// machine's.
///
/// Read again every ``MDNSAnnouncer/interfacePollInterval`` rather than
/// followed through netlink: a poll is a `getifaddrs` call, and ten seconds is
/// well inside the time a user takes to open a peer list after joining Wi-Fi.
/// An interface that appears — or whose addresses change — gets a fresh socket
/// and is announced on (RFC 6762 §8.4: "if any of a host's IP addresses change,
/// it MUST re-announce those address records"); one that disappears is closed.
extension MDNSAnnouncer {
    /// Opens a socket on every current interface.
    ///
    /// Throws only when there were interfaces and **none** of them would open:
    /// that is the port being unshareable, which no later poll will fix. A
    /// single interface failing — a VPN tunnel without multicast, say — is
    /// logged and skipped.
    func openSockets() async throws {
        let interfaces = try MDNSInterface.current()
        var lastError: (any Error)?
        for interface in interfaces {
            do {
                try await open(interface)
            } catch {
                logger.notice(
                    "cannot answer mDNS on an interface",
                    metadata: ["interface": "\(interface.name)", "reason": "\(error)"])
                lastError = error
            }
        }
        if sockets.isEmpty, let lastError { throw lastError }
    }

    func startInterfaceWatch() {
        interfaceWatch?.cancel()
        interfaceWatch = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.interfacePollInterval)
                } catch {
                    return
                }
                await self?.refreshInterfaces()
            }
        }
    }

    func refreshInterfaces() async {
        let interfaces: [MDNSInterface]
        do {
            interfaces = try MDNSInterface.current()
        } catch {
            logger.notice("cannot list network interfaces", metadata: ["reason": "\(error)"])
            return
        }
        let wanted = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.index, $0) })
        for (index, socket) in sockets where wanted[index] != socket.interface {
            await close(index)
        }
        for interface in interfaces where sockets[interface.index] == nil {
            do {
                try await open(interface)
                if phase == .established { joinLink(interface.index) }
            } catch {
                // Retried at the next poll, so a notice rather than a warning.
                logger.notice(
                    "cannot answer mDNS on an interface",
                    metadata: ["interface": "\(interface.name)", "reason": "\(error)"])
            }
        }
    }

    private func open(_ interface: MDNSInterface) async throws {
        let socket = try await MDNSSocket.open(on: interface, group: eventLoops)
        sockets[interface.index] = socket
        readers[interface.index] = Task { [weak self] in
            for await packet in socket.packets {
                guard !Task.isCancelled else { return }
                await self?.receive(packet, on: interface.index)
            }
        }
        logger.info(
            "answering mDNS",
            metadata: ["interface": "\(interface.name)", "addresses": "\(interface.addresses)"])
    }

    private func close(_ index: Int) async {
        linkRounds[index]?.cancel()
        linkRounds[index] = nil
        readers[index]?.cancel()
        readers[index] = nil
        lastMulticast[index] = nil
        guard let socket = sockets.removeValue(forKey: index) else { return }
        await socket.close()
    }
}
