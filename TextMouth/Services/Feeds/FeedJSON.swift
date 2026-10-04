import Foundation

// MARK: - Reading JSON From the Web (FR03)

/// Reads the JSON documents the feed reader fetches (FR03), such as the
/// podcast directory's answers.
///
/// They come from servers TextMouth does not control, so each field is read
/// on its own: one that is missing, or of a type other than the one
/// expected, reads as absent instead of failing the whole document, as
/// decoding into a `Decodable` type would. A number written as a string
/// ("1780") still reads as a number.
enum FeedJSON {
    /// The object `data` holds at its top level, or nil when it holds none,
    /// such as a web page or a JSON array.
    static func object(in data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `value` as text: a string holding something besides white space,
    /// trimmed; nil for anything else.
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `value` as a number: a JSON number, or a string holding one; nil for
    /// anything else, a true or false among them.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            // JSONSerialization reads true and false as numbers too.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        return string(value).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    /// `value` as a whole number, any fraction dropped; nil for anything
    /// that is no number, or too large to hold.
    static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number > Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }

    /// The objects in the array `value`, skipping anything else it holds;
    /// none when `value` is no array.
    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}
