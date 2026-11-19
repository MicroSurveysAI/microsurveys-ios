import Foundation

/// How long the thank-you stays up after the last answer. The delay grows with the length of the
/// message so a longer one gets time to be read, and the survey's `successPace` scales it.
/// Every MicroSurveys SDK uses the same formula and test vectors.
enum ThankYouTiming {
    static let defaultMessage = "Thanks!"

    /// The text the thank-you shows: the trimmed `successMessage`, or the default when blank.
    static func message(_ successMessage: String?) -> String {
        let trimmed = successMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultMessage : trimmed
    }

    /// Delay in milliseconds before the thank-you closes itself (before any screen-reader doubling).
    /// `pace` is `"slow"`, `"fast"`, or anything else (including `nil`) for normal.
    static func durationMs(message successMessage: String?, pace: String?) -> Int {
        let chars = message(successMessage).unicodeScalars.count
        let base = min(max(1000 + 50 * chars, 1300), 7000)
        let percent: Int
        switch pace {
        case "slow": percent = 150
        case "fast": percent = 70
        default: percent = 100
        }
        // Integer round-half-up of base × percent / 100 (both are positive).
        return (base * percent + 50) / 100
    }
}
