import XCTest
@testable import TextMouth

/// A time typed or pasted into one field is read as people write it
/// (`TimeEntry`): the audio editor's Go to Time and its length of silence
/// read it, and the reader's Go to Time reads it too (P08). Pure: no window,
/// no audio.
final class TimeEntryTests: XCTestCase {

    /// Times are read as people type them: seconds alone, minutes and
    /// seconds, or hours, minutes, and seconds, spaces ignored.
    func testTimesAreReadAsPeopleTypeThem() {
        XCTAssertEqual(TimeEntry.reading("75.5"), .seconds(75.5))
        XCTAssertEqual(TimeEntry.reading("12:04.3"), .seconds(724.3))
        XCTAssertEqual(TimeEntry.reading(" 1 : 02 : 03 "), .seconds(3_723))
        XCTAssertEqual(TimeEntry.reading("0:05"), .seconds(5))
        XCTAssertEqual(TimeEntry.reading("1:60"), .problem("Seconds must be less than 60."))
        XCTAssertEqual(TimeEntry.reading("1:60:00"), .problem("Minutes must be less than 60."))
        for text in ["", "  ", "-5", "1e3", ":5", "12:", "1.5:00", "a:b", "1:2:3:4", "."] {
            XCTAssertEqual(TimeEntry.reading(text), .problem(TimeEntry.howToType), text)
        }
    }

    /// The forms P08's Go to Time promises, as a time is shown, spoken, or
    /// pasted: "1:02:03", "62:03", and "3723" all name an hour, two minutes,
    /// and three seconds, and "12:04.3" keeps its tenth; the status row's
    /// "2:13:05", its minutes alone ("133:05"), its seconds alone ("7985"),
    /// and a time with a tenth ("2:13:05.4") all name the same place.
    func testTheFormsGoToTimePromisesAreRead() throws {
        for text in ["1:02:03", "62:03", "3723", "01:02:03"] {
            XCTAssertEqual(try seconds(text), 3_723, accuracy: 1e-9, text)
        }
        XCTAssertEqual(try seconds("12:04.3"), 724.3, accuracy: 1e-9)
        for text in ["2:13:05", "133:05", "7985"] {
            XCTAssertEqual(try seconds(text), 7_985, accuracy: 1e-9, text)
        }
        XCTAssertEqual(try seconds("2:13:05.4"), 7_985.4, accuracy: 1e-9)
        // Minutes after hours are under 60, as a clock shows them.
        XCTAssertEqual(TimeEntry.reading("0:62:03"), .problem(TimeEntry.minutesTooLarge))
    }

    /// Hours may be any whole number, the first part of a time may be as
    /// large as it likes, and a number of hours too large for an integer is
    /// refused rather than trapping; the caller compares what is read with
    /// the length of what it names a place in.
    func testLargeTimesAreReadWithoutTrapping() throws {
        XCTAssertEqual(try seconds("100:00:00"), 360_000, accuracy: 1e-9)
        XCTAssertEqual(try seconds("90:00"), 5_400, accuracy: 1e-9)
        XCTAssertEqual(TimeEntry.reading("99999999999999999999999:00:00"), .problem(TimeEntry.howToType))
        XCTAssertEqual(try seconds("9999999999:00:00"), 9_999_999_999 * 3_600, accuracy: 1)
    }

    /// Every sentence is a constant, pinned word for word.
    func testTheSentencesAreFixed() {
        XCTAssertEqual(TimeEntry.howToType, "Type a time, such as 12:04.3, 1:02:03, or 75.5.")
        XCTAssertEqual(TimeEntry.secondsTooLarge, "Seconds must be less than 60.")
        XCTAssertEqual(TimeEntry.minutesTooLarge, "Minutes must be less than 60.")
    }

    // MARK: - Helpers

    /// The seconds `text` is read as; throws, failing the assertion that
    /// asked, when it is refused.
    private func seconds(_ text: String) throws -> TimeInterval {
        let reading = TimeEntry.reading(text)
        guard case .seconds(let value) = reading else {
            throw Refused(text: text, reading: reading)
        }
        return value
    }

    /// A time that was refused, named in the failure.
    private struct Refused: Error, CustomStringConvertible {
        let text: String
        let reading: TimeEntry
        var description: String { "\"\(text)\" was refused: \(reading)" }
    }
}
