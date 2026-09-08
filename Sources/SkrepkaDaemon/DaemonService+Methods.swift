import DBUS
import Foundation
import SkrepkaIPC
import SkrepkaSync

extension DaemonService {
    /// The object this daemon exports, and every member on it.
    ///
    /// The `inputArgs`/`outputArgs` declared here are what
    /// `org.freedesktop.DBus.Introspectable.Introspect` answers with, so they
    /// are the machine-readable half of ``SkrepkaIPC/SkrepkaInterface`` — a
    /// `busctl introspect dev.soldunov.Skrepka /dev/soldunov/Skrepka` has to
    /// show the same signatures that type documents, or a client generated from
    /// introspection will not match one written by hand.
    func exportedObject() -> DBusObjectServer.ExportedObject {
        DBusObjectServer.ExportedObject(
            path: SkrepkaInterface.objectPath,
            interfaces: [
                DBusObjectServer.Interface(
                    name: SkrepkaInterface.name,
                    methods: readMethods() + clipboardMethods() + peerMethods()
                        + pairingWindowMethods() + pairingAnswerMethods(),
                    signals: [
                        DBusObjectServer.Signal(name: SkrepkaInterface.Signal.historyChanged),
                        DBusObjectServer.Signal(
                            name: SkrepkaInterface.Signal.pairingRequested,
                            args: [DBusObjectServer.MethodArg(name: "proposal", type: "s")]
                        ),
                    ]
                )
            ]
        )
    }

    private func readMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.interfaceVersion,
                outputArgs: [DBusObjectServer.MethodArg(name: "version", type: "u")]
            ) { _ in [.uint32(SkrepkaInterface.version)] },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.history,
                inputArgs: [DBusObjectServer.MethodArg(name: "limit", type: "u")],
                outputArgs: [DBusObjectServer.MethodArg(name: "history", type: "s")]
            ) { context in
                let limit = Self.uint32(context.arguments.first) ?? 0
                return [.string(try SkrepkaDocumentCoding.encode(await daemon.historyDocument(limit: limit)))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.peers,
                outputArgs: [DBusObjectServer.MethodArg(name: "peers", type: "s")]
            ) { _ in
                [.string(try SkrepkaDocumentCoding.encode(await daemon.peersDocument()))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.diagnostics,
                outputArgs: [DBusObjectServer.MethodArg(name: "diagnostics", type: "s")]
            ) { _ in
                [.string(try SkrepkaDocumentCoding.encode(await daemon.diagnosticsDocument()))]
            },
        ]
    }

    /// The two members that act on the clipboard: taking one entry out of the
    /// history, and putting one a client observed into it.
    private func clipboardMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.copy,
                inputArgs: [DBusObjectServer.MethodArg(name: "selector", type: "s")],
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { context in
                guard let raw = Self.string(context.arguments.first) else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.copy)
                }
                let result = await daemon.copy(ClipSelector(raw))
                return [.string(try SkrepkaDocumentCoding.encode(result))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.submit,
                inputArgs: [DBusObjectServer.MethodArg(name: "clip", type: "s")],
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { context in
                guard let json = Self.string(context.arguments.first) else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.submit)
                }
                let request = try SkrepkaDocumentCoding.decode(SubmitRequest.self, from: json)
                return [.string(try SkrepkaDocumentCoding.encode(await daemon.submit(request)))]
            },
        ]
    }

    /// The two members that act on paired peers.
    private func peerMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.syncNow,
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { _ in
                [.string(try SkrepkaDocumentCoding.encode(await daemon.syncNow()))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.unpair,
                inputArgs: [DBusObjectServer.MethodArg(name: "fingerprint", type: "s")],
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { context in
                guard let fingerprint = Self.string(context.arguments.first) else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.unpair)
                }
                let result = await daemon.unpair(fingerprint: fingerprint)
                return [.string(try SkrepkaDocumentCoding.encode(result))]
            },
        ]
    }

    /// Opening and closing the window in which this device will accept a dial
    /// from a peer it has never met.
    private func pairingWindowMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.openPairing,
                inputArgs: [DBusObjectServer.MethodArg(name: "seconds", type: "u")],
                outputArgs: [DBusObjectServer.MethodArg(name: "window", type: "s")]
            ) { context in
                let seconds = Self.uint32(context.arguments.first) ?? 0
                let duration: Duration =
                    seconds == 0 ? Daemon.defaultPairingWindow : .seconds(Int64(seconds))
                let window = try await daemon.openPairing(for: duration)
                return [.string(try SkrepkaDocumentCoding.encode(window))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.closePairing,
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { _ in
                await daemon.closePairing()
                return [.string(try SkrepkaDocumentCoding.encode(ActionDocument.succeeded()))]
            },
        ]
    }

    /// Starting a pairing, and answering one — the two halves a person stands
    /// between, comparing six words on two screens.
    private func pairingAnswerMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.pairWith,
                inputArgs: [DBusObjectServer.MethodArg(name: "fingerprint", type: "s")],
                outputArgs: [DBusObjectServer.MethodArg(name: "proposal", type: "s")]
            ) { context in
                guard let fingerprint = Self.string(context.arguments.first) else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.pairWith)
                }
                let proposal = try await daemon.pair(withFingerprint: fingerprint)
                return [.string(try SkrepkaDocumentCoding.encode(proposal))]
            },
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.confirmPairing,
                inputArgs: [
                    DBusObjectServer.MethodArg(name: "deviceId", type: "s"),
                    DBusObjectServer.MethodArg(name: "accept", type: "b"),
                ],
                outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
            ) { context in
                guard let hex = Self.string(context.arguments.first),
                    let deviceID = SyncDeviceID(hex: hex),
                    case .boolean(let accept)? = context.arguments.dropFirst().first
                else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.confirmPairing)
                }
                // The document comes from the daemon rather than being composed
                // here: refusing an outgoing proposal has to carry the
                // one-sided-trust warning, and only the daemon knows which
                // direction the waiting proposal ran in.
                let result = await daemon.answerPairing(deviceID: deviceID, accept: accept)
                return [.string(try SkrepkaDocumentCoding.encode(result))]
            },
        ]
    }

    // MARK: - Argument reading

    static func string(_ value: DBusValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        return text
    }

    /// A `u` argument, tolerating the narrower integers a hand-written client
    /// might send.
    ///
    /// `busctl call … u 20` sends a `uint32`, but a client that built the
    /// message itself may well send an `int32` for a number it thought of as a
    /// count. Accepting both costs two lines and turns a puzzling `InvalidArgs`
    /// into a working call; a negative value is refused rather than wrapped.
    static func uint32(_ value: DBusValue?) -> UInt32? {
        switch value {
        case .uint32(let number): number
        case .int32(let number) where number >= 0: UInt32(number)
        case .uint16(let number): UInt32(number)
        default: nil
        }
    }
}
