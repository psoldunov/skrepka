import DBUS
import Foundation
import SkrepkaIPC

extension DaemonService {
    /// The version-3 picker surface. Each handler checks the whole body because
    /// DBusObjectServer passes through surplus arguments instead of rejecting them.
    func pickerMethods() -> [DBusObjectServer.Method] {
        [searchMethod(), copyAsMethod(), setPinnedMethod(), deleteMethod(), clearMethod(), previewMethod()]
    }

    private func searchMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.search,
            inputArgs: [
                DBusObjectServer.MethodArg(name: "query", type: "s"),
                DBusObjectServer.MethodArg(name: "limit", type: "u"),
            ],
            outputArgs: [DBusObjectServer.MethodArg(name: "history", type: "s")]
        ) { context in
            guard context.arguments.count == 2,
                let query = Self.string(context.arguments.first),
                let limit = Self.uint32(context.arguments.last)
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.search) }
            return [
                .string(
                    try SkrepkaDocumentCoding.encode(await daemon.searchDocument(query: query, limit: limit)))
            ]
        }
    }

    private func copyAsMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.copyAs,
            inputArgs: [
                DBusObjectServer.MethodArg(name: "selector", type: "s"),
                DBusObjectServer.MethodArg(name: "style", type: "s"),
            ],
            outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
        ) { context in
            guard context.arguments.count == 2,
                let selector = Self.string(context.arguments.first),
                let style = Self.string(context.arguments.last),
                CopyStyle(wireValue: style) != nil
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.copyAs) }
            return [
                .string(
                    try SkrepkaDocumentCoding.encode(
                        await daemon.copyAs(ClipSelector(selector), style: style)))
            ]
        }
    }

    private func setPinnedMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.setPinned,
            inputArgs: [
                DBusObjectServer.MethodArg(name: "selector", type: "s"),
                DBusObjectServer.MethodArg(name: "pinned", type: "b"),
            ],
            outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
        ) { context in
            guard context.arguments.count == 2,
                let selector = Self.string(context.arguments.first),
                case .boolean(let pinned)? = context.arguments.last
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.setPinned) }
            return [
                .string(
                    try SkrepkaDocumentCoding.encode(
                        await daemon.setPinned(ClipSelector(selector), pinned: pinned)))
            ]
        }
    }

    private func deleteMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.delete,
            inputArgs: [DBusObjectServer.MethodArg(name: "selector", type: "s")],
            outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
        ) { context in
            guard context.arguments.count == 1, let selector = Self.string(context.arguments.first)
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.delete) }
            return [.string(try SkrepkaDocumentCoding.encode(await daemon.delete(ClipSelector(selector))))]
        }
    }

    private func clearMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.clear,
            inputArgs: [DBusObjectServer.MethodArg(name: "keepPinned", type: "b")],
            outputArgs: [DBusObjectServer.MethodArg(name: "result", type: "s")]
        ) { context in
            guard context.arguments.count == 1, case .boolean(let keepPinned)? = context.arguments.first
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.clear) }
            return [.string(try SkrepkaDocumentCoding.encode(await daemon.clear(keepingPinned: keepPinned)))]
        }
    }

    private func previewMethod() -> DBusObjectServer.Method {
        let daemon = daemonReference
        return DBusObjectServer.Method(
            name: SkrepkaInterface.Member.preview,
            inputArgs: [
                DBusObjectServer.MethodArg(name: "selector", type: "s"),
                DBusObjectServer.MethodArg(name: "maxBytes", type: "u"),
            ],
            outputArgs: [DBusObjectServer.MethodArg(name: "preview", type: "s")]
        ) { context in
            guard context.arguments.count == 2,
                let selector = Self.string(context.arguments.first),
                let maxBytes = Self.uint32(context.arguments.last)
            else { throw ServiceError.badArguments(SkrepkaInterface.Member.preview) }
            return [
                .string(
                    try SkrepkaDocumentCoding.encode(
                        await daemon.preview(ClipSelector(selector), maxBytes: maxBytes)))
            ]
        }
    }
}
