import DBUS
import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// The contract the Phase 8 GNOME Shell extension is written against.
///
/// `dev.soldunov.Skrepka1` promises that a member is added and never removed or
/// re-signatured, and `Introspect` answers with whatever `exportedObject()`
/// declares — so a member renamed here, or an argument type changed here, is a
/// silently broken client that ships through a review queue weeks later.
/// Nothing checked that. This does.
@Suite("Exported D-Bus interface")
struct DaemonServiceInterfaceTests {
    /// Every member, with the argument types ``SkrepkaIPC/SkrepkaInterface``'s
    /// own doc comments state. Transcribed from those comments deliberately: a
    /// table generated from the implementation would agree with it by
    /// construction and prove nothing.
    static let members: [String: (inputs: [String], outputs: [String])] = [
        SkrepkaInterface.Member.interfaceVersion: ([], ["u"]),
        SkrepkaInterface.Member.history: (["u"], ["s"]),
        SkrepkaInterface.Member.copy: (["s"], ["s"]),
        SkrepkaInterface.Member.submit: (["s"], ["s"]),
        SkrepkaInterface.Member.peers: ([], ["s"]),
        SkrepkaInterface.Member.diagnostics: ([], ["s"]),
        SkrepkaInterface.Member.openPairing: (["u"], ["s"]),
        SkrepkaInterface.Member.closePairing: ([], ["s"]),
        SkrepkaInterface.Member.pairWith: (["s"], ["s"]),
        SkrepkaInterface.Member.confirmPairing: (["s", "b"], ["s"]),
        SkrepkaInterface.Member.unpair: (["s"], ["s"]),
        SkrepkaInterface.Member.syncNow: ([], ["s"]),
    ]

    static func service() throws -> DaemonService {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-interface-\(UUID().uuidString)", directoryHint: .isDirectory)
        // A session pointed at a socket nothing is listening on, on any
        // machine. Nothing here connects to it — every test below reads
        // `exportedObject()`, which builds the method table and touches no bus
        // — and the dead address is what keeps that true if one ever does.
        return DaemonService(
            daemon: try Daemon(options: options, environment: [:]),
            session: BusSession(bus: .session, address: BusNameClaimTests.deadAddress)
        )
    }

    static func interface() async throws -> DBusObjectServer.Interface {
        let service = try Self.service()
        let object = await service.exportedObject()
        #expect(object.path == SkrepkaInterface.objectPath)
        let interface = try #require(object.interfaces.first)
        #expect(interface.name == SkrepkaInterface.name)
        return interface
    }

    @Test("every member the interface documents is exported, and nothing else")
    func exportsExactlyTheDocumentedMembers() async throws {
        let exported = Set(try await Self.interface().methods.map(\.name))
        #expect(exported == Set(Self.members.keys))
    }

    @Test("every member carries the argument types the interface documents")
    func exportsTheDocumentedSignatures() async throws {
        for method in try await Self.interface().methods {
            let expected = try #require(Self.members[method.name], "\(method.name) is undocumented")
            #expect(method.inputArgs.map(\.type) == expected.inputs, "\(method.name) inputs")
            #expect(method.outputArgs.map(\.type) == expected.outputs, "\(method.name) outputs")
            // An unnamed argument introspects as one, and a generated client
            // names its parameters from these.
            #expect(method.inputArgs.allSatisfy { !$0.name.isEmpty }, "\(method.name) input names")
            #expect(method.outputArgs.allSatisfy { !$0.name.isEmpty }, "\(method.name) output names")
        }
    }

    @Test("both signals are exported, with the payloads they document")
    func exportsBothSignals() async throws {
        let signals = try await Self.interface().signals
        let byName = Dictionary(signals.map { ($0.name, $0) }) { first, _ in first }
        #expect(
            Set(byName.keys) == [
                SkrepkaInterface.Signal.historyChanged,
                SkrepkaInterface.Signal.pairingRequested,
            ])
        #expect(byName[SkrepkaInterface.Signal.historyChanged]?.args.isEmpty == true)
        #expect(byName[SkrepkaInterface.Signal.pairingRequested]?.args.map(\.type) == ["s"])
    }
}

/// The two readers every method's arguments go through.
///
/// Both are documented as tolerating more than the strict type — and neither
/// was tested, which is the shape of thing that quietly stops being true.
@Suite("D-Bus argument reading")
struct DaemonServiceArgumentTests {
    @Test("a uint32 argument accepts the narrower integers a hand-written client sends")
    func uint32AcceptsWhatItDocuments() {
        #expect(DaemonService.uint32(.uint32(20)) == 20)
        #expect(DaemonService.uint32(.int32(20)) == 20)
        #expect(DaemonService.uint32(.uint16(20)) == 20)
        #expect(DaemonService.uint32(.uint32(.max)) == UInt32.max)
    }

    @Test("a negative int32 is refused rather than wrapped")
    func uint32RefusesANegative() {
        // Wrapping would turn `-1` into 4294967295 — a history limit of four
        // billion, or a pairing window of a hundred and thirty years.
        #expect(DaemonService.uint32(.int32(-1)) == nil)
        #expect(DaemonService.uint32(.int32(.min)) == nil)
    }

    @Test("anything else is refused")
    func uint32RefusesEverythingElse() {
        #expect(DaemonService.uint32(.string("20")) == nil)
        #expect(DaemonService.uint32(.boolean(true)) == nil)
        #expect(DaemonService.uint32(.uint64(20)) == nil)
        #expect(DaemonService.uint32(nil) == nil)
    }

    @Test("a string argument is read only from a string")
    func stringReadsOnlyStrings() {
        #expect(DaemonService.string(.string("hello")) == "hello")
        // Non-nil *and* empty: an empty string argument is a value the caller
        // sent, not an absent one, and the two must not collapse together.
        #expect(DaemonService.string(.string(""))?.isEmpty == true)
        #expect(DaemonService.string(.uint32(1)) == nil)
        #expect(DaemonService.string(nil) == nil)
    }
}
