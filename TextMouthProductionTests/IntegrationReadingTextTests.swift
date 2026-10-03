import XCTest
@testable import TextMouth

/// Reading text at the real boundary (TODO Q04; the September 28 repair of
/// EPUB navigation destinations at the start of a line): a book imported as
/// a user imports it, its text cached as the import caches it, and opened
/// in a reader, which reads the cache through its own loader.
///
/// This is the seventh workflow, chosen as the repair most at risk of
/// silent regression. A lost paragraph raises no error anywhere: the
/// import succeeds, the reader opens, and the words are simply never
/// spoken, which a listener cannot notice without the printed book. It
/// has already happened at scale: the 3.0.4 cache silently dropped every
/// paragraph that began with a destination anchor, 145 paragraphs of one
/// book and part of 86 of 623 books in the live library, found only while
/// investigating a user's report about headings. The loss happened only on
/// the cached path (the direct parser kept the words), so only a test that
/// goes through import, cache, and reader catches it. And the code involved,
/// the HTML to Markdown conversion and the CommonMark reading of the cache,
/// changes often: the cache format was rebuilt twice more within two days
/// of the repair (3.0.6 and 3.0.7), the second time for a rewrite of that
/// conversion.
@MainActor
final class IntegrationReadingTextTests: XCTestCase {
    /// Each paragraph, list item, and quotation of this book begins with a
    /// destination its table of contents leads to, as books converted from
    /// other formats commonly do (an empty anchor such as "filepos1022"),
    /// and one destination follows a line break. Opened in a reader, every
    /// paragraph's words are there, once and in order, nothing of the
    /// markup is read out, and every table of contents entry is a heading
    /// at the first word of its passage.
    ///
    /// Before the repair, such an anchor began the cached Markdown line,
    /// which CommonMark reads as the start of an HTML block, swallowing the
    /// line's words. With that placement restored in
    /// `HTMLToMarkdownConverter.emit` (commit 2c92d2b no longer reverts
    /// cleanly), this test fails with "Chapter 1 does not read “CHAPTER ONE”
    /// exactly once": chapter 1 reads only "The boiler held at forty pounds
    /// while the stoker banked the fire.", chapter 2 only "Open the damper.",
    /// and three of the five contents entries are lost.
    func testPassagesThatBeginWithTheirDestinationsReachTheReaderWhole() throws {
        let world = try makeIntegrationWorld("Integration Reading Text")
        let book = try world.importBook(from: writeEngineRoomEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "The book did not open")
        let chapters = try XCTUnwrap(reader.content?.chapters)
        XCTAssertEqual(chapters.count, Self.passages.count)
        for (number, expected) in Self.passages.enumerated() where number < chapters.count {
            let text = chapters[number].text
            assertInOrderExactlyOnce(expected, in: text, chapter: number + 1)
            for markup in ["<", ">", "[", "]"] {
                XCTAssertFalse(text.contains(markup), "Chapter \(number + 1) reads out “\(markup)”: \(text)")
            }
        }

        XCTAssertEqual(reader.headings.map(\.text), Self.contents.map(\.label))
        for (heading, entry) in zip(reader.headings, Self.contents) where heading.chapterIndex < chapters.count {
            let text = chapters[heading.chapterIndex].text
            let words = try XCTUnwrap(text.range(of: entry.firstWords), "No “\(entry.firstWords)” in the reader")
            XCTAssertEqual(
                heading.characterOffset,
                text.utf16Offset(of: words.lowerBound),
                "“\(entry.label)” does not lead to the first word of its passage"
            )
        }
    }

    // MARK: - Fixture

    /// The words of each chapter's passages, in reading order.
    private static let passages: [[String]] = [
        [
            "CHAPTER ONE",
            "The boiler held at forty pounds while the stoker banked the fire.",
            "The first signal came at dawn.",
            "A second followed at noon.",
        ],
        [
            "CHAPTER TWO",
            "Check the water glass.",
            "Open the damper.",
            "Never let the crown sheet run dry.",
        ],
    ]

    /// The table of contents: each entry's label, its destination, and the
    /// first words of the passage it leads to.
    private static let contents: [(label: String, target: String, firstWords: String)] = [
        ("Chapter One", "ch01.xhtml#filepos1022", "CHAPTER ONE"),
        ("Noon Signal", "ch01.xhtml#filepos1310", "A second followed at noon."),
        ("Chapter Two", "ch02.xhtml#filepos2048", "CHAPTER TWO"),
        ("Daily Checks", "ch02.xhtml#filepos2100", "Check the water glass."),
        ("Boiler Rule", "ch02.xhtml#filepos2200", "Never let the crown sheet run dry."),
    ]

    /// An engine-room handbook whose passages begin with the destinations
    /// of `contents`, written as an EPUB in a folder of this test's own.
    private func writeEngineRoomEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("IntegrationReadingTextSources").appendingPathComponent("engine-room.epub")
        try IntegrationEPUB.write(
            title: "Engine Room",
            chapters: [
                IntegrationEPUBChapter(fileName: "ch01.xhtml", body: """
                <p><a id="filepos1022"></a>CHAPTER ONE</p>
                <p>The boiler held at forty pounds while the stoker banked the fire.</p>
                <p>The first signal came at dawn.<br/><a id="filepos1310"></a>A second followed at noon.</p>
                """),
                IntegrationEPUBChapter(fileName: "ch02.xhtml", body: """
                <p><span id="filepos2048"></span>CHAPTER TWO</p>
                <ul><li><a id="filepos2100"></a>Check the water glass.</li><li>Open the damper.</li></ul>
                <blockquote><span id="filepos2200"></span>Never let the crown sheet run dry.</blockquote>
                """),
            ],
            contents: Self.contents.map { IntegrationTOCEntry(label: $0.label, target: $0.target) },
            to: epub
        )
        return epub
    }

    /// Checks that each of `passages` appears in `text` exactly once, each
    /// after the one before it.
    private func assertInOrderExactlyOnce(
        _ passages: [String],
        in text: String,
        chapter: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for passage in passages {
            XCTAssertEqual(
                text.components(separatedBy: passage).count - 1,
                1,
                "Chapter \(chapter) does not read “\(passage)” exactly once: \(text)",
                file: file,
                line: line
            )
            guard let found = text.range(of: passage, range: searchStart..<text.endIndex) else {
                XCTFail("Chapter \(chapter) lacks “\(passage)” after the passage before it: \(text)", file: file, line: line)
                return
            }
            searchStart = found.upperBound
        }
    }
}
