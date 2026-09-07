import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// `posix_spawn` and `waitpid`, directly.
///
/// Not `Foundation.Process`, and the reason is a measurement rather than
/// taste. Driving the headless compositor through `Process` hung the whole test
/// binary: the main thread sat in `rt_sigsuspend` — which is how
/// swift-corelibs-foundation implements `waitUntilExit()`, waiting for a
/// `SIGCHLD` that never arrived — while the child it was waiting on was still
/// running ten minutes later. The same work through the probe binary, outside
/// the test harness, completed in under a second.
///
/// Rather than work out which of the several things in this process changes
/// signal handling — the Swift concurrency runtime, libdispatch, or the
/// backends' own `signal(SIGPIPE, SIG_IGN)` — the child handling is done with
/// the two calls whose behaviour is not in question. `waitpid` with `WNOHANG`
/// in a bounded loop cannot hang, whatever else the process is doing to
/// signals.
struct Subprocess {
    let pid: pid_t

    enum Failure: Error {
        case notExecutable(String)
        case spawnFailed(String, errno: Int32)
    }

    /// Spawns a child, with each stream either inherited, discarded, or piped.
    ///
    /// - Returns: the child, plus the parent's end of whichever pipes were
    ///   asked for. The caller closes those.
    static func spawn(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Redirect = .discard,
        stdout: Redirect = .discard,
        stderrPath: String = "/dev/null"
    ) throws -> (process: Subprocess, stdin: Int32?, stdout: Int32?) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notExecutable(executable)
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var parentStdin: Int32?
        var parentStdout: Int32?
        var toClose: [Int32] = []
        defer { for descriptor in toClose { close(descriptor) } }

        if stdin == .pipe {
            let ends = try makePipe(&actions, childEnd: 0, executable: executable)
            toClose.append(ends.child)
            parentStdin = ends.parent
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if stdout == .pipe {
            let ends = try makePipe(&actions, childEnd: 1, executable: executable)
            toClose.append(ends.child)
            parentStdout = ends.parent
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        // Clipboard-tool chatter is noise, so it goes to /dev/null by default.
        // A long-lived child gets a real file instead: when a compositor fails
        // to come up, its own complaint is the only thing that says why, and
        // discarding it turns a diagnosable failure into a flake.
        posix_spawn_file_actions_addopen(
            &actions, 2, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644
        )

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, nil, argv, envp)
        guard result == 0 else { throw Failure.spawnFailed(executable, errno: result) }
        return (Subprocess(pid: pid), parentStdin, parentStdout)
    }

    enum Redirect: Equatable {
        case discard
        case pipe
    }

    /// A pipe with one end wired to the child's `childEnd` descriptor.
    ///
    /// The parent's end is closed **in the child** rather than merely inherited.
    /// `posix_spawn` hands the child every descriptor the parent holds, so on
    /// the standard-input side that would leave the child a writer on its own
    /// input and reading EOF would never happen — which is a `wl-copy` hanging
    /// forever on a clipping the parent already finished sending.
    private static func makePipe(
        _ actions: inout posix_spawn_file_actions_t,
        childEnd: Int32,
        executable: String
    ) throws -> (parent: Int32, child: Int32) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw Failure.spawnFailed(executable, errno: errno) }
        // Standard input reads, so the child takes the read end and the parent
        // keeps the write end; every other stream is the other way round.
        let isInput = childEnd == 0
        let forChild = isInput ? ends[0] : ends[1]
        let forParent = isInput ? ends[1] : ends[0]
        posix_spawn_file_actions_adddup2(&actions, forChild, childEnd)
        posix_spawn_file_actions_addclose(&actions, forParent)
        return (parent: forParent, child: forChild)
    }

    /// The exit status, or nil while the child is still running.
    func status() -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        // WIFEXITED/WEXITSTATUS are function-like macros, which Swift does not
        // import; both are one mask and one shift on the raw status word.
        return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
    }

    /// Waits for the child to exit, to a deadline.
    ///
    /// Returns nil on timeout rather than blocking forever, which is the whole
    /// point of not using `waitUntilExit()`.
    @discardableResult
    func wait(timeout: Duration = .seconds(10)) -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let status = status() { return status }
            usleep(5_000)
        }
        return status()
    }

    /// SIGTERM, then SIGKILL if it is ignored, then reap.
    func terminate() {
        kill(pid, SIGTERM)
        if wait(timeout: .seconds(3)) == nil {
            kill(pid, SIGKILL)
            wait(timeout: .seconds(3))
        }
    }
}
