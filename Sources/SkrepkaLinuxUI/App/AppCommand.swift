/// What one invocation of `skrepka-gui` asks the running app to do.
///
/// The app is single-instance: a second `skrepka-gui` hands its arguments to
/// the first over the session bus and exits with whatever status the first
/// answers. So these are not start-up modes of a process — they are requests
/// to the one process that owns the tray, and every one of them is safe to
/// send to an app that is already running.
///
/// Decided without GTK in scope, so every spelling is tested.
public enum AppCommand: Equatable, Sendable {
    /// No arguments: what clicking the launcher means. The picker opens, so a
    /// first launch shows the user what the app is instead of a tray icon they
    /// have not noticed yet.
    case showPicker
    /// `--picker`: open the picker, or close it if it is open. What a
    /// keyboard shortcut bound by hand in the desktop's own settings runs.
    case togglePicker
    /// `--settings`: open the Settings window, or raise it.
    case openSettings
    /// `--background`: run the tray and the shortcut and show nothing. What
    /// the autostart entry runs at login.
    case background
    /// `--quit`: stop the app. The daemon is a separate service and keeps
    /// recording history.
    case quit
    /// `--help`.
    case help

    /// The usage text, printed for `--help` and after a mistake.
    public static let usage = """
        usage: skrepka-gui [--picker | --settings | --background | --quit]

          (no option)    open the clipboard picker
          --picker       open the picker, or close it when it is open —
                         bind this to a shortcut if the desktop has no
                         global-shortcuts portal
          --settings     open Settings
          --background   start in the tray without opening anything
          --quit         quit the app (skrepkad keeps running)
        """

    /// Why an invocation could not be understood.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownOption(String)
        case tooManyOptions([String])

        public var description: String {
            switch self {
            case .unknownOption(let option):
                "unknown option \(option)"
            case .tooManyOptions(let options):
                "pass one option at a time, not \(options.joined(separator: " "))"
            }
        }
    }

    /// Reads the arguments after the program name.
    ///
    /// One option at most. Two of these rarely mean anything together —
    /// `--picker --settings` would open the picker and immediately cover it —
    /// so the second is refused rather than silently dropped.
    public static func parse(_ arguments: [String]) -> Result<AppCommand, ParseError> {
        guard arguments.count <= 1 else { return .failure(.tooManyOptions(arguments)) }
        guard let option = arguments.first else { return .success(.showPicker) }
        switch option {
        case "--picker": return .success(.togglePicker)
        case "--settings": return .success(.openSettings)
        case "--background": return .success(.background)
        case "--quit": return .success(.quit)
        case "--help", "-h": return .success(.help)
        default: return .failure(.unknownOption(option))
        }
    }
}
