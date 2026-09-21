import Foundation

/// The one timestamp format every plain-text report uses — `skrepka list`,
/// `skrepka doctor`, and the Settings window's copy of the doctor report.
///
/// Fixed-width, ISO-ordered, and deliberately not localised: the output is
/// read next to a terminal history and pasted into issues, where a
/// locale-dependent date is one more thing to disambiguate.
public enum ReportStamp {
    public static func text(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let fields = [parts.month, parts.day, parts.hour, parts.minute].map { value in
            let digits = String(value ?? 0)
            return digits.count < 2 ? "0" + digits : digits
        }
        return "\(fields[0])-\(fields[1]) \(fields[2]):\(fields[3])"
    }
}
