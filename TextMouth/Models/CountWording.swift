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

    /// `count` feeds: "1 feed", "2 feeds".
    static func feeds(_ count: Int) -> String {
        phrase(count, singular: "feed", plural: "feeds")
    }

    /// The library's books and the feeds beside them, as the library counts
    /// them wherever it counts its books (FR11): "743 books, 2 feeds", "1
    /// book, 1 feed". A feed's episodes and articles are never counted as
    /// books; their feed is counted instead. The feeds are left out where
    /// there are none ("743 books"), and the books where there are feeds and
    /// no books ("2 feeds"), so nothing is said of a count of nothing but
    /// "0 books" where there is neither. The screen and VoiceOver say the
    /// same words.
    static func booksAndFeeds(books bookCount: Int, feeds feedCount: Int) -> String {
        guard feedCount > 0 else { return books(bookCount) }
        guard bookCount > 0 else { return feeds(feedCount) }
        return "\(books(bookCount)), \(feeds(feedCount))"
    }

    /// How far a batch has got: `done` of `total`, then `noun`, as in "3 of
    /// 10 books processed". The noun counts the total, so it is the plural
    /// whatever `done` is. A progress overlay's count says it, and VoiceOver
    /// reads it the same way (FR10).
    static func progress(_ done: Int, of total: Int, _ noun: String) -> String {
        "\(done) of \(total) \(noun)"
    }
}
