import Foundation

/// Counted words in what TextMouth shows and speaks: "0 books", "1 book",
/// "2 books" (TODO Q08).
///
/// Visible text, VoiceOver labels, and messages each used to spell out the
/// same choice between singular and plural wherever they counted something.
/// They now share these functions, so every count follows one rule, and the
/// words on screen agree with the words VoiceOver speaks.
enum CountWording {
    /// A noun as a count says it: `singular` after exactly one, `plural`
    /// after every other count, as in "1 book processed" and "3 books
    /// processed". A progress overlay is given the noun it counts its
    /// items by this way.
    struct Noun: Equatable, Sendable {
        /// The words after a count of exactly one.
        let singular: String
        /// The words after every other count.
        let plural: String
    }

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

    /// `count` bookmarks: "1 bookmark", "2 bookmarks", as Speak Info and a
    /// feed's item row say them.
    static func bookmarks(_ count: Int) -> String {
        phrase(count, singular: "bookmark", plural: "bookmarks")
    }

    /// `count` minutes: "1 minute", "30 minutes", as the sleep timer and
    /// spoken durations count them.
    static func minutes(_ count: Int) -> String {
        phrase(count, singular: "minute", plural: "minutes")
    }

    /// `count` seconds: "1 second", "5 seconds".
    static func seconds(_ count: Int) -> String {
        phrase(count, singular: "second", plural: "seconds")
    }

    /// `part` of `whole` things, the noun agreeing with the whole, which it
    /// counts: "0 of 1 book", "1 of 1 book", "2 of 5 books", as the
    /// Library's edit bar counts the books selected (TODO A10; it said "0 of
    /// 1 books").
    static func part(_ part: Int, of whole: Int, singular: String, plural: String) -> String {
        "\(part) of \(phrase(whole, singular: singular, plural: plural))"
    }

    /// `part` of `whole` things named by `noun`, which agrees with the
    /// whole: "0 of 1 book processed", "3 of 10 books processed", as the
    /// import overlay and the text cache's overlay count their books (REV13;
    /// they said "0 of 1 books processed").
    static func part(_ part: Int, of whole: Int, _ noun: Noun) -> String {
        self.part(part, of: whole, singular: noun.singular, plural: noun.plural)
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
        listItems(books: bookCount, feeds: feedCount)
    }

    /// The books of a list and the episodes and articles it shows beside
    /// them, each by its own noun, then the feeds, as Recently Opened and
    /// the Reading List count them, which list feed items beside books
    /// (FR11): "2 books, 5 episodes", "1 book, 2 episodes, 1 article", "3
    /// episodes". Each count of nothing is left out, and "0 books" is said
    /// where there is nothing at all, as `booksAndFeeds(books:feeds:)`, which
    /// is this without feed items, says it. The screen and VoiceOver say the
    /// same words.
    static func listItems(books bookCount: Int, episodes: Int = 0, articles: Int = 0, feeds feedCount: Int = 0) -> String {
        var parts: [String] = []
        if bookCount > 0 || episodes + articles + feedCount == 0 {
            parts.append(books(bookCount))
        }
        if episodes > 0 {
            parts.append(phrase(episodes, singular: "episode", plural: "episodes"))
        }
        if articles > 0 {
            parts.append(phrase(articles, singular: "article", plural: "articles"))
        }
        if feedCount > 0 {
            parts.append(feeds(feedCount))
        }
        return parts.joined(separator: ", ")
    }

    /// The books, episodes, and articles among `rows`, with `feeds` feeds,
    /// as `listItems(books:episodes:articles:feeds:)` says them: a feed
    /// item is an episode when it is audio and an article otherwise, and
    /// every other row is a book.
    static func listItems(of rows: [Book], feeds feedCount: Int = 0) -> String {
        let counts = ListCounts(rows)
        return listItems(books: counts.books, episodes: counts.episodes, articles: counts.articles, feeds: feedCount)
    }

    /// The header of the section listing `rows`: "Books (743)", or, where
    /// episodes and articles are listed beside the books, as in Recently
    /// Opened and the Reading List (FR11), each kind under its own name, so
    /// no episode is counted as a book: "Books (2), Episodes (5)",
    /// "Episodes (3), Articles (1)". A list of nothing is "Books (0)".
    static func booksHeader(of rows: [Book]) -> String {
        let counts = ListCounts(rows)
        var parts: [String] = []
        if counts.books > 0 || counts.episodes + counts.articles == 0 {
            parts.append("Books (\(counts.books))")
        }
        if counts.episodes > 0 {
            parts.append("Episodes (\(counts.episodes))")
        }
        if counts.articles > 0 {
            parts.append("Articles (\(counts.articles))")
        }
        return parts.joined(separator: ", ")
    }

    /// How many of a list's rows are books of the library's own, episodes,
    /// and articles (FR11).
    private struct ListCounts {
        /// Rows of the library's own books.
        var books = 0
        /// Feed items whose format is audio.
        var episodes = 0
        /// Every other feed item.
        var articles = 0

        /// The counts of `rows`.
        init(_ rows: [Book]) {
            for row in rows {
                if !row.isFeedItem {
                    books += 1
                } else if row.format.isAudio {
                    episodes += 1
                } else {
                    articles += 1
                }
            }
        }
    }

    /// How far a batch has got: `done` of `total`, then `noun` as it is,
    /// whatever the total: "3 of 9 done", as the feed downloads section's
    /// count says it (FR10). A noun that must agree with the total, as the
    /// progress overlays' books do, is counted by `part(_:of:_:)` instead.
    static func progress(_ done: Int, of total: Int, _ noun: String) -> String {
        "\(done) of \(total) \(noun)"
    }
}
