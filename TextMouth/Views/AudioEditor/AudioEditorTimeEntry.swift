import Foundation

/// Reads a time typed into one of the audio editor's fields (FR04): Go to
/// Time's place, and the length of silence to insert. One plain text field
/// takes the whole time, as people write it, so VoiceOver reads it as the
/// edit text it is.
enum AudioEditorTimeEntry: Equatable {
    /// The time typed, in seconds.
    case seconds(TimeInterval)
    /// What is wrong with what was typed, as a sentence.
    case problem(String)

    /// What a field holding nothing, or something that isn't a time, says.
    static let howToType = "Type a time, such as 12:04.3, 1:02:03, or 75.5."

    /// The time `text` names: seconds alone ("75.5"), minutes and seconds
    /// ("12:04.3"), or hours, minutes, and seconds ("1:02:03"), spaces
    /// ignored. Only the seconds may have a fraction; minutes and seconds
    /// after a larger part are under 60.
    static func reading(_ text: String) -> AudioEditorTimeEntry {
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
            return .problem("Seconds must be less than 60.")
        }
        if larger.count == 2, larger[1] >= 60 {
            return .problem("Minutes must be less than 60.")
        }
        // Hours and minutes are converted before they are multiplied, so a
        // huge number of hours can't overflow; the caller checks the time
        // against the audio's length.
        let total = larger.reduce(0.0) { $0 * 60 + Double($1) } * 60 + seconds
        guard total.isFinite else { return .problem(howToType) }
        return .seconds(total)
    }
}
