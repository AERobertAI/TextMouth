import Foundation

/// Rewrites the day keys that TextMouth wrote before TODO C06 as the
/// Gregorian keys of `ListeningDays`, once for each statistics file.
///
/// Those keys came from a `DateFormatter` that followed the system's
/// settings of the day, so they are in whatever calendar and digits the
/// user had: Thai users got Buddhist years ("2569-10-02"), the Japanese
/// calendar era years ("0008-10-02"), Saudi Arabia the Umm al-Qura
/// calendar in Arabic-Indic digits ("١٤٤٨-٠٤-٢١"), and Egypt Gregorian
/// dates in those digits. Each key is read back the way it was written: a
/// strict formatter in a candidate calendar parses it, and the reading
/// counts only when that formatter writes exactly the same key for the day
/// it read, and that day is one TextMouth could have recorded. The
/// candidates, in order:
///
/// 1. Gregorian, in ASCII digits, so a key that already names such a day
///    is left as it is (made ASCII if its digits were not);
/// 2. the user's calendar now, which wrote the keys unless it changed:
///    first exactly as the old formatter used it, with the user's locale,
///    whose digits and leap-month markers ("闰" in Chinese) it wrote, then
///    in ASCII digits, in case only the digits changed;
/// 3. every other calendar macOS offers, in ASCII digits, for keys written
///    before the user changed calendars.
///
/// A day TextMouth could have recorded lies between `earliestDay` and two
/// days after now: a time zone can be a day ahead of UTC, and a clock a
/// little fast. That window is what tells the calendars apart. This year
/// in each of the others (2569, 0008, 0115, 1448, 5787, 1405, 1948, 1743,
/// 2019 Ethiopian, 7519, cyclic 0043) falls outside it when read as
/// Gregorian, and the years differ enough that only variants of one
/// calendar, the Islamic ones, can read a key as different days in it.
///
/// A key that no candidate reads is kept, seconds and all, under
/// `legacyKeyPrefix`: the all-time total, which the migration never
/// changes, still includes it, but no day does.
struct ListeningDayKeyMigration {
    /// The prefix of a key no calendar could read, kept as
    /// "legacy:" followed by the key as it was.
    static let legacyKeyPrefix = "legacy:"

    /// The tag of the debug log line that reports a migration.
    static let logTag = "READING_STATS_DAY_KEYS"

    /// The first day TextMouth could have recorded listening on, 1 January
    /// 2025, ahead of its first commit in March 2026. Read as Gregorian,
    /// this year in every other calendar falls before it or after now; the
    /// Ethiopian year, seven or eight behind, reaches 2025 only in 2032.
    static let earliestDay = DateComponents(year: 2025, month: 1, day: 1)

    /// The calendars macOS offers besides the Gregorian, in the order they
    /// are tried once the user's own has failed. Of the Islamic variants,
    /// which can read one key as days a day or two apart, the Umm al-Qura
    /// calendar, Saudi Arabia's official one, comes first.
    private static let otherCalendars: [Calendar.Identifier] = [
        .buddhist, .japanese, .republicOfChina, .islamicUmmAlQura, .islamic, .islamicCivil,
        .islamicTabular, .hebrew, .persian, .indian, .coptic, .ethiopicAmeteMihret,
        .ethiopicAmeteAlem, .chinese,
    ]

    /// Writes the Gregorian key of a day read in UTC, where keys are read.
    private static let gregorianDays = ListeningDays(timeZone: .gmt)

    /// What migrating one statistics file's daily totals came to.
    struct Outcome: Equatable {
        /// The daily totals under Gregorian keys, with the seconds of keys
        /// that name the same day added together, and those of keys no
        /// calendar read under `legacyKeyPrefix`.
        var dailyListeningSeconds: [String: TimeInterval] = [:]
        /// How many keys were rewritten: read in another calendar or
        /// written in other digits.
        var rewrittenKeyCount = 0
        /// The keys no calendar read, as they were, in sorted order.
        var legacyKeys: [String] = []

        /// The debug log line reporting this migration, or nil when it
        /// changed no key.
        var logLine: String? {
            guard rewrittenKeyCount > 0 || !legacyKeys.isEmpty else { return nil }
            var line = "\(ListeningDayKeyMigration.logTag): rewritten \(rewrittenKeyCount)"
            if !legacyKeys.isEmpty {
                let quoted = legacyKeys.map { "\"\($0)\"" }.joined(separator: ", ")
                line += ", kept as legacy \(legacyKeys.count): \(quoted)"
            }
            return line
        }
    }

    /// One way of reading keys back: a strict formatter set up like the
    /// one that wrote them, but in UTC, and whether a key's digits are
    /// made ASCII before it is read.
    private struct KeyReader {
        /// Parses and writes keys in one calendar and locale.
        let formatter: DateFormatter
        /// Whether keys are read in ASCII digits, as the POSIX locale
        /// writes them, rather than as they were written.
        let readsASCIIDigits: Bool

        /// A reader of "yyyy-MM-dd" keys in the `identifier` calendar and
        /// `locale`'s digits and markers. It refuses anything it would not
        /// write itself (`isLenient` is false), and takes what a key leaves
        /// out, such as the Japanese era or the Chinese 60-year cycle, from
        /// `now`: the keys were written in the era current now.
        init(calendar identifier: Calendar.Identifier, locale: Locale, now: Date, readsASCIIDigits: Bool) {
            let formatter = DateFormatter()
            // The calendar comes from the locale's calendar keyword alone,
            // as it did for the formatter that wrote the keys; a Calendar
            // assigned to the formatter can count days differently.
            formatter.locale = Self.locale(locale, calendar: identifier)
            formatter.timeZone = .gmt
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            formatter.defaultDate = now
            self.formatter = formatter
            self.readsASCIIDigits = readsASCIIDigits
        }

        /// `base` with its calendar set to `identifier`. Foundation names
        /// the Ethiopian Amete Alem calendar by its short alias, "ethioaa",
        /// which the formatters of the macOS versions tested read as the
        /// Gregorian calendar (its `Calendar(identifier:)` counts days as
        /// the Gregorian does too), so that one is given its full keyword,
        /// "ethiopic-amete-alem", which they read as the calendar that
        /// wrote the keys.
        private static func locale(_ base: Locale, calendar identifier: Calendar.Identifier) -> Locale {
            var components = Locale.Components(locale: base)
            components.calendar = identifier
            let locale = Locale(components: components)
            guard identifier == .ethiopicAmeteAlem else { return locale }
            return Locale(identifier: locale.identifier.replacingOccurrences(
                of: "calendar=ethioaa", with: "calendar=ethiopic-amete-alem"
            ))
        }

        /// A moment of the day `key` names, in UTC, at the time of day of
        /// `now` (which the key leaves out), when this reader writes exactly
        /// that key for it again; otherwise the key was read leniently or in
        /// another calendar's sense, and nil.
        func day(namedBy key: String) -> Date? {
            let written = readsASCIIDigits ? ListeningDayKeyMigration.asciiDigits(key) : key
            guard let day = formatter.date(from: written), formatter.string(from: day) == written else {
                return nil
            }
            return day
        }
    }

    /// The readers to try on each key, in order.
    private let readers: [KeyReader]

    /// The moments a key's day may be read as to be accepted: from the
    /// start of `earliestDay` to two days after now, in UTC. Readers give
    /// the day at now's time of day, so this admits exactly the days from
    /// `earliestDay` to the day after tomorrow.
    private let plausibleDays: ClosedRange<Date>

    /// A migration for a file whose keys were written in `userCalendar`'s
    /// calendar system and locale, unless the user changed them, as of
    /// `now`. Nil when `now` is before `earliestDay`: a clock that wrong
    /// cannot tell which days are plausible, and would turn every real key
    /// into a legacy entry for good, so the migration waits for a launch
    /// with a sane one.
    init?(userCalendar: Calendar, now: Date) {
        let utc = Self.gregorianDays.calendar
        guard let earliest = utc.date(from: Self.earliestDay), now >= earliest,
              let latest = utc.date(byAdding: .day, value: 2, to: now)
        else { return nil }
        plausibleDays = earliest...latest

        // Each calendar once in ASCII digits. ISO 8601 writes days exactly
        // as the Gregorian calendar does, so it adds nothing.
        let posix = Locale(identifier: "en_US_POSIX")
        var seen: Set<Calendar.Identifier> = [.iso8601]
        let asciiReaders = ([.gregorian, userCalendar.identifier] + Self.otherCalendars)
            .filter { seen.insert($0).inserted }
            .map { KeyReader(calendar: $0, locale: posix, now: now, readsASCIIDigits: true) }
        // The user's settings exactly as the old formatter used them come
        // right after the Gregorian reading.
        let asWritten = KeyReader(
            calendar: userCalendar.identifier, locale: userCalendar.locale ?? posix,
            now: now, readsASCIIDigits: false
        )
        readers = [asciiReaders[0], asWritten] + asciiReaders.dropFirst()
    }

    /// Migrates `dailyListeningSeconds` as an earlier TextMouth saved them.
    func migrate(_ dailyListeningSeconds: [String: TimeInterval]) -> Outcome {
        var outcome = Outcome()
        // In key order, so the seconds of keys naming one day are always
        // added in the same order.
        for (key, seconds) in dailyListeningSeconds.sortedStably(by: { $0.key < $1.key }) {
            let migratedKey: String
            if key.hasPrefix(Self.legacyKeyPrefix) {
                // Kept by an earlier migration, before a version that does
                // not know `dayKeyVersion` saved the file without it.
                migratedKey = key
            } else if let gregorianKey = gregorianKey(forLegacyKey: key) {
                migratedKey = gregorianKey
                if gregorianKey != key { outcome.rewrittenKeyCount += 1 }
            } else {
                migratedKey = Self.legacyKeyPrefix + key
                outcome.legacyKeys.append(key)
            }
            outcome.dailyListeningSeconds[migratedKey, default: 0] += seconds
        }
        return outcome
    }

    /// The Gregorian key of the day that `key`, written by an earlier
    /// TextMouth, names: from the first reader that reads it back exactly
    /// as a day TextMouth could have recorded, or nil when none does.
    func gregorianKey(forLegacyKey key: String) -> String? {
        for reader in readers {
            if let day = reader.day(namedBy: key), plausibleDays.contains(day) {
                return Self.gregorianDays.key(for: day)
            }
        }
        return nil
    }

    /// `key` with every decimal digit of any script (Arabic-Indic, Persian,
    /// Thai, Devanagari, and so on) replaced by the ASCII digit of the same
    /// value, which is how a formatter in the POSIX locale can read it.
    static func asciiDigits(_ key: String) -> String {
        var ascii = String.UnicodeScalarView()
        for scalar in key.unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber,
               let value = scalar.properties.numericValue {
                // A decimal digit's value is a whole number from 0 to 9.
                ascii.append(contentsOf: String(Int(value)).unicodeScalars)
            } else {
                ascii.append(scalar)
            }
        }
        return String(ascii)
    }
}
