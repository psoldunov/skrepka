#if canImport(os)
    import os
#else
    import Logging
#endif

/// Subsystem-scoped loggers. Errors are logged with context here and surfaced
/// to the user in the UI layer — never swallowed in either place.
///
/// `os.Logger` on Apple platforms, swift-log everywhere else. The two agree on
/// the call sites Skrepka uses: both `error(_:)`, `notice(_:)` and `debug(_:)`
/// take one message argument, and both message types conform to
/// `ExpressibleByStringInterpolation`, so `"…\(error.localizedDescription)"`
/// compiles unchanged against either (checked against swift-log 1.15.0's
/// `Sources/Logging/Logger.swift`, not remembered).
///
/// What does *not* port is `os`'s privacy interpolation —
/// `"\(message, privacy: .public)"` is an `OSLogInterpolation` feature with no
/// swift-log equivalent. Every use of it is in the macOS-only app target, so
/// nothing here has to pretend otherwise. A future `SkrepkaCore` call site
/// wanting redaction on both platforms needs swift-log metadata instead, and
/// that is a change to make deliberately rather than by reaching for the
/// familiar syntax.
///
/// Construction is the one genuine difference: `os.Logger` is scoped by
/// subsystem and category, swift-log by a single label. Joining the two with a
/// dot keeps `dev.soldunov.skrepka.store` recognisable in either log.
public enum SkrepkaLog {
    private static let subsystem = "dev.soldunov.skrepka"

    public static let store = make(category: "store")
    public static let clipboard = make(category: "clipboard")
    public static let paste = make(category: "paste")
    public static let panel = make(category: "panel")
    public static let permissions = make(category: "permissions")

    private static func make(category: String) -> Logger {
        #if canImport(os)
            Logger(subsystem: subsystem, category: category)
        #else
            Logger(label: "\(subsystem).\(category)")
        #endif
    }
}
