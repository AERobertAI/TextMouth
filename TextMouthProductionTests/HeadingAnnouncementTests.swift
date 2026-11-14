import XCTest
@testable import TextMouth

/// What VoiceOver hears on arriving at a heading by Next Heading, Previous
/// Heading, and the subheading jumps: every heading that begins at the place
/// reached, the outermost first. An audiobook's manifest begins a group
/// heading at the same place as its first track's heading, and the jump
/// says both: "Heading: Season Two, Where Is Everybody?". A heading alone at
/// its place is said as it always was.
@MainActor
final class HeadingAnnouncementTests: XCTestCase {

    // MARK: - The Wording

    /// Headings that share a place are said together, the outermost first,
    /// whichever of them the jump found; one alone is said as before.
    func testHeadingsSharingAPlaceAreSaidOutermostFirst() {
        let headings = Self.groupedHeadings
        let group = headings[1]
        let track = headings[2]

        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: group, in: headings), "Heading: Season One, Where Is Everybody?")
        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: track, in: headings), "Heading: Season One, Where Is Everybody?")
        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: headings[0], in: headings), "Heading: Prologue")
        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: headings[3], in: headings), "Heading: One for the Angels")
    }

    /// Outermost means the lowest level, whatever order the list gives
    /// them in; headings of one level keep the list's order.
    func testTheOutermostComesFirstAndEqualLevelsKeepTheirOrder() {
        let inner = Heading(level: 3, text: "Ferry Notes", chapterIndex: 0, characterOffset: 40)
        let outer = Heading(level: 1, text: "Part Two", chapterIndex: 0, characterOffset: 40)
        let middleA = Heading(level: 2, text: "Harbor", chapterIndex: 0, characterOffset: 40)
        let middleB = Heading(level: 2, text: "Breakwater", chapterIndex: 0, characterOffset: 40)
        let elsewhere = Heading(level: 1, text: "Part One", chapterIndex: 0, characterOffset: 0)
        let headings = [elsewhere, inner, middleA, outer, middleB]

        XCTAssertEqual(
            ReaderViewModel.headingsSharingPlace(with: inner, in: headings).map(\.text),
            ["Part Two", "Harbor", "Breakwater", "Ferry Notes"]
        )
        XCTAssertEqual(
            ReaderViewModel.headingAnnouncement(arrivingAt: middleB, in: headings),
            "Heading: Part Two, Harbor, Breakwater, Ferry Notes"
        )
    }

    /// A blank heading is left out of a place it shares, and one alone is
    /// said as before.
    func testBlankHeadingsAreLeftOutOfASharedPlace() {
        let blank = Heading(level: 1, text: " ", chapterIndex: 2, characterOffset: 0)
        let named = Heading(level: 2, text: "Chapter Three", chapterIndex: 2, characterOffset: 0)
        let lonely = Heading(level: 1, text: "", chapterIndex: 3, characterOffset: 0)
        let headings = [blank, named, lonely]

        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: blank, in: headings), "Heading: Chapter Three")
        XCTAssertEqual(ReaderViewModel.headingAnnouncement(arrivingAt: lonely, in: headings), "Heading: ")
    }

    // MARK: - The Jumps

    /// Next Heading stops once at a place two headings share and says both;
    /// the next press goes on to the next place.
    func testNextHeadingSaysEveryHeadingAtThePlaceItReaches() {
        let reader = makeReader()
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 20

        reader.nextHeading()
        XCTAssertEqual(place(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Season One, Where Is Everybody?")

        reader.nextHeading()
        XCTAssertEqual(place(of: reader), "2:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: One for the Angels")

        reader.nextHeading()
        XCTAssertEqual(place(of: reader), "3:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Season Two, King Nine Will Not Return")
    }

    /// Previous Heading finds the inner heading of a shared place, the last
    /// one listed, and says the outer one first all the same.
    func testPreviousHeadingSaysEveryHeadingAtThePlaceItReaches() {
        let reader = makeReader()
        defer { reader.close() }
        reader.currentChapterIndex = 3
        reader.currentCharacterOffset = 0

        reader.previousHeading()
        XCTAssertEqual(place(of: reader), "2:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: One for the Angels")

        reader.previousHeading()
        XCTAssertEqual(place(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Season One, Where Is Everybody?")
    }

    /// The subheading jumps say every heading at the place too.
    func testSubheadingJumpsSayEveryHeadingAtThePlaceTheyReach() {
        let reader = makeReader()
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 20

        reader.nextSubheading()
        XCTAssertEqual(place(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Season One, Where Is Everybody?")

        reader.currentChapterIndex = 3
        reader.currentCharacterOffset = 50
        reader.previousSubheading()
        XCTAssertEqual(place(of: reader), "3:0")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Season Two, King Nine Will Not Return")
    }

    /// The jumps and the heading measures read the reader's published
    /// `headings` instead of rebuilding the book's (the audit's C17), so the
    /// two must be the same list whenever the book's text is replaced: the
    /// jumps and the sizes then follow the new headings, not the old.
    func testTheJumpsAndMeasuresFollowTheHeadingsOfTheContentShown() {
        let reader = makeReader()
        defer { reader.close() }
        XCTAssertEqual(reader.headings, reader.content?.allHeadings)
        XCTAssertEqual(reader.estimatedCharsInHeading(Self.groupedHeadings[0]), 100)

        // The book's text is replaced by one with a single heading.
        let only = Heading(level: 1, text: "Only", chapterIndex: 2, characterOffset: 10)
        let chapters = (0..<4).map { index in
            Chapter(title: "Part \(index + 1)", text: String(repeating: "x", count: 100), headings: index == 2 ? [only] : [])
        }
        reader.content = DocumentContent(title: "Replaced", author: "", chapters: chapters)

        XCTAssertEqual(reader.headings, [only])
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0
        reader.nextHeading()
        XCTAssertEqual(place(of: reader), "2:10")
        XCTAssertEqual(reader.lastAnnouncement, "Heading: Only")
        XCTAssertEqual(reader.estimatedCharsInHeading(only), 190)
    }

    // MARK: - Fixtures

    /// The headings of a book arranged as an audiobook's manifest arranges
    /// one: a heading of its own before the first group, then two groups,
    /// each beginning with its first track's heading.
    private static let groupedHeadings = [
        Heading(level: 1, text: "Prologue", chapterIndex: 0, characterOffset: 0),
        Heading(level: 1, text: "Season One", chapterIndex: 1, characterOffset: 0),
        Heading(level: 2, text: "Where Is Everybody?", chapterIndex: 1, characterOffset: 0),
        Heading(level: 2, text: "One for the Angels", chapterIndex: 2, characterOffset: 0),
        Heading(level: 1, text: "Season Two", chapterIndex: 3, characterOffset: 0),
        Heading(level: 2, text: "King Nine Will Not Return", chapterIndex: 3, characterOffset: 0),
    ]

    /// A stopped reader of a book of four chapters, each a hundred letters
    /// long, with `groupedHeadings`, read from memory: nothing plays, and
    /// nothing is read from disk.
    private func makeReader() -> ReaderViewModel {
        let book = Book(
            title: "Grouped Headings",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-grouped-headings.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false)
        )
        let chapters = (0..<4).map { index in
            Chapter(
                title: "Part \(index + 1)",
                text: String(repeating: "x", count: 100),
                headings: Self.groupedHeadings.filter { $0.chapterIndex == index }
            )
        }
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        return reader
    }

    /// Where `reader`'s cursor is, as "chapter:offset".
    private func place(of reader: ReaderViewModel) -> String {
        "\(reader.currentChapterIndex):\(reader.currentCharacterOffset)"
    }
}
