import XCTest
import SwiftSoup
@testable import TextMouth

/// The pages of the documents textutil reads (PG11, fixing B13): rich text,
/// Word 97-2003, and Word 2003 XML, whose HTML keeps no page break and joins
/// the words on either side of one, and whose plain text keeps each break as
/// a form feed. The second run's plain text is lined up with the HTML by
/// letters and digits (`TextutilPageBreaks`) and written into it as
/// page-break elements, which the converter writes as page markers.
///
/// The samples are `TestData/format-samples/{rtf,doc,wordml}/page-breaks.*`,
/// made by `make_textutil_pages.sh`: two paragraphs on one page, the second
/// running on over a real page break ("runs on and" / "continues here."),
/// then a `\pagebb` and a `\sect` that textutil loses when it reads, so the
/// document has two pages and no more.
final class TextutilPageTests: XCTestCase {

    // MARK: - Helpers

    /// A folder for the hidden files textutil writes; every read must leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("TextutilPagesWork")
    }

    /// The Markdown of the sample at `path` (a copy of it), read as `format`
    /// with or without pages, under the stand-in `tool` when given, and the
    /// chapter that Markdown parses to as content.md is read.
    private func read(
        _ path: String,
        as format: BookFormat,
        includesPages: Bool = true,
        using tool: TextutilConverter.Tool = TextutilConverter.tool
    ) throws -> (markdown: String, chapter: Chapter) {
        let copy = try copyOfFormatSample(path)
        let markdown = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilConverter.$tool.withValue(tool) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: format, includesPages: includesPages).markdown
            }
        }
        // Every working folder the read made is gone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
        return (markdown, chapter)
    }

    /// The reading text of `chapter` from the page's offset on, found through
    /// UTF-16 as every saved place is.
    private func text(from page: PageBreak, in chapter: Chapter) -> String {
        let units = Array(chapter.text.utf16)
        guard page.characterOffset >= 0, page.characterOffset <= units.count else { return "" }
        return String(decoding: units[page.characterOffset...], as: UTF16.self)
    }

    /// Asserts that `chapter` holds pages 1 and 2 of the samples, page 1 at
    /// the start and page 2 at "continues", and that its words run on with one
    /// space (B13 fixed).
    private func assertTheSamplesPages(of chapter: Chapter, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(chapter.pages.map(\.label), ["1", "2"], file: file, line: line)
        guard chapter.pages.count == 2 else { return }
        XCTAssertEqual(chapter.pages[0].characterOffset, 0, file: file, line: line)
        XCTAssertTrue(text(from: chapter.pages[1], in: chapter).hasPrefix("continues here."), file: file, line: line)
        XCTAssertTrue(chapter.text.contains("runs on and continues here."), chapter.text, file: file, line: line)
        XCTAssertFalse(chapter.text.contains("andcontinues"), file: file, line: line)
    }

    /// The HTML in `body` of `html` after the plain text `plain`'s page breaks
    /// are written into it, with no line breaks added, and what was placed.
    private func inserted(
        _ plain: String,
        into html: String
    ) throws -> (body: String, outcome: TextutilPageBreaks.Outcome) {
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        let outcome = try TextutilPageBreaks.insertPageBreaks(fromPlainText: plain, into: document)
        return (try XCTUnwrap(document.body()).html(), outcome)
    }

    /// The element that stands for page `page`, as written.
    private func span(_ page: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(page)\"></span>"
    }

    // MARK: - The Samples

    func testTheRichTextSampleHasTwoPagesAndItsWordsAreApart() throws {
        let read = try read("rtf/page-breaks.rtf", as: .rtf)
        assertTheSamplesPages(of: read.chapter)
        // The marker is never part of the reading text.
        XCTAssertFalse(read.chapter.text.contains("page:"))
    }

    func testWithoutPagesTheWordsAreJoinedAsBeforeAndNoPageIsFound() throws {
        let read = try read("rtf/page-breaks.rtf", as: .rtf, includesPages: false)
        XCTAssertEqual(read.chapter.pages, [])
        XCTAssertFalse(read.markdown.contains("<!-- page:"))
        XCTAssertTrue(read.chapter.text.contains("runs on andcontinues here."), read.chapter.text)
    }

    func testWithoutPagesTextutilRunsOnceAndWithPagesTwice() throws {
        let runs = LockedValue<[TextutilConverter.Output]>([])
        let real = TextutilConverter.Tool.textutil
        let counting = TextutilConverter.Tool(
            command: { input, format, output in
                runs.value.append(TextutilConverter.Output(outputName: output.lastPathComponent))
                return real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
        _ = try read("rtf/page-breaks.rtf", as: .rtf, includesPages: false, using: counting)
        XCTAssertEqual(runs.value, [.html])
        runs.value = []
        _ = try read("rtf/page-breaks.rtf", as: .rtf, using: counting)
        XCTAssertEqual(runs.value, [.html, .plainText])
    }

    func testTheWordDocumentSampleGivesTheSamePagesAndWords() throws {
        assertTheSamplesPages(of: try read("doc/page-breaks.doc", as: .doc).chapter)
    }

    func testTheWordML2003SampleGivesTheSamePagesAndWords() throws {
        assertTheSamplesPages(of: try read("wordml/page-breaks.wordml", as: .wordml).chapter)
    }

    func testTheDirectReaderFindsTheSamePages() throws {
        let copy = try copyOfFormatSample("rtf/page-breaks.rtf")
        let content = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilDocumentReader.parse(url: copy, bookFormat: .rtf)
        }
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2"])
        XCTAssertEqual(content.pages.total, 2)
    }

    func testReadingTheNamesAloneRunsNoSecondPass() throws {
        let runs = LockedValue<Int>(0)
        let real = TextutilConverter.Tool.textutil
        let counting = TextutilConverter.Tool(
            command: { input, format, output in
                runs.value += 1
                return real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
        let copy = try copyOfFormatSample("rtf/page-breaks.rtf")
        _ = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilConverter.$tool.withValue(counting) {
                try TextutilDocumentReader.readMetadata(from: copy, bookFormat: .rtf)
            }
        }
        XCTAssertEqual(runs.value, 1)
    }

    // MARK: - The Plain Text Run

    func testThePlainTextKeepsTheBreakAsAFormFeed() throws {
        let copy = try copyOfFormatSample("rtf/page-breaks.rtf")
        let text = try TextutilConverter.plainText(of: copy, as: .rtf, workingIn: work)
        XCTAssertTrue(text.contains("runs on and\u{000C}continues here."), text)
        XCTAssertEqual(text.unicodeScalars.filter { $0 == TextutilPageBreaks.formFeed }.count, 1)
        // The hidden file is gone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testThePlainTextRunsArgumentsAreThePinnedOnesWithTxt() {
        let arguments = TextutilConverter.arguments(
            input: URL(fileURLWithPath: "/in/-dash.doc"),
            format: .doc,
            output: URL(fileURLWithPath: "/out/.x.textutil.txt")
        )
        XCTAssertEqual(arguments, [
            "-convert", "txt", "-noload", "-nostore", "-format", "doc", "-encoding", "UTF-8",
            "-output", "/out/.x.textutil.txt", "--", "/in/-dash.doc",
        ])
    }

    func testTheKindOfAnOutputComesFromItsName() {
        XCTAssertEqual(TextutilConverter.Output(outputName: ".A.textutil.html"), .html)
        XCTAssertEqual(TextutilConverter.Output(outputName: ".A.textutil.txt"), .plainText)
        XCTAssertEqual(TextutilConverter.temporarySuffixes, [".textutil.html", ".textutil.txt"])
    }

    func testTheLeftoverSweepKnowsBothHiddenFiles() {
        XCTAssertTrue(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/.a.textutil.txt"))
        XCTAssertTrue(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/.a.textutil.html"))
        XCTAssertFalse(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/.textutil.txt"))
        XCTAssertFalse(OrphanedConversionSweep.isTextutilTemporaryOutputName("/tmp/a.textutil.txt"))
    }

    // MARK: - A Plain Text Run That Fails

    /// Real textutil for the HTML and `/usr/bin/false` for the plain text.
    private func toolWhosePlainTextRunFails() -> TextutilConverter.Tool {
        let real = TextutilConverter.Tool.textutil
        return TextutilConverter.Tool(
            command: { input, format, output in
                TextutilConverter.Output(outputName: output.lastPathComponent) == .plainText
                    ? (URL(fileURLWithPath: "/usr/bin/false"), [])
                    : real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
    }

    func testADocumentWhosePlainTextRunFailsIsReadWithoutPages() throws {
        let read = try read("rtf/page-breaks.rtf", as: .rtf, using: toolWhosePlainTextRunFails())
        // The HTML run is unaffected: the document reads as it does without pages.
        XCTAssertEqual(read.chapter.pages, [])
        XCTAssertTrue(read.chapter.text.contains("runs on andcontinues here."), read.chapter.text)
        XCTAssertTrue(read.chapter.text.contains("First page paragraph one."))
    }

    func testTheFailureOfThePlainTextRunIsLoggedInOneLine() {
        XCTAssertEqual(
            TextutilPageBreaks.failedLogLine(fileName: "a.doc", why: "textutil stopped"),
            "TEXTUTIL_PAGES_FAILED: a.doc: textutil stopped"
        )
        XCTAssertEqual(
            TextutilPageBreaks.unalignedLogLine(fileName: "a.doc", page: 4),
            "TEXTUTIL_PAGE_UNALIGNED: a.doc: page 4"
        )
    }

    func testAStoppedPlainTextRunIsReadWithoutPagesToo() throws {
        let real = TextutilConverter.Tool.textutil
        let stalled = WatchedProcess.Limits(
            maximumSeconds: 1, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 1, pollInterval: 0.1
        )
        let hangsOnThePlainText = TextutilConverter.Tool(
            command: { input, format, output in
                TextutilConverter.Output(outputName: output.lastPathComponent) == .plainText
                    ? (URL(fileURLWithPath: "/bin/sleep"), ["60"])
                    : real.command(input, format, output)
            },
            limits: { bytes in bytes < 1_000_000 ? stalled : real.limits(bytes) },
            residentMemory: { _ in nil }
        )
        let read = try read("rtf/page-breaks.rtf", as: .rtf, using: hangsOnThePlainText)
        XCTAssertEqual(read.chapter.pages, [])
        XCTAssertTrue(read.chapter.text.contains("First page paragraph one."))
    }

    // MARK: - Alignment

    func testABreakWhereTheTextsDifferIsDroppedAndNeverPlacedWrongly() throws {
        // The HTML has an extra word near the break.
        let result = try inserted(
            "alpha beta\u{000C}gamma delta",
            into: "<p>alpha extra beta gamma delta</p>"
        )
        XCTAssertEqual(result.outcome, TextutilPageBreaks.Outcome(placed: [1], unaligned: [2]))
        XCTAssertEqual(result.body, "\(span(1))<p>alpha extra beta gamma delta</p>")
    }

    func testAListNumberTheHTMLLacksDropsTheBreaksAfterIt() throws {
        // The plain text counts the "1" of a list marker that the HTML lacks.
        let result = try inserted(
            "1. First item\n2. Second item\u{000C}Third item",
            into: "<ul><li>First item</li><li>Second item</li></ul><p>Third item</p>"
        )
        XCTAssertEqual(result.outcome.unaligned, [2])
        XCTAssertEqual(result.outcome.placed, [1])
    }

    func testAnUnalignedBreakDoesNotStopTheOnesThatAlign() throws {
        // The texts differ in one letter by page 2's break, which is dropped;
        // the counts still agree, and the words around page 3's break are the
        // same in both, so it is placed.
        let plain = "one two\u{000C}three four five six seven eight\u{000C}nine ten"
        let html = "<p>one twx three four five six seven eight nine ten</p>"
        let result = try inserted(plain, into: html)
        XCTAssertEqual(result.outcome.unaligned, [2])
        XCTAssertEqual(result.outcome.placed, [1, 3])
        XCTAssertTrue(result.body.contains("\(span(3))nine ten"), result.body)
    }

    func testABreakNearTheStartOfTheDocumentIsCheckedOnWhatThereIs() throws {
        let result = try inserted("ab\u{000C}cd", into: "<p>ab cd</p>")
        XCTAssertEqual(result.outcome, TextutilPageBreaks.Outcome(placed: [1, 2], unaligned: []))
        // The check also catches a difference within those few letters.
        let different = try inserted("ab\u{000C}cd", into: "<p>ab cx</p>")
        XCTAssertEqual(different.outcome.unaligned, [2])
    }

    func testABreakNearTheEndOfTheDocumentIsCheckedOnWhatThereIs() throws {
        let result = try inserted(
            "this document ends here\u{000C}ok",
            into: "<p>this document ends here ok</p>"
        )
        XCTAssertEqual(result.outcome.placed, [1, 2])
        let different = try inserted(
            "this document ends here\u{000C}ok",
            into: "<p>this document ends here on</p>"
        )
        XCTAssertEqual(different.outcome.unaligned, [2])
    }

    func testABreakWithNothingAfterItIsAnEmptyPageAndIsLeftOut() throws {
        let result = try inserted("only page\u{000C}", into: "<p>only page</p>")
        XCTAssertEqual(result.outcome, TextutilPageBreaks.Outcome(placed: [1], unaligned: []))
    }

    func testTextThatTheConverterSkipsIsNotCounted() throws {
        // A script, a style, and a hidden element are not read, so their
        // letters do not move the count.
        let html = "<style>p { color: red }</style><script>var x</script><p hidden>hidden words</p><p>ab cd</p>"
        let result = try inserted("ab\u{000C}cd", into: html)
        XCTAssertEqual(result.outcome.placed, [1, 2])
        XCTAssertTrue(result.body.contains("ab \(span(2))cd"), result.body)
    }

    func testADocumentWithNoLettersGetsNoPages() throws {
        let result = try inserted("\u{000C} --", into: "<p>--</p>")
        XCTAssertEqual(result.outcome, TextutilPageBreaks.Outcome())
        XCTAssertEqual(result.body, "<p>--</p>")
    }

    func testMoreBreaksThanTheLimitAreNotRead() throws {
        let plain = "a" + String(repeating: "\u{000C}", count: TextutilPageBreaks.maximumPages) + "b"
        XCTAssertNil(TextutilPageBreaks.formFeeds(in: plain))
        let result = try inserted(plain, into: "<p>ab</p>")
        XCTAssertEqual(result.outcome, TextutilPageBreaks.Outcome())
    }

    func testTheCountIsOfLettersAndDigitsAlone() {
        XCTAssertTrue(TextutilPageBreaks.isCounted("a"))
        XCTAssertTrue(TextutilPageBreaks.isCounted("É"))
        XCTAssertTrue(TextutilPageBreaks.isCounted("7"))
        XCTAssertTrue(TextutilPageBreaks.isCounted("\u{0661}"))
        XCTAssertFalse(TextutilPageBreaks.isCounted(" "))
        XCTAssertFalse(TextutilPageBreaks.isCounted("."))
        XCTAssertFalse(TextutilPageBreaks.isCounted("\u{2022}"))
        XCTAssertFalse(TextutilPageBreaks.isCounted("\u{FFFC}"))
        // A combining mark does not count, so a page cannot begin between a letter and its mark.
        XCTAssertFalse(TextutilPageBreaks.isCounted("\u{0301}"))
    }

    func testTheFormFeedsOfAPlainTextCarryTheirContext() throws {
        let plain = try XCTUnwrap(TextutilPageBreaks.formFeeds(in: "ab, c\u{000C}d e\u{000C}\u{000C}f"))
        XCTAssertEqual(plain.letters, 6)
        XCTAssertEqual(plain.breaks.map(\.page), [2, 3, 4])
        XCTAssertEqual(plain.breaks.map(\.lettersBefore), [3, 5, 5])
        XCTAssertEqual(plain.breaks[0].context.before, ["a", "b", "c"])
        XCTAssertEqual(plain.breaks[0].context.after, ["d", "e", "f"])
        XCTAssertEqual(plain.breaks[2].context.after, ["f"])
    }

    // MARK: - Insertion

    func testABreakInTheMiddleOfAWordRunGetsOneSpace() throws {
        // textutil joined the words: "andcontinues" (B13).
        let result = try inserted("runs on and\u{000C}continues", into: "<p>runs on andcontinues</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>runs on and \(span(2))continues</p>")
    }

    func testABreakAfterASpaceAddsNoSpace() throws {
        let result = try inserted("runs on and\u{000C}continues", into: "<p>runs on and continues</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>runs on and \(span(2))continues</p>")
    }

    func testABreakAtTheStartOfANodeAddsNoSpace() throws {
        let result = try inserted("first\n\u{000C}second", into: "<p>first</p><p>second</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>first</p><p>\(span(2))second</p>")
    }

    func testABreakInsideInlineMarkupIsPlacedInsideIt() throws {
        let result = try inserted("one two\u{000C}three", into: "<p><b>one two</b><i>three</i></p>")
        XCTAssertEqual(result.body, "\(span(1))<p><b>one two</b><i>\(span(2))three</i></p>")
    }

    func testTwoBreaksAtOnePlaceGiveTwoSpansInOrder() throws {
        let result = try inserted("ab\u{000C}\u{000C}cd", into: "<p>abcd</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>ab \(span(2))\(span(3))cd</p>")
        XCTAssertEqual(result.outcome.placed, [1, 2, 3])
    }

    func testSeveralBreaksInOneNodeKeepEveryWord() throws {
        let result = try inserted("aa\u{000C}bb\u{000C}cc", into: "<p>aabbcc</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>aa \(span(2))bb \(span(3))cc</p>")
    }

    func testABreakBeforeTheFirstWordBothStartTheBookAndPageTwo() throws {
        // A form feed first in the text: page 1 is empty, page 2 begins at the start.
        let result = try inserted("\u{000C}ab cd", into: "<p>ab cd</p>")
        XCTAssertEqual(result.body, "\(span(1))<p>\(span(2))ab cd</p>")
    }

    func testTheSpansBecomeMarkersTheConverterWritesAndNeverReads() throws {
        let document = try SwiftSoup.parse("<p>runs on andcontinues</p>")
        try TextutilPageBreaks.insertPageBreaks(fromPlainText: "runs on and\u{000C}continues", into: document)
        let markdown = try HTMLToMarkdownConverter.convert(
            document: document,
            readingFlow: PublicationSemantics.ReadingFlow(source: "<p>runs on andcontinues</p>" + TextutilPageBreaks.pageBreakRole)
        )
        XCTAssertTrue(markdown.contains("<!-- page: 1 -->"), markdown)
        XCTAssertTrue(markdown.contains("<!-- page: 2 -->continues"), markdown)
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
        XCTAssertEqual(chapter.text, "runs on and continues")
    }

    // MARK: - The Cost

    func testTheSecondRunsCost() throws {
        for (path, format) in [("rtf/page-breaks.rtf", BookFormat.rtf), ("doc/page-breaks.doc", .doc), ("rtf/word-styles.rtf", .rtf)] {
            let copy = try copyOfFormatSample(path)
            let started = Date()
            _ = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: format, includesPages: false)
            }
            let single = Date().timeIntervalSince(started)
            let startedAgain = Date()
            _ = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: format, includesPages: true)
            }
            let double = Date().timeIntervalSince(startedAgain)
            print("PG11 cost \(path): one run \(single) s, with the plain-text run \(double) s")
        }
    }
}
