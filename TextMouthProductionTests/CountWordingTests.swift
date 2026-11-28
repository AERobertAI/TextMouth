import XCTest
@testable import TextMouth

/// The one rule for counted words in what TextMouth shows and speaks
/// (TODO Q08): exactly one takes the singular, and every other count the
/// plural. The helper replaced the inline copies of that choice in the
/// library, reader, settings, and message wording, so these tests pin the
/// rule they all followed, and add the plural duration units that had no
/// test of their own.
final class CountWordingTests: XCTestCase {
    /// Exactly one takes the singular. Zero, several, and even a negative
    /// count take the plural, and large counts are written without digit
    /// grouping, all as the inline copies wrote them.
    func testOnlyExactlyOneTakesTheSingular() {
        XCTAssertEqual(CountWording.phrase(0, singular: "day", plural: "days"), "0 days")
        XCTAssertEqual(CountWording.phrase(1, singular: "day", plural: "days"), "1 day")
        XCTAssertEqual(CountWording.phrase(2, singular: "day", plural: "days"), "2 days")
        XCTAssertEqual(CountWording.phrase(1_000, singular: "day", plural: "days"), "1000 days")
        XCTAssertEqual(CountWording.phrase(-1, singular: "day", plural: "days"), "-1 days")
    }

    /// The words may include a verb, which then agrees with the count, as
    /// in the library's "not been opened yet" summary.
    func testWordsMayIncludeAVerbThatAgrees() {
        XCTAssertEqual(CountWording.phrase(1, singular: "book has", plural: "books have"), "1 book has")
        XCTAssertEqual(CountWording.phrase(4, singular: "book has", plural: "books have"), "4 books have")
    }

    /// Books, the thing TextMouth counts most often, have a shorthand.
    func testBooks() {
        XCTAssertEqual(CountWording.books(0), "0 books")
        XCTAssertEqual(CountWording.books(1), "1 book")
        XCTAssertEqual(CountWording.books(3), "3 books")
    }

    /// Spoken durations count each unit by the same rule. Singular units
    /// and seconds are tested in `LegacyDocumentAndAccessibilityTests`;
    /// plural hours and minutes were not.
    func testSpokenDurationsCountEachUnit() {
        XCTAssertEqual(TimeFormatting.spoken(7_384), "2 hours, 3 minutes, 4 seconds")
        XCTAssertEqual(TimeFormatting.spoken(3_600), "1 hour")
        XCTAssertEqual(TimeFormatting.spoken(120), "2 minutes")
    }

    /// Hours have a shorthand of their own, which spoken durations and the
    /// audio editor's lengths count by, as minutes and seconds have.
    func testHours() {
        XCTAssertEqual(CountWording.hours(0), "0 hours")
        XCTAssertEqual(CountWording.hours(1), "1 hour")
        XCTAssertEqual(CountWording.hours(2), "2 hours")
        XCTAssertEqual(AudioEditWording.duration(3_725), "1 hour, 2 minutes, 5 seconds")
        XCTAssertEqual(AudioEditWording.duration(7_260, titleCase: true), "2 Hours, 1 Minute")
    }

    /// A part of a whole counts its noun by the whole: "0 of 1 book
    /// processed", as the import overlay and the text cache's overlay
    /// count their books, where they said "0 of 1 books processed".
    func testAPartsNounAgreesWithTheWhole() {
        let noun = CountWording.Noun(singular: "book processed", plural: "books processed")
        XCTAssertEqual(CountWording.part(0, of: 1, noun), "0 of 1 book processed")
        XCTAssertEqual(CountWording.part(1, of: 1, noun), "1 of 1 book processed")
        XCTAssertEqual(CountWording.part(3, of: 10, noun), "3 of 10 books processed")
        XCTAssertEqual(CountWording.part(0, of: 0, noun), "0 of 0 books processed")
        // A noun that needs no agreement, as the feed downloads' "done",
        // is its own plural (`FeedDownloadProgressWording.count`).
        XCTAssertEqual(CountWording.part(3, of: 9, singular: "done", plural: "done"), "3 of 9 done")
        XCTAssertEqual(CountWording.part(1, of: 1, singular: "done", plural: "done"), "1 of 1 done")
        XCTAssertEqual(FeedDownloadProgressWording.count(done: 3, of: 9, failed: 1), "3 of 9 done, 1 failed")
    }

    /// Seconds kept in tenths are said to the nearest tenth, the same on
    /// the Shortcuts tab (the double press time) and the Miscellaneous tab
    /// (the gesture's time window), which each worded them with a function
    /// of their own (board #1552): whole seconds counted, tenths as a
    /// decimal, and a value just off a tenth, as arithmetic leaves one,
    /// rounded to it.
    func testSecondsKeptInTenthsAreSaidToTheTenth() {
        let said: [(Double, String)] = [
            (0.5, "0.5 seconds"), (0.2, "0.2 seconds"), (1, "1 second"), (2, "2 seconds"), (1.5, "1.5 seconds"),
            (10, "10 seconds"), (0.30000000000000004, "0.3 seconds"), (0.7999999999999999, "0.8 seconds"),
            (2.96, "3 seconds"), (0.04, "0 seconds"),
        ]
        for (seconds, words) in said {
            XCTAssertEqual(CountWording.secondsToTheTenth(seconds), words, "\(seconds)")
        }
        // A value no setting holds is written, never trapped on.
        XCTAssertTrue(CountWording.secondsToTheTenth(.nan).hasSuffix(" seconds"))
        XCTAssertFalse(CountWording.secondsToTheTenth(.infinity).isEmpty)
        XCTAssertFalse(CountWording.secondsToTheTenth(1e300).isEmpty)
    }

    // MARK: - Shown and Spoken Alike

    /// The Bluetooth disconnect delay reads the same on screen and to
    /// VoiceOver, which used to hear "1 seconds" beside "1 second".
    func testDisconnectDelaySpeaksTheCountItShows() {
        XCTAssertEqual(MiscellaneousSettingsView.disconnectDelayPhrase(1), "1 second")
        XCTAssertEqual(MiscellaneousSettingsView.disconnectDelayPhrase(5), "5 seconds")
        XCTAssertEqual(MiscellaneousSettingsView.disconnectDelayPhrase(10), "10 seconds")
    }

    // MARK: - Lists

    /// The one list joiner words a list as a sentence does, and says nothing
    /// for no items, which each caller words for itself.
    func testListJoinsItemsAsASentenceListsThem() {
        // The list follows the region (FR34), so the serial comma is pinned
        // to en_US here and the other regions are checked below.
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(CountWording.list([], locale: us), "")
        XCTAssertEqual(CountWording.list(["A"], locale: us), "A")
        XCTAssertEqual(CountWording.list(["A", "B"], locale: us), "A and B")
        XCTAssertEqual(CountWording.list(["A", "B", "C"], locale: us), "A, B, and C")
        XCTAssertEqual(CountWording.list(["A", "B", "C", "D"], locale: us), "A, B, C, and D")
    }

    /// A list is worded by the region's own rules: British English drops the
    /// serial comma and Spanish says "y".
    func testListFollowsTheRegion() {
        XCTAssertEqual(CountWording.list(["A", "B", "C"], locale: Locale(identifier: "en_GB")), "A, B and C")
        XCTAssertEqual(CountWording.list(["A", "B", "C"], locale: Locale(identifier: "es_ES")), "A, B y C")
        XCTAssertEqual(CountWording.list(["A", "B"], locale: Locale(identifier: "es_ES")), "A y B")
    }

    // MARK: - Localized Counts

    /// A count is formatted for the region, as a localized count should be
    /// ("1,000 books" in en_US), where it used to be written without grouping.
    func testCountsAreGroupedForTheRegion() {
        let grouped = 1_000.formatted()
        XCTAssertEqual(CountWording.books(1_000), "\(grouped) books")
        XCTAssertEqual(CountWording.feeds(1_000), "\(grouped) feeds")
        XCTAssertEqual(CountWording.bookmarks(1_001), "\(1_001.formatted()) bookmarks")
        XCTAssertEqual(CountWording.minutes(1_000), "\(grouped) minutes")
        // Below a thousand nothing is grouped, so the shorthand stays as it was.
        XCTAssertEqual(CountWording.books(999), "999 books")
    }

    /// Every named count has its English one and other forms in the catalog,
    /// so exactly one takes the singular.
    func testEveryNamedCountHasItsEnglishPluralForms() {
        let counts: [(Int) -> String] = [
            CountWording.books, CountWording.feeds, CountWording.bookmarks, CountWording.hours,
            CountWording.minutes, CountWording.seconds, CountWording.episodes, CountWording.articles,
        ]
        let nouns = ["book", "feed", "bookmark", "hour", "minute", "second", "episode", "article"]
        for (count, noun) in zip(counts, nouns) {
            XCTAssertEqual(count(1), "1 \(noun)")
            XCTAssertEqual(count(0), "0 \(noun)s")
            XCTAssertEqual(count(2), "2 \(noun)s")
        }
    }

    /// A list of counts reads as a short run, with no "and", where each kind
    /// keeps its own noun.
    func testListsOfCountsAreShortRuns() {
        XCTAssertEqual(CountWording.listItems(books: 2, episodes: 5, articles: 1, feeds: 1), "2 books, 5 episodes, 1 article, 1 feed")
        XCTAssertEqual(CountWording.booksAndFeeds(books: 743, feeds: 2), "743 books, 2 feeds")
        XCTAssertEqual(CountWording.listItems(books: 0), "0 books")
    }

    /// Whole seconds are counted as every count is; a decimal is written
    /// with the region's decimal separator.
    func testTenthsOfASecondUseTheRegionsDecimalSeparator() {
        let half = 0.5.formatted(.number.precision(.fractionLength(1)))
        XCTAssertEqual(CountWording.secondsToTheTenth(0.5), "\(half) seconds")
        XCTAssertEqual(CountWording.secondsToTheTenth(3), CountWording.seconds(3))
    }
}
