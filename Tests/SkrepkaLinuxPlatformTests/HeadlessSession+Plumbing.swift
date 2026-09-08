import Foundation
import Synchronization

#if canImport(Glibc)
    import Glibc
#endif

/// Finding tools, running them, and waiting for things that offer no readiness
/// signal.
///
/// Split from ``HeadlessSession`` itself because the fixture crossed 300 lines,
/// and this is the half with no clipboard in it: process plumbing and polling,
/// nothing about Wayland or X11.
extension HeadlessSession {
    enum Failure: Error {
        case toolMissing(String)
        case didNotStart(String)
    }

    func require(_ tool: String) throws -> String {
        guard let path = Self.which(tool) else { throw Failure.toolMissing(tool) }
        return path
    }

    /// Display numbers well above anything a desktop uses, one per session.
    static let displayCounter = Mutex(90)

    static func nextDisplayNumber() -> Int {
        displayCounter.withLock {
            $0 += 1
            return $0
        }
    }

    /// Distinguishes two sessions that would otherwise name the same directory.
    ///
    /// The label alone is not unique. `WaylandBackendTests` and
    /// `X11BackendTests` are separate suites, so Swift Testing runs them
    /// concurrently, and six of their labels are the same word — `probe`,
    /// `html`, `notify`, `self`, `text`, `write`. Two sessions sharing a run
    /// directory is not a near-miss: ``HeadlessSession/stop()`` removes that
    /// directory, so the suite that finished first deleted the other's
    /// `XDG_RUNTIME_DIR` out from under a live compositor — which showed up as
    /// sway running happily for its full thirty-second timeout without ever
    /// producing a socket, and a failure message reading `(no log)` because
    /// sway's stderr file had gone with it.
    static let sessionCounter = Mutex(0)

    static func nextSessionNumber() -> Int {
        sessionCounter.withLock {
            $0 += 1
            return $0
        }
    }

    /// Whether `SIGPIPE` has already been turned off for this process.
    ///
    /// A `Mutex` rather than a lazy `static let` for the same reason the
    /// counters above are one: every test in both integration suites can reach
    /// this concurrently, and one flag guarded the same way as everything else
    /// in this file is easier to read than two synchronisation stories.
    private static let sigpipeIgnored = Mutex(false)

    /// Ignores `SIGPIPE`, once, from whichever test arrives first.
    ///
    /// ``Subprocess/spawn(_:arguments:environment:stdin:stdout:stderrPath:)``
    /// leaves the parent's signal disposition alone, so a clipboard tool that
    /// has already exited turns the write below into a `SIGPIPE` — whose
    /// default action kills the whole test runner rather than the write.
    ///
    /// The backends do set this themselves, but not soon enough to help here:
    /// ``SkrepkaLinuxPlatform/DataControlSession`` sets it only once a Wayland
    /// session has started, and the X11 session never sets it at all. This
    /// fixture writes to a child before either, and in tests that start
    /// neither, so it has to hold the disposition down itself.
    static func ignoreSIGPIPE() {
        sigpipeIgnored.withLock { alreadyIgnored in
            guard !alreadyIgnored else { return }
            signal(SIGPIPE, SIG_IGN)
            alreadyIgnored = true
        }
    }

    static func which(_ tool: String) -> String? {
        let search = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in search.split(separator: ":") {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    func run(_ tool: String, arguments: [String], input: String? = nil) -> Bool {
        guard let path = Self.which(tool) else { return false }
        guard
            let spawned = try? Subprocess.spawn(
                path,
                arguments: arguments,
                environment: childEnvironment,
                stdin: input == nil ? .discard : .pipe
            )
        else { return false }

        if let input, let descriptor = spawned.stdin {
            Self.ignoreSIGPIPE()
            // In a loop, because a pipe takes 64 KiB at a time and the case
            // this fixture exists to cover is the megabyte one.
            let bytes = Array(input.utf8)
            var offset = 0
            var wroteEverything = true
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { buffer in
                    write(descriptor, buffer.baseAddress, buffer.count)
                }
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    // `EPIPE` above all: the tool exited before it had the
                    // whole clipping, so what it put on the clipboard — if
                    // anything — is not what this call was asked to copy.
                    // Reporting success would leave the test asserting against
                    // the previous clipping and calling that a pass.
                    wroteEverything = false
                    break
                }
            }
            close(descriptor)
            guard wroteEverything else {
                // Reaped rather than left: `terminate()` kills a tool still
                // waiting on input it will never get, and collects one that has
                // already died, so neither becomes a zombie for the rest of the
                // run.
                spawned.process.terminate()
                return false
            }
        }
        // `wl-copy` and `xclip` both fork a server that holds the selection, so
        // the foreground process exits immediately, and waiting for that exit
        // is what makes the copy observable rather than racy.
        return spawned.process.wait() == 0
    }

    func capture(_ tool: String, arguments: [String]) -> String? {
        guard let path = Self.which(tool) else { return nil }
        guard
            let spawned = try? Subprocess.spawn(
                path,
                arguments: arguments,
                environment: childEnvironment,
                stdout: .pipe
            ), let descriptor = spawned.stdout
        else { return nil }

        var output = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &scratch, scratch.count)
            if count > 0 {
                output.append(contentsOf: scratch[0..<count])
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        close(descriptor)
        guard spawned.process.wait() == 0 else { return nil }
        return String(bytes: output, encoding: .utf8)
    }

    /// Polls a condition to a deadline.
    ///
    /// A compositor takes a moment to come up and offers no readiness signal;
    /// the alternative to polling is a fixed sleep, which is either slower or
    /// flakier depending on the machine.
    func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }
}
