import os

/// Subsystem-scoped loggers. Errors are logged with context here and surfaced
/// to the user in the UI layer — never swallowed in either place.
public enum SkrepkaLog {
    private static let subsystem = "dev.soldunov.skrepka"

    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    public static let panel = Logger(subsystem: subsystem, category: "panel")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
