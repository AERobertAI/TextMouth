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
        // A noun that needs no agreement, as the feed downloads' "done".
        XCTAssertEqual(CountWording.progress(3, of: 9, "done"), "3 of 9 done")
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
        XCTAssertEqual(CountWording.secondsToTheTenth(.nan), "nan seconds")
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
}
