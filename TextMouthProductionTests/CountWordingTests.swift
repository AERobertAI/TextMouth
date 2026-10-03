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
}
