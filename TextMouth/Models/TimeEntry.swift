import Foundation

/// Reads a time typed or pasted into one text field, as people write it:
/// the audio editor's Go to Time and its length of silence to insert (FR04),
/// and the reader's Go to Time (P08, `JumpInputValidator.time`). One plain
/// text field takes the whole time, so VoiceOver reads it as the edit text
/// it is, and a time copied from anywhere goes in with one paste.
enum TimeEntry: Equatable {
    /// The time typed, in seconds.
    case seconds(TimeInterval)
    /// What is wrong with what was typed, as a sentence.
    case problem(String)

    /// What a field holding nothing, or something that isn't a time, says.
    static let howToType = "Type a time, such as 12:04.3, 1:02:03, or 75.5."

    /// What a time whose seconds, after minutes or hours, reach 60 says.
    static let secondsTooLarge = "Seconds must be less than 60."

    /// What a time whose minutes, after hours, reach 60 says.
    static let minutesTooLarge = "Minutes must be less than 60."

    /// The time `text` names: seconds alone ("75.5", "3723"), minutes and
    /// seconds ("12:04.3", "62:03"), or hours, minutes, and seconds
    /// ("1:02:03"), spaces ignored. Only the seconds may have a fraction;
    /// minutes and seconds after a larger part are under 60, while the first
    /// part may be as large as it likes ("62:03" is 62 minutes, 3 seconds).
    static func reading(_ text: String) -> TimeEntry {
        let compact = text.filter { !$0.isWhitespace }
        let parts = compact.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !compact.isEmpty, (1...3).contains(parts.count), let last = parts.last,
              let seconds = Double(last), seconds.isFinite, seconds >= 0,
              last.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            return .problem(howToType)
        }
        // Every part before the seconds is a whole number.
        var larger: [Int] = []
        for part in parts.dropLast() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else {
                return .problem(howToType)
            }
            larger.append(value)
        }
        if !larger.isEmpty, seconds >= 60 {
            return .problem(secondsTooLarge)
        }
        if larger.count == 2, larger[1] >= 60 {
            return .problem(minutesTooLarge)
        }
        // Hours and minutes are converted before they are multiplied, so a
        // huge number of hours can't overflow; the caller checks the time
        // against the length of whatever it names a place in.
        let total = larger.reduce(0.0) { $0 * 60 + Double($1) } * 60 + seconds
        guard total.isFinite else { return .problem(howToType) }
        return .seconds(total)
    }
}
