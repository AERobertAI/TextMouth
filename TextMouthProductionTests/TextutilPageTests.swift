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

    func testTheDirectReaderReadsTheSameWordsAsTheCache() throws {
        let copy = try copyOfFormatSample("rtf/page-breaks.rtf")
        let content = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilDocumentReader.parse(url: copy, bookFormat: .rtf)
        }
        // The direct reader does not read page markers (as it reads no
        // heading annotations), but its words must be the cache's, so that a
        // place saved in one is the same place in the other: one space (B13).
        XCTAssertEqual(content.chapters.count, 1)
        guard let chapter = content.chapters.first else { return }
        XCTAssertTrue(chapter.text.contains("runs on and continues here."), chapter.text)
        XCTAssertEqual(chapter.text, try read("rtf/page-breaks.rtf", as: .rtf).chapter.text)
        XCTAssertEqual(content.pages, BookPages.none)
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

    /// A plain-text run the watchdog stops is read without pages too. The
    /// stand-in plain-text run never ends by itself (`sleep 60`), and the
    /// test's one-second limits stop it; the real HTML run before it is held
    /// to textutil's own limits. A tool's limits are asked for by the
    /// document's size alone, so the one-second limits once held the HTML
    /// run too, which a busy Mac could stop, failing the read.
    func testAStoppedPlainTextRunIsReadWithoutPagesToo() throws {
        let real = TextutilConverter.Tool.textutil
        let stalled = WatchedProcess.Limits(
            maximumSeconds: 1, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 1, pollInterval: 0.1
        )
        // Set as the converter asks for the plain-text run's command, which
        // it does once the HTML run has ended, just before it asks for that
        // run's limits.
        let plainTextAskedFor = LockedValue(false)
        let hangsOnThePlainText = TextutilConverter.Tool(
            command: { input, format, output in
                guard TextutilConverter.Output(outputName: output.lastPathComponent) == .plainText else {
                    return real.command(input, format, output)
                }
                plainTextAskedFor.value = true
                return (URL(fileURLWithPath: "/bin/sleep"), ["60"])
            },
            limits: { bytes in plainTextAskedFor.value ? stalled : real.limits(bytes) },
            residentMemory: { _ in nil }
        )
        let read = try read("rtf/page-breaks.rtf", as: .rtf, using: hangsOnThePlainText)
        XCTAssertTrue(plainTextAskedFor.value, "the plain-text run was never asked for")
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

    // MARK: - Word fields (ST10)

    /// A Word 97-2003 file holds a table of contents and a link, which
    /// textutil writes into both its HTML and its plain text as bare text
    /// (instructions and results alike, with no field delimiters). The
    /// instructions are removed from the HTML before it is read, so lining
    /// the two texts up afterwards disagreed on every page after the first
    /// field: only page 1 was kept and the words at each break stayed joined.
    /// The pages are placed while both still hold the instructions.
    func testAWordFileWithFieldsKeepsEveryPage() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil"), "textutil is not here")
        // Three pages: the contents and a link are on the first, so the
        // second and third pages come after the instructions. In an RTF
        // string a doubled backslash is one backslash of text.
        let rtf = #"""
            {\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}
            \pard Alpha opening words.\par
            \pard TOC \\o "1-3" \\h \\z \\u HYPERLINK \\l "_Toc68096040" Contents\tab PAGEREF _Toc68096040 \\h 1\par
            \pard Still the first page ends here.\page Bravo second page begins here.\page Charlie third page begins here.\par
            }
            """#
        let folder = try makeSandboxDirectory("TextutilFieldsDoc")
        let source = folder.appendingPathComponent("fields.rtf")
        let doc = folder.appendingPathComponent("fields.doc")
        try rtf.write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "doc", "-format", "rtf", "-output", doc.path, source.path]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "textutil could not make the .doc")

        let markdown = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilDocumentReader.extract(from: doc, bookFormat: .doc, includesPages: true).markdown
        }
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)

        XCTAssertEqual(chapter.pages.map(\.label), ["1", "2", "3"], markdown)
        guard chapter.pages.count == 3 else { return }
        XCTAssertTrue(text(from: chapter.pages[0], in: chapter).hasPrefix("Alpha"), chapter.text)
        XCTAssertTrue(text(from: chapter.pages[1], in: chapter).hasPrefix("Bravo"), chapter.text)
        XCTAssertTrue(text(from: chapter.pages[2], in: chapter).hasPrefix("Charlie"), chapter.text)
        // The words either side of each break are apart (B13), and the
        // instructions are never read.
        XCTAssertTrue(chapter.text.contains("ends here. Bravo second"), chapter.text)
        XCTAssertTrue(chapter.text.contains("begins here. Charlie third"), chapter.text)
        XCTAssertFalse(chapter.text.contains("HYPERLINK"), chapter.text)
        XCTAssertFalse(chapter.text.contains("PAGEREF"), chapter.text)
    }

    // MARK: - The Cost

    /// Prints what the plain-text run for pages costs, one run against two,
    /// for each sample, and checks what each read gives: the read without
    /// pages writes no page marker, the read with pages has its plain-text
    /// run succeed, and the samples with page breaks have markers with it.
    func testTheSecondRunsCost() throws {
        let samples: [(path: String, format: BookFormat, hasPageBreaks: Bool)] = [
            ("rtf/page-breaks.rtf", .rtf, true), ("doc/page-breaks.doc", .doc, true), ("rtf/word-styles.rtf", .rtf, false),
        ]
        for (path, format, hasPageBreaks) in samples {
            let copy = try copyOfFormatSample(path)
            let started = Date()
            let single = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: format, includesPages: false)
            }
            let singleSeconds = Date().timeIntervalSince(started)
            let startedAgain = Date()
            let withPages = try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: format, includesPages: true)
            }
            let doubleSeconds = Date().timeIntervalSince(startedAgain)
            print("PG11 cost \(path): one run \(singleSeconds) s, with the plain-text run \(doubleSeconds) s")

            XCTAssertFalse(single.markdown.contains("<!-- page:"), path)
            XCTAssertFalse(withPages.pageRunFailed, path)
            if hasPageBreaks {
                XCTAssertTrue(withPages.markdown.contains("<!-- page:"), path)
            }
        }
    }
}
