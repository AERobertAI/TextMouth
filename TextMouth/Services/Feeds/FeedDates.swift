import Foundation

// MARK: - Dates and Durations in Feeds (FR03)

/// Reads the dates and durations feeds write (FR03), in the forms seen in
/// the wild as well as the specified ones.
///
/// - RSS dates follow RFC 822 ("Wed, 02 Oct 2002 13:00:00 GMT"): the day
///   name is optional and never checked (a wrong one is common), seconds are
///   optional, the year has two or four digits, and the zone is an offset
///   ("+0200", "+02:00"), "GMT", "UT", "UTC", "Z", one of the US names RFC
///   822 defines ("EST", "PDT", and so on), another abbreviation the system
///   knows, or missing, which reads as UTC. Month names are English, three
///   letters or whole ("Sept" too), in any letter case.
/// - Atom and Dublin Core dates follow RFC 3339 ("2003-12-13T18:30:02.25Z"),
///   read leniently: fractional seconds, a space for the "T", missing
///   seconds, a missing zone (read as UTC), or a date alone.
///
/// Dates are read by hand rather than with a `DateFormatter`, which reads a
/// two-digit year "02" as the year 2 and needs a pattern for every variant
/// (measured in the research). A date in any other form, such as one with
/// German month names, is nil, and its item sorts by when it was first seen.
enum FeedDates {
    /// The date `text` names, or nil when it names none in a form read here.
    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // RFC 3339 begins with a four-digit year and a hyphen; RFC 822 with a
        // day name or the day.
        let characters = Array(trimmed.prefix(5))
        if characters.count == 5, characters.prefix(4).allSatisfy({ $0.isASCII && $0.isNumber }), characters[4] == "-" {
            return rfc3339Date(from: trimmed)
        }
        return rfc822Date(from: trimmed)
    }

    // MARK: RFC 822

    /// The RFC 822 date `text` names: an optional day name, then day,
    /// month, year, and optionally the time and zone.
    static func rfc822Date(from text: String) -> Date? {
        var tokens = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        // A day name ("Wed", "Wednesday") is never checked: feeds often give
        // the wrong one.
        if let first = tokens.first, first.allSatisfy(\.isLetter) {
            tokens.removeFirst()
        }
        guard tokens.count >= 3,
              let day = Int(tokens[0]), (1...31).contains(day),
              let month = month(named: tokens[1]),
              let year = fullYear(tokens[2]) else { return nil }

        var hour = 0, minute = 0, second = 0
        var zoneTokens = Array(tokens.dropFirst(3))
        if let time = zoneTokens.first, time.contains(":") {
            zoneTokens.removeFirst()
            guard let parts = timeParts(time) else { return nil }
            (hour, minute, second) = parts
        }
        // A zone written in two parts, such as "+0200 (CEST)", is read by its
        // first part.
        guard let offset = zoneOffset(zoneTokens.first) else { return nil }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                        second: second, fraction: 0, offset: offset)
    }

    /// The month whose English name, three letters or whole, `name` is.
    private static func month(named name: String) -> Int? {
        let prefix = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(3)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: String(prefix)).map { $0 + 1 }
    }

    /// The four-digit year a two- or four-digit year means. A two-digit year
    /// is in this century below 50 and in the last one from 50 on, as RFC
    /// 2822 reads one.
    private static func fullYear(_ text: String) -> Int? {
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(text) else { return nil }
        switch text.count {
        case 2: return year < 50 ? 2000 + year : 1900 + year
        case 4: return year
        default: return nil
        }
    }

    /// The hour, minute, and second of "13:00:00" or "13:00".
    private static func timeParts(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2 || parts.count == 3, !parts.contains(nil) else { return nil }
        let values = parts.compactMap { $0 }
        let (hour, minute, second) = (values[0], values[1], values.count == 3 ? values[2] : 0)
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return (hour, minute, second)
    }

    /// The zones RFC 822 names, with their offsets in hours.
    private static let namedZones: [String: Int] = [
        "GMT": 0, "UT": 0, "UTC": 0, "Z": 0,
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
    ]

    /// The offset from UTC, in seconds, that a zone token gives: 0 for a
    /// missing zone or a military letter, which RFC 1123 calls unreliable,
    /// and for an abbreviation the system does not know; nil for something
    /// that is no zone at all.
    private static func zoneOffset(_ token: String?) -> Int? {
        guard let token, !token.isEmpty else { return 0 }
        if let sign = token.first, sign == "+" || sign == "-" {
            return numericOffset(String(token.dropFirst()), negative: sign == "-")
        }
        let upper = token.uppercased()
        if let hours = namedZones[upper] {
            return hours * 3_600
        }
        guard upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        if upper.count == 1 {
            return 0
        }
        return TimeZone(abbreviation: upper)?.secondsFromGMT() ?? 0
    }

    /// The offset written as digits after its sign: "0200", "02:00", or
    /// "02", in seconds; nil for anything else.
    private static func numericOffset(_ digits: String, negative: Bool) -> Int? {
        let plain = digits.replacingOccurrences(of: ":", with: "")
        guard plain.count == 2 || plain.count == 4, plain.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(plain) else { return nil }
        let hours = plain.count == 2 ? value : value / 100
        let minutes = plain.count == 2 ? 0 : value % 100
        guard hours <= 14, minutes < 60 else { return nil }
        let seconds = hours * 3_600 + minutes * 60
        return negative ? -seconds : seconds
    }

    // MARK: RFC 3339

    /// The RFC 3339 date `text` names, read leniently: "YYYY-MM-DD", then
    /// optionally "T" (or "t", or a space) and "HH:MM", optionally ":SS" with
    /// a fraction after "." or ",", then optionally "Z" or an offset.
    static func rfc3339Date(from text: String) -> Date? {
        var reader = DigitReader(text)
        guard let year = reader.number(digits: 4), reader.skip("-"),
              let month = reader.number(digits: 2), reader.skip("-"),
              let day = reader.number(digits: 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        if reader.skip("T") || reader.skip("t") || reader.skip(" ") {
            guard let readHour = reader.number(digits: 2), reader.skip(":"),
                  let readMinute = reader.number(digits: 2) else { return nil }
            (hour, minute) = (readHour, readMinute)
            if reader.skip(":") {
                guard let readSecond = reader.number(digits: 2) else { return nil }
                second = readSecond
                if reader.skip(".") || reader.skip(",") {
                    guard let digits = reader.digitRun(), let value = Double("0." + digits) else { return nil }
                    fraction = value
                }
            }
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        reader.skipSpaces()
        var offset = 0
        if reader.skip("Z") || reader.skip("z") {
            offset = 0
        } else if let sign = reader.next(where: { $0 == "+" || $0 == "-" }) {
            guard let parsed = numericOffset(reader.rest, negative: sign == "-") else { return nil }
            offset = parsed
            reader.skipToEnd()
        }
        guard reader.isAtEnd else { return nil }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                        second: second, fraction: fraction, offset: offset)
    }

    /// The moment the given calendar fields name in the zone `offset`
    /// seconds from UTC, or nil when they name no real day (February 30). A
    /// leap second, 60, reads as the second before it.
    private static func makeDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, fraction: Double, offset: Int
    ) -> Date? {
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59)
        )
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date.addingTimeInterval(fraction)
    }

    // MARK: Durations

    /// How long an episode plays, in seconds, from an `itunes:duration`:
    /// "HH:MM:SS", "H:MM:SS", "MM:SS", or seconds alone ("1780", "1780.5"),
    /// whitespace around it ignored. Nil for anything else, or for a length
    /// of 0.
    static func duration(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            // Every part is digits; only the last may hold a fraction.
            let allowed = isLast ? CharacterSet(charactersIn: "0123456789.") : CharacterSet(charactersIn: "0123456789")
            guard !part.isEmpty, part.unicodeScalars.allSatisfy(allowed.contains),
                  let value = Double(part), value.isFinite else { return nil }
            // After the first part, minutes and seconds stay below 60.
            if index > 0, value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return seconds > 0 ? seconds : nil
    }
}

// MARK: - Reading a Date's Characters

/// Reads a date's digits and separators from left to right.
private struct DigitReader {
    /// The characters of the text being read.
    private let characters: [Character]
    /// Where reading has got to.
    private var position = 0

    /// A reader at the start of `text`.
    init(_ text: String) {
        characters = Array(text)
    }

    /// Whether every character has been read.
    var isAtEnd: Bool { position >= characters.count }

    /// What is left to read.
    var rest: String { String(characters[min(position, characters.count)...]) }

    /// Reads exactly `digits` ASCII digits as a number.
    mutating func number(digits: Int) -> Int? {
        guard position + digits <= characters.count else { return nil }
        let run = characters[position..<position + digits]
        guard run.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(String(run)) else { return nil }
        position += digits
        return value
    }

    /// Reads one or more ASCII digits, as text.
    mutating func digitRun() -> String? {
        let start = position
        while position < characters.count, characters[position].isASCII, characters[position].isNumber {
            position += 1
        }
        return position > start ? String(characters[start..<position]) : nil
    }

    /// Reads `character` when it comes next.
    mutating func skip(_ character: Character) -> Bool {
        guard position < characters.count, characters[position] == character else { return false }
        position += 1
        return true
    }

    /// Reads the next character when `matches` accepts it.
    mutating func next(where matches: (Character) -> Bool) -> Character? {
        guard position < characters.count, matches(characters[position]) else { return nil }
        position += 1
        return characters[position - 1]
    }

    /// Reads any spaces that come next.
    mutating func skipSpaces() {
        while position < characters.count, characters[position] == " " {
            position += 1
        }
    }

    /// Reads everything left.
    mutating func skipToEnd() {
        position = characters.count
    }
}
