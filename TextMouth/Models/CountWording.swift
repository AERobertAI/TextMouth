import Foundation

/// Counted words in what TextMouth shows and speaks: "0 books", "1 book",
/// "2 books" (TODO Q08).
///
/// Visible text, VoiceOver labels, and messages each used to spell out the
/// same choice between singular and plural wherever they counted something.
/// They now share these functions, so every count follows one rule, and the
/// words on screen agree with the words VoiceOver speaks.
enum CountWording {
    /// `count` followed by the words for that many: `singular` for exactly
    /// one and `plural` for every other count, zero included, as in "0 days",
    /// "1 day", "2 days". The words may include a verb that agrees with the
    /// count, as in "1 book has" and "2 books have".
    static func phrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// `count` books: "0 books", "1 book", "2 books".
    static func books(_ count: Int) -> String {
        phrase(count, singular: "book", plural: "books")
    }
}
