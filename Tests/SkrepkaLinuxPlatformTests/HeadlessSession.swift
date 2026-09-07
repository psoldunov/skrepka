import Foundation
import Synchronization

@testable import SkrepkaLinuxPlatform

#if canImport(Glibc)
    import Glibc
#endif

/// A real compositor or X server, started for the duration of a test.
///
/// The phase plan called a nested headless compositor "worth trying", and said
/// that if it worked it would be "the difference between a backend that is
/// tested and one that is merely demonstrated". It works, on both halves:
///
/// - **Sway** runs against `WLR_BACKENDS=headless` with no DRM device and no
///   display, and advertises `zwlr_data_control_manager_v1` version 2. So the
///   Wayland backend is exercised against a real compositor.
/// - **Xvfb** is a real X server carrying the XFIXES extension, so the X11
///   backend gets real `XFixesSelectionNotify` events.
///
/// What neither gives is `ext_data_control_manager_v1`: Sway 1.9 is wlroots
/// 0.17, which predates it. That reader is covered by unit tests and by being
/// the same engine, and stays unverified against a live compositor here.
///
/// It changes nothing about this process. The display it started is handed to
/// the backend as an explicit name and to the outside tools in their own
/// environment, so two of these can exist at once without agreeing on
/// `WAYLAND_DISPLAY` or `DISPLAY` — which is what the two integration suites
/// do, and what made them fail each other when this used `setenv`.
final class HeadlessSession {
    enum Kind {
        case sway
        case xvfb
    }

    /// The outside tools a session of this kind cannot run without.
    static func requiredTools(_ kind: Kind) -> [String] {
        switch kind {
        case .sway: ["sway", "wl-copy", "wl-paste"]
        case .xvfb: ["Xvfb", "xclip"]
        }
    }

    /// Which of them are not on `PATH`.
    ///
    /// Named rather than counted, because this is what
    /// ``HeadlessToolRequirementTests`` puts in its failure message: "sway is
    /// missing" is diagnosable and "the tools are missing" is not.
    static func missingTools(_ kind: Kind) -> [String] {
        requiredTools(kind).filter { which($0) == nil }
    }

    /// Whether the tools this needs are installed.
    ///
    /// `docker/Dockerfile.linux` carries them, so the containerised gate always
    /// has them. A native Linux checkout might not, and a missing compositor
    /// should skip these tests rather than fail them — the unit tests still
    /// cover the pure half. ``HeadlessToolRequirementTests`` is what stops that
    /// skip from being silent where the tools are supposed to be there.
    static func isAvailable(_ kind: Kind) -> Bool {
        missingTools(kind).isEmpty
    }

    private let kind: Kind
    private var process: Subprocess?
    private let runtimeDirectory: URL
    /// What the outside tools are run with. They read `WAYLAND_DISPLAY` and
    /// `DISPLAY` and have no way to be told otherwise.
    var childEnvironment: [String: String] = [:]

    /// The absolute socket path, which is what makes the backend need no
    /// `XDG_RUNTIME_DIR`: libwayland's `connect_to_socket` uses an absolute
    /// name as-is.
    private(set) var waylandSocketPath: String?
    private(set) var x11Display: String?

    /// Waits for the compositor's socket, giving up early if it has died.
    ///
    /// The deadline is generous because the whole suite runs in parallel and a
    /// loaded container takes noticeably longer to bring a compositor up — a
    /// 10-second window was enough alone and not enough under 481 tests. What
    /// stops that generosity costing a slow failure is the liveness check:
    /// a compositor that exited is reported at once, with what it said.
    private func waitForSocket(
        named prefix: String,
        startedBy process: Subprocess,
        log: URL
    ) -> String? {
        var found: String?
        _ = waitUntil(timeout: .seconds(30)) {
            if process.status() != nil { return true }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDirectory.path))
            found = names?.first { $0.hasPrefix(prefix) && !$0.hasSuffix(".lock") }
            return found != nil
        }
        return found
    }

    /// The last few lines of a child's standard error, for a failure message.
    static func tail(of log: URL, lines: Int = 6) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else {
            return "(no log)"
        }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// The environment ``SkrepkaLinuxPlatform/SessionProbe`` should be run
    /// with, so a probe test exercises this session and not the machine's.
    var probeEnvironment: [String: String] {
        var environment: [String: String] = [:]
        if let waylandSocketPath { environment["WAYLAND_DISPLAY"] = waylandSocketPath }
        if let x11Display { environment["DISPLAY"] = x11Display }
        environment["XDG_CURRENT_DESKTOP"] = kind == .sway ? "sway" : "x11"
        return environment
    }

    init(_ kind: Kind, label: String) throws {
        self.kind = kind
        // Per-instance, because two suites running back to back must not find
        // each other's sockets — and because a leftover one from a crashed run
        // would make a compositor that never started look like one that did.
        //
        // The serial number is what makes it per-instance rather than per
        // label. Labels repeat across suites, suites run concurrently, and
        // `stop()` deletes this directory — see ``nextSessionNumber()``.
        let serial = Self.nextSessionNumber()
        runtimeDirectory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("skrepka-headless-\(label)-\(getpid())-\(serial)")
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Brings the session up, leaving nothing behind if it cannot.
    ///
    /// No caller cleans up after a failed start: `WaylandBackendTests`,
    /// `X11BackendTests` and `X11MultipleTests` all let the error straight out
    /// of the test that made the session. So a compositor that spawned and then
    /// failed its readiness check would keep running for the rest of the suite,
    /// with its run directory under `/tmp` still there. A leaked Xvfb is worse
    /// than untidy — it holds `/tmp/.X<n>-lock`, which is the lock race that
    /// ``startXvfb()`` numbers displays to avoid.
    ///
    /// The ordering is the whole trick. ``stop()`` deletes the run directory,
    /// and the child's stderr log that a failure message quotes sits inside it;
    /// the message survives only because it is a string built at the `throw`
    /// site, evaluated in full when the error is constructed, before this
    /// `catch` runs. Do not make one of those messages lazy, and do not move
    /// the cleanup up to a `throw` site without building the message first:
    /// either turns every failure here into `(no log)`.
    func start() throws {
        do {
            switch kind {
            case .sway: try startSway()
            case .xvfb: try startXvfb()
            }
        } catch {
            stop()
            throw error
        }
    }

    private func startSway() throws {
        // `exec` nothing: the compositor is only here to hold a clipboard, and
        // an empty config keeps it from trying to spawn a terminal or read the
        // user's own.
        let config = runtimeDirectory.appendingPathComponent("sway.config")
        try Data("# headless\n".utf8).write(to: config)

        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = runtimeDirectory.path
        // The headless backend is what makes this run with no GPU and no
        // display; without it wlroots looks for a DRM device and exits.
        environment["WLR_BACKENDS"] = "headless"
        environment["WLR_LIBINPUT_NO_DEVICES"] = "1"
        let log = runtimeDirectory.appendingPathComponent("sway.log")
        let sway = try Subprocess.spawn(
            try require("sway"),
            arguments: ["-c", config.path],
            environment: environment,
            stderrPath: log.path
        ).process
        process = sway

        guard let socket = waitForSocket(named: "wayland-", startedBy: sway, log: log) else {
            // The tail is read here, while the log still exists: ``start()``
            // catches this, and its cleanup deletes the directory holding it.
            throw Failure.didNotStart("sway produced no Wayland socket\n\(Self.tail(of: log))")
        }
        waylandSocketPath = runtimeDirectory.appendingPathComponent(socket).path
        environment["WAYLAND_DISPLAY"] = socket
        // Removed rather than left: a stale DISPLAY inherited from the host
        // would send `wl-copy` at somebody else's X server.
        environment["DISPLAY"] = nil
        environment["XDG_CURRENT_DESKTOP"] = "sway"
        childEnvironment = environment
    }

    private func startXvfb() throws {
        // A fresh number per session, not a fixed one. Reusing a number as soon
        // as the previous server is killed races its `/tmp/.X<n>-lock`: the new
        // Xvfb fails to bind, the old one answers a connection while it is
        // dying, and the backend then reports "No X11 display could be opened"
        // one test later. Which is exactly what happened.
        let display = ":\(Self.nextDisplayNumber())"
        process = try Subprocess.spawn(
            try require("Xvfb"),
            // `-noreset` is load-bearing, not tidiness. An X server resets when its
            // last client disconnects, and the readiness check below is a client
            // that connects and immediately disconnects — so without this the
            // server tears itself down the instant it is confirmed working, and
            // the backend connecting a moment later is refused with "No X11
            // display could be opened".
            arguments: [display, "-screen", "0", "1280x800x24", "-nolisten", "tcp", "-noreset"],
            environment: ProcessInfo.processInfo.environment
        ).process

        var environment = ProcessInfo.processInfo.environment
        environment["DISPLAY"] = display
        environment["WAYLAND_DISPLAY"] = nil
        environment["XDG_CURRENT_DESKTOP"] = "x11"
        childEnvironment = environment
        x11Display = display

        // Xvfb writes no ready marker, so readiness is "a client can connect",
        // asked by name rather than through `DISPLAY`.
        guard waitUntil({ XDisplayProbe.canConnect(display) }) else {
            // ``start()`` kills the server this leaves behind. Nothing else
            // does, and an Xvfb that outlives the run keeps its lock file.
            throw Failure.didNotStart("Xvfb never accepted a connection on \(display)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        childEnvironment = [:]
        try? FileManager.default.removeItem(at: runtimeDirectory)
    }

    // MARK: - Driving the clipboard from outside

    /// Puts something on the clipboard using a tool that is not Skrepka.
    ///
    /// The whole point of using `wl-copy` and `xclip` rather than Skrepka's own
    /// writer: a test where both ends are this code asserts that it agrees with
    /// itself, which is the one thing that was never in doubt.
    /// Always through standard input, never as an argument. Linux caps a
    /// single `argv` element at `MAX_ARG_STRLEN`, which is 128 KiB — so a
    /// megabyte of text passed as an argument fails with `E2BIG`, and the one
    /// case worth testing here is precisely the large one.
    @discardableResult
    func copy(_ text: String, mimeType: String? = nil) -> Bool {
        switch kind {
        case .sway:
            var arguments: [String] = []
            if let mimeType { arguments += ["--type", mimeType] }
            return run("wl-copy", arguments: arguments, input: text)
        case .xvfb:
            return run(
                "xclip",
                arguments: ["-selection", "clipboard", "-t", mimeType ?? "UTF8_STRING"],
                input: text
            )
        }
    }

    /// Reads the clipboard back with the same outside tool.
    func paste(mimeType: String? = nil) -> String? {
        switch kind {
        case .sway:
            var arguments = ["--no-newline"]
            if let mimeType { arguments += ["--type", mimeType] }
            return capture("wl-paste", arguments: arguments)
        case .xvfb:
            return capture(
                "xclip",
                arguments: ["-selection", "clipboard", "-o", "-t", mimeType ?? "UTF8_STRING"]
            )
        }
    }
}
