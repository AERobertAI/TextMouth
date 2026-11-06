import XCTest
@testable import TextMouth

/// The same book must read the same, whether TextMouth reads its EPUB or its
/// KFX conversion (FMT52). Each KFX sample here was made by Amazon's Kindle
/// Previewer from the EPUB beside it (`Scripts/make-kfx-sample.py` for the
/// small one, `TestData/alice.epub` for the large one), and the reading text
/// of each pair is compared word for word and in order, then heading for
/// heading. A difference that is meant is named in the test that pins it,
/// and nothing else is allowed through.
final class KFXEPUBComparisonTests: XCTestCase {

    // MARK: - Helpers

    /// The reading text of the EPUB at `url`, as chapters (no page markers).
    private func epubChapters(_ url: URL) throws -> [Chapter] {
        try EPUBParser.prepareBook(url: url, includesPages: false).chapters.map(\.chapter)
    }

    /// The reading text of the KFX book at `url`, as chapters.
    private func kfxChapters(_ url: URL) throws -> [Chapter] {
        try KFXParser.prepareBook(url: url).chapters.map(\.chapter)
    }

    /// The words of `chapters`, in order: the reading text split at white space.
    private func words(_ chapters: [Chapter]) -> [String] {
        chapters.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    /// A message that names where two word lists first differ, with the
    /// words around the place in each.
    private func firstDifference(_ epub: [String], _ kfx: [String]) -> String {
        let shared = min(epub.count, kfx.count)
        let index = (0..<shared).first { epub[$0] != kfx[$0] } ?? shared
        func around(_ words: [String]) -> String {
            let lower = max(0, index - 6), upper = min(words.count, index + 7)
            return words[lower..<upper].joined(separator: " ")
        }
        return "first difference at word \(index) of \(epub.count) (EPUB) and \(kfx.count) (KFX); "
            + "EPUB: \u{201C}\(around(epub))\u{201D}; KFX: \u{201C}\(around(kfx))\u{201D}"
    }

    /// Asserts that the two books read as the same words in the same order.
    private func assertSameWords(
        epub: URL, kfx: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let fromEPUB = words(try epubChapters(epub)), fromKFX = words(try kfxChapters(kfx))
        XCTAssertFalse(fromEPUB.isEmpty, file: file, line: line)
        XCTAssertTrue(fromEPUB == fromKFX, firstDifference(fromEPUB, fromKFX), file: file, line: line)
    }

    // MARK: - The pairs

    func testTheFeatureBookReadsAsItsEPUBDoes() throws {
        try assertSameWords(
            epub: formatSampleURL("kfx/kfx-features.epub"), kfx: formatSampleURL("kfx/kfx-features.kfx"))
    }

    func testAliceReadsAsItsEPUBDoes() throws {
        try assertSameWords(epub: requireFile("alice.epub"), kfx: formatSampleURL("kfx/alice.kfx"))
    }

    func testTheFeatureBookHasTheEPUBsThreeChapters() throws {
        let kfx = try kfxChapters(formatSampleURL("kfx/kfx-features.kfx"))
        let epub = try epubChapters(formatSampleURL("kfx/kfx-features.epub"))
        XCTAssertEqual(kfx.count, 3)
        XCTAssertEqual(kfx.count, epub.count)
    }

    func testEmphasisMarksAreNeverInTheFeatureBooksWords() throws {
        for chapter in try kfxChapters(formatSampleURL("kfx/kfx-features.kfx")) {
            for mark in ["*", "_", "<", ">", "kfx-"] {
                XCTAssertFalse(chapter.text.contains(mark), "\(mark) in \(chapter.title)")
            }
        }
    }

    func testTheFeatureBooksPoemAndHeadingBreakReadAsWords() throws {
        let text = words(try kfxChapters(formatSampleURL("kfx/kfx-features.kfx"))).joined(separator: " ")
        XCTAssertTrue(text.contains("The saw goes out on Monday, the saw comes back on Friday, and nobody asks where it has been."), text)
    }

    func testAliceChapterHeadingsReadWithASpaceWhereTheTitleBreaks() throws {
        let kfx = try kfxChapters(formatSampleURL("kfx/alice.kfx"))
        let headings = kfx.flatMap(\.headings).map(\.text)
        XCTAssertTrue(headings.contains("CHAPTER I. Down the Rabbit-Hole"), headings.joined(separator: " | "))
        XCTAssertFalse(headings.contains { $0.contains("\n") })
    }
}
