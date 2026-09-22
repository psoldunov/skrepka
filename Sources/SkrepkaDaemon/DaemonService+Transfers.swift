import DBUS
import Foundation
import SkrepkaIPC

extension DaemonService {
    /// The version-5 transfers member. The signal that follows it is pumped by
    /// `startSignalPumps(on:)`.
    func transferMethods() -> [DBusObjectServer.Method] {
        let daemon = daemonReference
        return [
            DBusObjectServer.Method(
                name: SkrepkaInterface.Member.transfers,
                outputArgs: [DBusObjectServer.MethodArg(name: "transfers", type: "s")]
            ) { context in
                guard context.arguments.isEmpty else {
                    throw ServiceError.badArguments(SkrepkaInterface.Member.transfers)
                }
                return [.string(try SkrepkaDocumentCoding.encode(await daemon.transfersDocument()))]
            }
        ]
    }
}
