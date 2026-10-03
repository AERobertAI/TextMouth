import Foundation

/// The local days that listening time is kept by (TODO C06).
///
/// A day key, such as "2026-10-02", names one local day. Day keys are the
/// keys of `ReadingStats.dailyListeningSeconds`, which is saved, so a key
/// must go on naming the same day for as long as the statistics exist. Keys
/// are therefore always written in the Gregorian calendar, in the POSIX
/// locale, with ASCII digits, whatever calendar, language, or numbering
/// system the user chooses: with the system's settings, as before, a switch
/// to the Buddhist calendar turned 2026 into "2569", which left every saved
/// total unreachable and broke the streak. Days are the user's local days,
/// though, so the one setting keys do follow is the time zone.
struct ListeningDays: Sendable {
    /// The calendar every key and every day boundary is computed in:
    /// Gregorian, POSIX, in the time zone these days are local to.
    let calendar: Calendar

    /// The days local to `timeZone`.
    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// The key of the day containing `date`: its Gregorian year, month, and
    /// day as "yyyy-MM-dd", zero-padded, in ASCII digits.
    func key(for date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return [
            Self.zeroPadded(day.year ?? 0, toWidth: 4),
            Self.zeroPadded(day.month ?? 0, toWidth: 2),
            Self.zeroPadded(day.day ?? 0, toWidth: 2),
        ].joined(separator: "-")
    }

    /// `value` in ASCII digits with leading zeros up to `width` digits.
    /// `String(_:)` of an integer never uses a locale, so neither the
    /// user's language nor their numbering system can change the digits.
    private static func zeroPadded(_ value: Int, toWidth width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
