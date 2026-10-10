import Foundation
import XCTest
@testable import TextMouth

// The reader's text area (TODO A11): the window of a long chapter's text it
// shows, which holds the reading position and begins and ends on whole
// words, and what VoiceOver and a braille display read there.

// MARK: - The Window's Edges

/// Where the window of a long chapter's text is cut
/// (`VisibleTextWindowPolicy.bounds(in:around:maximumLength:)`): around the
/// reading position, and on whole words.
final class VisibleTextWindowBoundsTests: XCTestCase {
    /// The longest window these tests cut, short enough for texts of a few
    /// thousand characters.
    private let limit = 400

    /// A text no longer than the limit is shown whole, wherever the reading
    /// position is.
    func testATextWithinTheLimitIsShownWhole() {
        let text = "Short enough to show whole.\n\nIt has two paragraphs."
        for offset in [0, 9, text.utf16.count] {
            XCTAssertEqual(
                VisibleTextWindowPolicy.bounds(in: text, around: offset, maximumLength: limit),
                0..<text.utf16.count,
                "offset \(offset)"
            )
        }
    }

    /// In paragraphs set apart by blank lines, the window keeps whole
    /// paragraphs around the reading position: it begins just after a blank
    /// line and ends just before one.
    func testParagraphsAreKeptWhole() {
        let text = ReaderTextFixtures.paragraphs(count: 40)
        let offset = text.utf16.count / 2

        let window = VisibleTextWindowPolicy.bounds(in: text, around: offset, maximumLength: limit)

        XCTAssertTrue(window.lowerBound <= offset && offset <= window.upperBound, "\(window) around \(offset)")
        XCTAssertEqual(ReaderTextFixtures.text(text, in: (window.lowerBound - 2)..<window.lowerBound), "\n\n")
        XCTAssertEqual(ReaderTextFixtures.text(text, in: window.upperBound..<(window.upperBound + 2)), "\n\n")
        XCTAssertTrue(ReaderTextFixtures.text(text, in: window).hasPrefix("Paragraph "))
    }

    /// Paragraphs ended by single line breaks, with one blank line just
    /// before the place the window's end is cut: the window was the twelve
    /// characters after that blank line, "Where did th", all after the
    /// reading position, a fragment like the one the user met (TODO A11).
    /// Now it holds the reading position, begins at a line, and ends at the
    /// blank line.
    func testOneBlankLineNearTheCutNoLongerLeavesAFragment() {
        let fixture = ReaderTextFixtures.blankLineNearTheCut(limit: limit)

        let window = VisibleTextWindowPolicy.bounds(in: fixture.text, around: fixture.offset, maximumLength: limit)
        let shown = ReaderTextFixtures.text(fixture.text, in: window)

        XCTAssertTrue(window.lowerBound <= fixture.offset && fixture.offset <= window.upperBound, "\(window) around \(fixture.offset)")
        XCTAssertFalse(shown.contains("Where did th"), shown)
        XCTAssertTrue(shown.hasPrefix(ReaderTextFixtures.lineStart), shown)
        XCTAssertTrue(shown.hasSuffix(ReaderTextFixtures.lineEnd), shown)
        XCTAssertGreaterThanOrEqual(window.count, limit / 2)
    }

    /// Wherever the reading position is, in text set out in each of the
    /// ways books are, the window holds it, begins and ends between words,
    /// and is at least half and at most all of the limit long.
    func testEveryPositionIsShownBetweenWholeWords() {
        let texts: [(name: String, text: String)] = [
            ("paragraphs", ReaderTextFixtures.paragraphs(count: 40)),
            ("lines with a rare blank line", ReaderTextFixtures.blankLineNearTheCut(limit: limit).text),
            ("one long paragraph", String(repeating: "Words run on in one paragraph without a break. ", count: 60)),
            ("words beyond ASCII", String(repeating: "Café naïve 🙂 résumé “quoted” déjà vu. ", count: 60)),
        ]
        for (name, text) in texts {
            let length = text.utf16.count
            XCTAssertGreaterThan(length, limit, name)
            for offset in stride(from: 0, through: length, by: 7) {
                let window = VisibleTextWindowPolicy.bounds(in: text, around: offset, maximumLength: limit)
                let context = "\(name), offset \(offset), window \(window)"
                XCTAssertTrue(window.lowerBound <= offset && offset <= window.upperBound, context)
                XCTAssertTrue(ReaderTextFixtures.isBetweenWords(text, at: window.lowerBound), context)
                XCTAssertTrue(ReaderTextFixtures.isBetweenWords(text, at: window.upperBound), context)
                XCTAssertLessThanOrEqual(window.count, limit, context)
                XCTAssertGreaterThanOrEqual(window.count, limit / 2, context)
            }
        }
    }

    /// Near a chapter's start or end the window reaches that end, and only
    /// its other edge moves to a boundary.
    func testNearTheChaptersEndsOnlyTheInnerEdgeMoves() {
        let text = ReaderTextFixtures.paragraphs(count: 40)
        let length = text.utf16.count

        let first = VisibleTextWindowPolicy.bounds(in: text, around: 3, maximumLength: limit)
        XCTAssertEqual(first.lowerBound, 0)
        XCTAssertEqual(ReaderTextFixtures.text(text, in: first.upperBound..<(first.upperBound + 2)), "\n\n")

        let last = VisibleTextWindowPolicy.bounds(in: text, around: length, maximumLength: limit)
        XCTAssertEqual(last.upperBound, length)
        XCTAssertEqual(ReaderTextFixtures.text(text, in: (last.lowerBound - 2)..<last.lowerBound), "\n\n")
    }

    /// Text with no space to cut at, as in a language written without
    /// spaces, is cut where the window falls, at the full limit, still
    /// around the reading position.
    func testTextWithoutSpacesIsCutWhereTheWindowFalls() {
        let text = String(repeating: "字", count: 2_000)
        let offset = 1_000

        let window = VisibleTextWindowPolicy.bounds(in: text, around: offset, maximumLength: limit)

        XCTAssertEqual(window, (offset - limit / 2)..<(offset + limit / 2))
    }
}

// MARK: - The Reader's Window

/// The window the reader itself shows (`ReaderViewModel.displayVisibleTextWindow`),
/// cut from a chapter as long as the user's book's, around a reading
/// position as the reader restores one.
@MainActor
final class ReaderVisibleTextWindowTests: XCTestCase {
    /// The reader shows whole words around the reading position, not the
    /// fragment "Where did th" after it, in text whose one blank line falls
    /// just before the cut, at the reader's own limit (TODO A11).
    func testTheReaderShowsWholeWordsAroundThePosition() {
        let limit = ReaderViewModel.maxDisplayChars
        let fixture = ReaderTextFixtures.blankLineNearTheCut(limit: limit)
        let reader = ReaderTextFixtures.reader(showing: fixture.text)
        defer { reader.close() }

        reader.refreshPlaybackUI(chapterIndex: 0, offset: fixture.offset, forceVisibleTextRefresh: true)
        let shown = reader.displayVisibleTextWindow

        XCTAssertNotEqual(shown, "Where did th")
        XCTAssertFalse(shown.contains("Where did th"))
        XCTAssertTrue(shown.hasPrefix(ReaderTextFixtures.lineStart), String(shown.prefix(80)))
        XCTAssertTrue(shown.hasSuffix(ReaderTextFixtures.lineEnd), String(shown.suffix(80)))
        XCTAssertGreaterThanOrEqual(shown.utf16.count, limit / 2)
        XCTAssertLessThanOrEqual(shown.utf16.count, limit)
        // The line the reading position is in is shown.
        let lineAtPosition = ReaderTextFixtures.line(of: fixture.text, at: fixture.offset)
        XCTAssertTrue(shown.contains(lineAtPosition), lineAtPosition)
    }
}

// MARK: - Fixtures

/// Texts and readers for the text area's tests.
enum ReaderTextFixtures {
    /// How each line of `blankLineNearTheCut(limit:)` begins.
    static let lineStart = "A line of the chapter"
    /// How each line of `blankLineNearTheCut(limit:)` ends, before its
    /// line break.
    static let lineEnd = "ended by one line break only."

    /// `count` paragraphs of a few sentences each, set apart by blank lines.
    static func paragraphs(count: Int) -> String {
        (1...count).map { number in
            "Paragraph \(number) opens here. Its sentences run on for a while, as a book's do."
        }
        .joined(separator: "\n\n")
    }

    /// A text of numbered lines ended by single line breaks, with one blank
    /// line, then the sentence "Where did the reader go?", and more lines;
    /// and `offset`, a reading position whose window, cut at `limit` around
    /// it, ends twelve characters after the "W" of "Where", within "the":
    /// the window the reader used to show was "Where did th".
    static func blankLineNearTheCut(limit: Int) -> (text: String, offset: Int) {
        // Lines enough that the window's start is cut within them, before
        // the blank line, and as many after it, so that neither end of the
        // text is reached.
        var number = 0
        var before = ""
        while before.utf16.count <= limit {
            number += 1
            before += numberedLine(number)
        }
        var after = ""
        for _ in 0..<number {
            number += 1
            after += numberedLine(number)
        }
        let text = before + "\nWhere did the reader go? Nobody had seen her leave.\n" + after
        // The last line's break and one more make the blank line, which ends
        // where "Where" begins.
        let whereOffset = before.utf16.count + 1
        return (text, whereOffset + 12 - limit / 2)
    }

    /// Line `number` of `blankLineNearTheCut(limit:)`, with its line break:
    /// "A line of the chapter, number 7, ended by one line break only."
    private static func numberedLine(_ number: Int) -> String {
        "\(lineStart), number \(number), \(lineEnd)\n"
    }

    /// The part of `text` between two UTF-16 offsets, each kept within the
    /// text, so a window cut wrongly fails its test rather than raising a
    /// range exception that would end the test host.
    static func text(_ text: String, in range: Range<Int>) -> String {
        let length = text.utf16.count
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        return (text as NSString).substring(with: NSRange(location: lower, length: upper - lower))
    }

    /// The line of `text` holding the UTF-16 offset `offset`, kept within
    /// the text, without its line break.
    static func line(of text: String, at offset: Int) -> String {
        let string = text as NSString
        let location = min(max(offset, 0), string.length)
        let range = string.lineRange(for: NSRange(location: location, length: 0))
        return string.substring(with: range).trimmingCharacters(in: .newlines)
    }

    /// Whether the UTF-16 offset `offset` falls between words of `text`: at
    /// either end, or beside whitespace.
    static func isBetweenWords(_ text: String, at offset: Int) -> Bool {
        let units = Array(text.utf16)
        guard offset > 0, offset < units.count else { return true }
        func isSpace(_ unit: UInt16) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        return isSpace(units[offset - 1]) || isSpace(units[offset])
    }

    /// A reader of a text book whose file does not exist, in an inert
    /// library of its own, showing `text` as its one chapter, as though it
    /// had loaded. Callers close it.
    @MainActor
    static func reader(showing text: String) -> ReaderViewModel {
        let book = Book(
            title: "Text Area Fixture",
            format: .txt,
            filePath: "/nonexistent/reader-text-area/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
        reader.content = DocumentContent(
            title: book.title,
            author: "",
            chapters: [Chapter(title: book.title, text: text)]
        )
        return reader
    }
}
