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
///
/// Travel: listening is attributed in the time zone that is current when
/// it is credited, the whole slice since the last checkpoint included, and
/// time already credited never moves. After a flight west, the day the
/// user is now in may be the day before the one the open session last
/// credited; that time stays where it was, and Today reads the key of the
/// day that is current in the new zone, so the later day's listening is
/// counted again once that day arrives there.
struct ListeningDays: Sendable {
    /// The version of the rules above, saved with the statistics as
    /// `ReadingStats.dayKeyVersion`. Keys saved without it followed the
    /// system's calendar and are migrated once (`ListeningDayKeyMigration`).
    static let keyVersion = 1

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

    /// The seconds of a span of listening that fall on one local day.
    struct Piece: Equatable, Sendable {
        /// The key of the day the piece falls on.
        let dayKey: String
        /// The length of the piece.
        let seconds: TimeInterval
    }

    /// Splits the span from `start` to `end` at every local midnight it
    /// crosses, so each day gets exactly its own seconds of the span. Days
    /// come from the calendar (`dateInterval(of: .day, for:)`), never as
    /// 86,400 seconds, so the 23- or 25-hour day of a daylight-saving
    /// change, or a day that begins at 1 a.m. because the change happens at
    /// midnight, is split where it really begins and ends. The pieces come
    /// in order, each within one day, and their lengths add up to the
    /// span's. An empty or backward span has no pieces.
    func split(from start: Date, to end: Date) -> [Piece] {
        var pieces: [Piece] = []
        var pieceStart = start
        while pieceStart < end {
            // The piece runs to the end of its day or of the span, whichever
            // comes first. A day the calendar cannot place, or one that does
            // not end after the piece starts, takes the rest of the span, so
            // the loop always ends.
            let dayEnd = calendar.dateInterval(of: .day, for: pieceStart)?.end ?? end
            let pieceEnd = dayEnd > pieceStart ? min(dayEnd, end) : end
            pieces.append(Piece(dayKey: key(for: pieceStart), seconds: pieceEnd.timeIntervalSince(pieceStart)))
            pieceStart = pieceEnd
        }
        return pieces
    }

    /// A moment on the day before the one containing `date`: `date` one
    /// calendar day earlier (`date(byAdding: .day, value: -1, to:)`), which
    /// keeps its time of day across a 23- or 25-hour day where subtracting
    /// 86,400 seconds would skip or repeat a day. Should that not land on an
    /// earlier day, as where a time zone once skipped a whole day, the last
    /// second before this day began is used, so walking back always moves
    /// to the previous day and ends.
    func dayBefore(_ date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        if let earlier = calendar.date(byAdding: .day, value: -1, to: date), earlier < startOfDay {
            return earlier
        }
        return startOfDay.addingTimeInterval(-1)
    }

    /// The `count` consecutive days ending with the one containing `date`:
    /// their keys, latest first, and the moment the earliest of them began.
    func span(ofDays count: Int, endingWith date: Date) -> (keys: [String], start: Date) {
        var keys: [String] = []
        var day = date
        var earliestDay = date
        for _ in 0..<count {
            keys.append(key(for: day))
            earliestDay = day
            day = dayBefore(day)
        }
        return (keys, calendar.startOfDay(for: earliestDay))
    }

    /// `value` in ASCII digits with leading zeros up to `width` digits.
    /// `String(_:)` of an integer never uses a locale, so neither the
    /// user's language nor their numbering system can change the digits.
    private static func zeroPadded(_ value: Int, toWidth width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
