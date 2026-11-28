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

    /// `count` seconds in English whatever the interface language, "1 second"
    /// and "62 seconds", for text that goes into the debug log, which stays
    /// English (`WatchedProcess.KillReason.words`). Never shown to a listener
    /// by itself; the localized `seconds(_:)` is the one to show.
    static func englishSeconds(_ count: Int) -> String {
        phrase(count, singular: "second", plural: "seconds") // l10n: no (debug log text, which stays English)
    }

    // MARK: - Named Counts

    // Each named count is one localized string with its English plural
    // forms in the catalog (`l10n.py plural`), so every language counts by
    // its own rules. The number is formatted for the region ("1,000 books"),
    // as a count should be.

    /// `count` books: "0 books", "1 book", "2 books".
    static func books(_ count: Int) -> String {
        // Translators: A count of books standing alone, such as a library summary. %lld is the number of books.
        InterfaceText.line("common.countBooks", "\(number: count) books")
    }

    /// `count` feeds: "1 feed", "2 feeds".
    static func feeds(_ count: Int) -> String {
        // Translators: A count of podcast and news feeds standing alone, such as a library summary. %lld is the number of feeds.
        InterfaceText.line("count.feeds", "\(number: count) feeds")
    }

    /// `count` bookmarks: "1 bookmark", "2 bookmarks", as Speak Info and a
    /// feed's item row say them.
    static func bookmarks(_ count: Int) -> String {
        // Translators: A count of bookmarks standing alone, as Speak Info and a feed item's row say it. %lld is the number of bookmarks.
        InterfaceText.line("count.bookmarks", "\(number: count) bookmarks")
    }

    /// `count` hours: "1 hour", "2 hours", as spoken durations and the
    /// audio editor's lengths count them.
    static func hours(_ count: Int) -> String {
        // Translators: A count of hours inside a duration, such as "2 hours, 3 minutes". %lld is the number of hours.
        InterfaceText.line("count.hours", "\(number: count) hours")
    }

    /// `count` minutes: "1 minute", "30 minutes", as the sleep timer and
    /// spoken durations count them.
    static func minutes(_ count: Int) -> String {
        // Translators: A sleep timer's length, as its preset button and the custom minutes' value say it, such as "10 minutes". %lld is the number of minutes.
        InterfaceText.line("common.countMinutes", "\(number: count) minutes")
    }

    /// `count` seconds: "1 second", "5 seconds".
    static func seconds(_ count: Int) -> String {
        // Translators: A count of whole seconds inside a duration or a setting's length. %lld is the number of seconds.
        InterfaceText.line("count.seconds", "\(number: count) seconds")
    }

    /// `count` episodes: "1 episode", "5 episodes", as a list of audio feed
    /// items counts them beside its books.
    static func episodes(_ count: Int) -> String {
        // Translators: A count of podcast episodes in a list, counted beside books. %lld is the number of episodes.
        InterfaceText.line("count.episodes", "\(number: count) episodes")
    }

    /// `count` articles: "1 article", "2 articles", as a list of text feed
    /// items counts them beside its books.
    static func articles(_ count: Int) -> String {
        // Translators: A count of news articles in a list, counted beside books. %lld is the number of articles.
        InterfaceText.line("count.articles", "\(number: count) articles")
    }

    /// `value` seconds to the nearest tenth, as a setting kept in tenths of
    /// a second says it on screen and to VoiceOver alike: whole seconds
    /// counted as `seconds(_:)` counts them, "1 second" and "2 seconds",
    /// and tenths as a decimal, "0.5 seconds" and "1.5 seconds". The
    /// Miscellaneous tab's gesture time window and the Shortcuts tab's
    /// double press time both say their times this way (board #1552). The
    /// decimal follows the region's number format ("0,5" in Spain).
    static func secondsToTheTenth(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        // Whole seconds that a whole number can hold are counted; any other
        // value, one no setting holds included, is written as a decimal,
        // which never traps.
        if tenths.truncatingRemainder(dividingBy: 10) == 0, let whole = Int(exactly: tenths / 10) {
            return seconds(whole)
        }
        // A decimal has no plural form that varies with it, so it is one
        // string of its own around the formatted number.
        let decimal = (tenths / 10).formatted(.number.precision(.fractionLength(1)).locale(InterfaceLanguage.current.locale))
        // Translators: A length of time in seconds with one decimal digit, such as "0.5 seconds". %@ is the already formatted number.
        return InterfaceText.line("common.valueSeconds", "\(decimal) seconds")
    }

    /// `part` of `whole` things, the noun agreeing with the whole, which it
    /// counts: "0 of 1 book", "1 of 1 book", "2 of 5 books", as the
    /// Library's edit bar counts the books selected (TODO A10; it said "0 of
    /// 1 books").
    static func part(_ part: Int, of whole: Int, singular: String, plural: String) -> String {
        "\(part) of \(phrase(whole, singular: singular, plural: plural))" // l10n: no (a plural that agrees with the second number waits for TL14; each caller's wave rewrites its sentence)
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
            parts.append(Self.episodes(episodes))
        }
        if articles > 0 {
            parts.append(Self.articles(articles))
        }
        if feedCount > 0 {
            parts.append(feeds(feedCount))
        }
        return joinedCounts(parts)
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
            // Translators: The header of a list's books, with their count: "Books (743)". %lld is the number of books.
            parts.append(InterfaceText.line("common.booksCount", "Books (\(number: counts.books))"))
        }
        if counts.episodes > 0 {
            // Translators: The header of a list's podcast episodes, with their count: "Episodes (5)". %lld is the number of episodes.
            parts.append(InterfaceText.line("common.episodesCount", "Episodes (\(number: counts.episodes))"))
        }
        if counts.articles > 0 {
            // Translators: The header of a list's news articles, with their count: "Articles (3)". %lld is the number of articles.
            parts.append(InterfaceText.line("common.articlesCount", "Articles (\(number: counts.articles))"))
        }
        return joinedCounts(parts)
    }

    /// Counts joined as a short run of figures reads in the region's
    /// language, as a narrow list: "743 books, 2 feeds", "2 books, 5
    /// episodes, 1 article" in English, where a sentence's "and" would only
    /// slow VoiceOver and braille down. Each count is already localized.
    static func joinedCounts(_ counts: [String]) -> String {
        counts.formatted(.list(type: .and, width: .narrow).locale(InterfaceLanguage.current.locale))
    }

    /// How many of a list's rows are books of the library's own, episodes,
    /// and articles (FR11), told apart as a Library view tells them apart
    /// (`Book.listedKind`).
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
                switch row.listedKind {
                case .books:
                    books += 1
                case .episodes:
                    episodes += 1
                case .articles:
                    articles += 1
                case .feeds:
                    // Only a feed's own row is a feed, never a book's.
                    break
                }
            }
        }
    }

    // MARK: - Lists

    /// `items` joined as a sentence lists them, "A", "A and B", "A, B, and C"
    /// in en_US, the same in what TextMouth shows and what VoiceOver speaks;
    /// empty for no items, which each caller words for itself. The region's
    /// list style decides the commas and the word for "and", so en_GB writes
    /// "A, B and C" and Spanish "A, B y C". `locale` is the region whose
    /// style is used, the user's own unless a test names another.
    static func list(_ items: [String], locale: Locale = InterfaceLanguage.current.locale) -> String {
        items.formatted(.list(type: .and).locale(locale))
    }
}
