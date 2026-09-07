import Foundation
import SkrepkaCore
import SkrepkaLinuxPlatform

#if canImport(Glibc)
    import Glibc
#endif

/// The headless proof for Phase 5.
///
/// Speaks the whole clipboard backend and touches no history store, no window
/// and no GUI — the Linux counterpart of `skrepka-sync-probe`, and the binary
/// Phase 5's "done when" is written against. What it demonstrates is the
/// capture path end to end: the probe picks a backend, the real
/// `ClipboardWatcher` and `CaptureRules` decide what each change is, and the
/// decision is printed.
///
/// Deliberately not a daemon. Reconnection *policy* — how long to wait, how
/// many times, whether to give up — belongs to the Phase 6 daemon; what lives
/// here is the smallest loop that satisfies "survives the compositor restarting
/// under it", so that the claim can be tested before the daemon exists.
@main
enum ClipProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "report", .none:
            await report()
        case "watch":
            await watch()
        case "copy":
            await copy(text: arguments.dropFirst().joined(separator: " "))
        case "help", "--help", "-h":
            usage()
        case let other:
            print("unknown command: \(other ?? "")")
            usage()
            exit(2)
        }
    }

    private static func usage() {
        print(
            """
            skrepka-clip-probe — the headless Linux clipboard backend

              report            what this session offers, and which backend it implies
              watch             log every clipboard change until interrupted
              copy <text>       own the selection and serve <text> until something else takes it

            With no command, reports.
            """
        )
    }

    // MARK: - report

    private static func report() async {
        let report = SessionProbe().run()
        print("session")
        print("  desktop:  \(report.desktop ?? "—")")
        print("  wayland:  \(report.waylandDisplay ?? "—")")
        print("  x11:      \(report.x11Display ?? "—")")
        print("  backend:  \(report.backend?.displayName ?? "none")")
        if report.isXWaylandFallback {
            print("  note:     X11 under Wayland — only XWayland clients' copies are visible")
        }
        if let problem = report.problem {
            print("  \(problem.isBlocking ? "problem" : "note"):  \(problem.reportLine)")
        }
        print(
            "  globals:  \(report.waylandGlobals.isEmpty ? "—" : report.waylandGlobals.joined(separator: ", "))"
        )
    }

    // MARK: - watch

    private static func watch() async {
        await report()
        while true {
            do {
                let running = try await ClipboardBackend.start()
                print("\nwatching through \(running.report.backend?.displayName ?? "?")")
                await follow(running)
                // `follow` returns only when the backend stopped, which on a
                // healthy session does not happen.
                print("backend stopped; reconnecting in 1s")
            } catch ClipboardBackend.StartError.unsupportedSession(let report) {
                // Not something waiting fixes. A compositor does not grow a
                // data-control global while the process sleeps.
                print("cannot watch this session: \(report.problem?.reportLine ?? "no backend")")
                exit(1)
            } catch {
                print("could not start: \(error); retrying in 1s")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Runs the real capture pipeline over the backend and prints each decision.
    private static func follow(_ running: ClipboardBackend.Running) async {
        let watcher = ClipboardWatcher(source: running.source)
        let decisions = await watcher.start()
        for await decision in decisions {
            print(describe(decision))
        }
        await running.stop()
    }

    private static func describe(_ decision: CaptureDecision) -> String {
        guard case .captured(let item) = decision else {
            return "· \(decision.rejectionLogMessage ?? "no decision")"
        }
        let types = item.payload.representations.keys.sorted().joined(separator: ", ")
        let preview = item.text
            .replacingOccurrences(of: "\n", with: "⏎")
            .prefix(60)
        return """
            ✓ \(item.kind.rawValue)\(item.isConcealed ? " (concealed)" : "") \
            \(item.payload.byteCount)B [\(types)] \(preview)
            """
    }

    // MARK: - copy

    private static func copy(text: String) async {
        guard !text.isEmpty else {
            print("copy needs something to put on the clipboard")
            exit(2)
        }
        do {
            let running = try await ClipboardBackend.start()
            var payload: [String: Data] = [:]
            for target in LinuxRepresentationMap.targets(forPasteboardType: PasteboardType.string) {
                payload[target] = Data(text.utf8)
            }
            await running.setSelection(payload)
            print("serving \(payload.count) targets — ^C to release the selection")
            // Both platforms' clipboards are ownership rather than storage: the
            // bytes live in this process and are served on request, so exiting
            // is what takes them off the clipboard.
            while true { try await Task.sleep(for: .seconds(3600)) }
        } catch {
            print("could not start: \(error)")
            exit(1)
        }
    }
}
