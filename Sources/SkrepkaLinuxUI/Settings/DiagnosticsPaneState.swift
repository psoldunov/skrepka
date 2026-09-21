import Foundation
import SkrepkaIPC

/// The Diagnostics pane, as the widgets draw it: problems first, then one card
/// each for the clipboard, the network, storage and the daemon — what
/// `skrepka doctor` prints, laid out — and the report Copy puts on the
/// clipboard.
public struct DiagnosticsPaneState: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        case good
        case warning
        case bad
    }

    /// One fact: a label on the left, its value on the right.
    public struct Row: Sendable, Hashable {
        public let title: String
        public let value: String
        /// Set for a value somebody may paste somewhere — a path, a
        /// fingerprint — which is drawn monospaced and selectable.
        public let isLiteral: Bool

        init(_ title: String, _ value: String, isLiteral: Bool = false) {
            self.title = title
            self.value = value
            self.isLiteral = isLiteral
        }
    }

    public struct Card: Sendable, Hashable {
        public let title: String
        public let rows: [Row]
        /// Notes under the rows: a blocked session, a responder that failed.
        public let notes: [String]
    }

    /// The headline: everything works, or how many things do not.
    public let headline: String
    public let tone: Tone
    /// Each problem, as the daemon worded it.
    public let problems: [String]
    public let cards: [Card]
    /// `skrepka doctor`'s text, for Copy; nil until there is a report.
    public let report: String?
    /// Shown in place of the cards while there are none.
    public let placeholder: String?

    public init(_ diagnosis: PreferencesModel.Diagnosis, timeZone: TimeZone) {
        switch diagnosis {
        case .loading:
            self.init(placeholder: "Asking skrepkad…", tone: .warning, headline: "Checking…")
        case .failed(let failure):
            self.init(
                placeholder: failure.remedy.map { "\(failure.message) \($0)" } ?? failure.message,
                tone: .bad,
                headline: "Skrepka cannot check itself right now.")
        case .ready(let document):
            self.init(document, timeZone: timeZone)
        }
    }

    private init(placeholder: String, tone: Tone, headline: String) {
        self.headline = headline
        self.tone = tone
        problems = []
        cards = []
        report = nil
        self.placeholder = placeholder
    }

    private init(_ document: DiagnosticsDocument, timeZone: TimeZone) {
        problems = document.problems
        switch problems.count {
        case 0:
            headline = "Everything Skrepka checks is working."
            tone = .good
        case 1:
            headline = "One thing needs attention."
            tone = document.session.isBlocking ? .bad : .warning
        default:
            headline = "\(problems.count) things need attention."
            tone = document.session.isBlocking ? .bad : .warning
        }
        cards = [
            DiagnosticsCards.clipboard(document.session),
            DiagnosticsCards.network(document.network),
            DiagnosticsCards.storage(document.storage, timeZone: timeZone),
            DiagnosticsCards.daemon(document),
        ]
        report = DoctorReport.text(document, timeZone: timeZone)
        placeholder = nil
    }

    public static let reportFooter = "Paste this into a bug report — it carries no clipboard content."
}
