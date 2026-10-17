import XCTest
@testable import TextMouth

/// The corpus report's builder, on synthetic values: no file is imported.
/// The report is read through VoiceOver and a braille display, so these
/// tests pin its wording, its order, and what it must never contain.
final class CorpusReportFormatTests: XCTestCase {

    // MARK: - Fixtures

    /// A context for a finished run on a folder called "Library Copy".
    private func context(
        folderName: String = "Library Copy", found: Int = 1, limit: Int? = nil, complete: Bool = true,
        hidden: [CorpusReportContext.HiddenPath] = []
    ) -> CorpusReportContext {
        CorpusReportContext(
            folderName: folderName, date: "2026-10-16", macOSVersion: "Version 26.3", appBuild: "0.1.1 (1)",
            hiddenPaths: hidden, foundCount: found, fileLimit: limit, isComplete: complete
        )
    }

    /// A dump of an imported book; each argument has a plain default.
    private func dump(
        format: String = "epub", title: String = "A Title", author: String = "An Author",
        report: String? = nil, headings: [DocumentDump.HeadingLine] = [],
        audioDuration: Double? = nil, tracks: [DocumentDump.Track] = []
    ) -> DocumentDump {
        DocumentDump(
            fileName: "x", format: format, title: title, author: author, chapterCount: 3, wordCount: 1200,
            textLength: 7000, textChecksum: "00ff00ff00ff00ff", firstSample: "", lastSample: "",
            reportMessage: report, headings: headings, audioDuration: audioDuration, tracks: tracks
        )
    }

    private func imported(
        _ path: String = "book.epub", dump: DocumentDump? = nil, lines: [String] = ["One", "Two"]
    ) -> CorpusFileEntry {
        CorpusFileEntry(
            relativePath: path, format: "EPUB",
            outcome: .imported(CorpusFacts(dump: dump ?? self.dump(), firstLines: lines)), importSeconds: 1.26
        )
    }

    /// The section of `entry` as one string, for substring checks.
    private func text(of entry: CorpusFileEntry, _ context: CorpusReportContext? = nil) -> String {
        CorpusReportBuilder.section(for: entry, context: context ?? self.context()).joined(separator: "\n")
    }

    // MARK: - One Section for Each Result

    func testAnImportedFileShowsEveryFactOnItsOwnLine() {
        let lines = CorpusReportBuilder.section(for: imported(), context: context())
        XCTAssertEqual(lines, [
            "## book.epub",
            "- Format: EPUB",
            "- Result: imported",
            "- Title: A Title",
            "- Author: An Author",
            "- Text length: 7000 UTF-16 units, 1200 words",
            "- Chapters: 3",
            "- Headings: 0",
            "- First lines:",
            "  - One",
            "  - Two",
            "- Import time: 1.3 seconds",
            "- Checksum: 00ff00ff00ff00ff",
        ])
    }

    func testAFileImportedWithWarningsSaysSoAndQuotesTheReport() {
        let message = "2 of 14 chapters could not be read: chapter 7 is missing from this EPUB book."
        let section = text(of: imported(dump: dump(report: message)))
        XCTAssertTrue(section.contains("- Result: imported with warnings"))
        XCTAssertTrue(section.contains("- Warnings: \(message)"))
    }

    func testAFileWithoutWarningsHasNoWarningsLine() {
        XCTAssertFalse(text(of: imported()).contains("Warnings:"))
    }

    func testARefusedFileQuotesTheFailureAndHasNoChecksum() {
        let failure = "“bad.epub” could not be imported. Reading its text failed: Not a ZIP archive."
        let entry = CorpusFileEntry(relativePath: "bad.epub", format: "EPUB", outcome: .refused(failure), importSeconds: 0.04)
        XCTAssertEqual(CorpusReportBuilder.section(for: entry, context: context()), [
            "## bad.epub",
            "- Format: EPUB",
            "- Result: refused",
            "- Refusal: \(failure)",
            "- Import time: 0.0 seconds",
            "- Checksum: none",
        ])
    }

    func testAnUnknownKindOfFileIsCalledUnrecognized() {
        let entry = CorpusFileEntry(relativePath: "a.xyz", format: nil, outcome: .refused("no"), importSeconds: nil)
        let section = text(of: entry)
        XCTAssertTrue(section.contains("- Format: unrecognized"))
        XCTAssertFalse(section.contains("Import time"), "No import was attempted, so no time is given")
    }

    func testAnOggFileIsSkippedWithTheReason() {
        let entry = CorpusFileEntry(
            relativePath: "drama/part 1.ogg", format: "Audio",
            outcome: .skipped(CorpusReportBuilder.oggSkipReason), importSeconds: nil
        )
        XCTAssertEqual(CorpusReportBuilder.section(for: entry, context: context()), [
            "## drama/part 1.ogg",
            "- Format: Audio",
            "- Result: skipped",
            "- skipped: Ogg audio is never decoded in the test host",
            "- Checksum: none",
        ])
    }

    func testATimedOutFileSaysHowLongTheLimitWas() {
        let entry = CorpusFileEntry(relativePath: "huge.pdf", format: "PDF", outcome: .timedOut(seconds: 180), importSeconds: 180.04)
        let section = text(of: entry)
        XCTAssertTrue(section.contains("- Result: timed out"))
        XCTAssertTrue(section.contains("timed out after 180 seconds"))
        XCTAssertTrue(section.contains("- Import time: 180.0 seconds"))
    }

    // MARK: - Headings

    func testHeadingsAreListedWithTheirLevels() {
        let headings = [
            DocumentDump.HeadingLine(level: 1, text: "Part One"),
            DocumentDump.HeadingLine(level: 2, text: "Chapter 1"),
        ]
        let lines = CorpusReportBuilder.section(for: imported(dump: dump(headings: headings)), context: context())
        let start = lines.firstIndex(of: "- Headings: 2")
        XCTAssertNotNil(start)
        guard let start, start + 2 < lines.count else { return XCTFail("The headings are missing") }
        XCTAssertEqual(lines[start + 1], "  - level 1: Part One")
        XCTAssertEqual(lines[start + 2], "  - level 2: Chapter 1")
    }

    func testHeadingsAreCappedAt200WithAnAndMoreLine() {
        let headings = (1...250).map { DocumentDump.HeadingLine(level: 2, text: "H\($0)") }
        let lines = CorpusReportBuilder.section(for: imported(dump: dump(headings: headings)), context: context())
        XCTAssertTrue(lines.contains("- Headings: 250"), "The count is of all the headings, not the shown ones")
        XCTAssertEqual(lines.filter { $0.hasPrefix("  - level 2: ") }.count, 200)
        XCTAssertTrue(lines.contains("  - level 2: H200"))
        XCTAssertFalse(lines.contains("  - level 2: H201"))
        XCTAssertTrue(lines.contains("  - and 50 more"))
    }

    func testExactly200HeadingsHaveNoAndMoreLine() {
        let headings = (1...200).map { DocumentDump.HeadingLine(level: 3, text: "H\($0)") }
        let lines = CorpusReportBuilder.section(for: imported(dump: dump(headings: headings)), context: context())
        XCTAssertFalse(lines.contains { $0.contains("and ") && $0.contains(" more") })
    }

    // MARK: - First Lines

    func testFirstLinesStopAtFiveAndAreCutAt120Characters() {
        let long = String(repeating: "x", count: 300)
        let lines = ["1", "2", "3", "4", long, "6", "7"]
        let section = CorpusReportBuilder.section(for: imported(lines: lines), context: context())
        let shown = section.filter { $0.hasPrefix("  - ") && !$0.contains("level") }
        XCTAssertEqual(shown.count, 5, "Only five lines are shown")
        XCTAssertEqual(shown[4], "  - " + String(repeating: "x", count: 120) + "...")
        XCTAssertFalse(section.contains("  - 6"))
    }

    func testALineOf120CharactersIsNotCut() {
        let exact = String(repeating: "y", count: 120)
        let section = CorpusReportBuilder.section(for: imported(lines: [exact]), context: context())
        XCTAssertTrue(section.contains("  - \(exact)"))
    }

    func testABookWithNoTextSaysSo() {
        let section = text(of: imported(lines: []))
        XCTAssertTrue(section.contains("  - (the book has no text)"))
    }

    func testFirstLinesAreTheFirstFiveNonEmptyLinesAcrossChapters() {
        let chapters = ["\n\n  \nAlpha\n\nBeta\n", "Gamma\n   Delta  \nEpsilon\nZeta"]
        XCTAssertEqual(
            CorpusReportBuilder.firstLines(of: chapters),
            ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
        )
        XCTAssertEqual(CorpusReportBuilder.firstLines(of: ["", "\n\n"]), [])
    }

    func testALineThatLooksLikeMarkdownIsNotAHeadingInTheReport() {
        let section = CorpusReportBuilder.section(for: imported(lines: ["# Not a heading"]), context: context())
        XCTAssertFalse(section.contains { $0.hasPrefix("#") && !$0.hasPrefix("## ") })
        XCTAssertTrue(section.contains("  - # Not a heading"))
    }

    // MARK: - Titles and Audio

    func testANewlineInATitleKeepsItOnOneLine() {
        let section = CorpusReportBuilder.section(for: imported(dump: dump(title: "Two\nLines\tand tabs", author: "")), context: context())
        XCTAssertTrue(section.contains("- Title: Two Lines and tabs"))
        XCTAssertTrue(section.contains("- Author: (none)"))
    }

    func testAnAudioBookGivesItsTrackCountAndDuration() {
        let tracks = [
            DocumentDump.Track(title: "One", file: "a.mp3", start: 0, end: 60),
            DocumentDump.Track(title: "Two", file: "b.mp3", start: 0, end: 90.5),
        ]
        let audio = dump(format: "audio", audioDuration: 150.5, tracks: tracks)
        let section = text(of: imported(dump: audio))
        XCTAssertTrue(section.contains("- Tracks: 2"))
        XCTAssertTrue(section.contains("- Audio duration: 150.5 seconds"))
    }

    func testABookWithNoAudioHasNoTrackLines() {
        let section = text(of: imported())
        XCTAssertFalse(section.contains("Tracks:"))
        XCTAssertFalse(section.contains("Audio duration"))
    }

    // MARK: - Counts and Header

    func testTheCountsLineCountsEachResult() {
        let warned = imported("w.epub", dump: dump(report: "one chapter missing"))
        let refused = CorpusFileEntry(relativePath: "r", format: nil, outcome: .refused("no"), importSeconds: 0)
        let skipped = CorpusFileEntry(relativePath: "s.ogg", format: "Audio", outcome: .skipped("Ogg"), importSeconds: nil)
        let entries = [imported("a.epub"), imported("b.epub"), warned, refused, skipped]
        XCTAssertEqual(
            CorpusReportBuilder.countsLine(for: entries),
            "5 files: 2 imported, 1 with warnings, 1 refused, 1 skipped"
        )
    }

    func testTheCountsLineNamesTimeoutsOnlyWhenThereAreSome() {
        let timedOut = CorpusFileEntry(relativePath: "t", format: nil, outcome: .timedOut(seconds: 5), importSeconds: 5)
        XCTAssertEqual(
            CorpusReportBuilder.countsLine(for: [timedOut, imported()]),
            "2 files: 1 imported, 0 with warnings, 0 refused, 0 skipped, 1 timed out"
        )
        XCTAssertEqual(CorpusReportBuilder.countsLine(for: []), "0 files: 0 imported, 0 with warnings, 0 refused, 0 skipped")
    }

    func testTheCountsLineIsOneFilesLineEvenForOneFile() {
        let line = CorpusReportBuilder.countsLine(for: [imported()])
        XCTAssertNotNil(line.range(of: #"^[0-9]+ files: "#, options: .regularExpression))
    }

    func testTheHeaderHasTheTitleBlockAndTheCounts() {
        let report = CorpusReportBuilder.report(context: context(), entries: [imported()])
        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(10)), [
            "# Corpus report",
            "",
            "- Folder: Library Copy",
            "- Date: 2026-10-16",
            "- macOS: Version 26.3",
            "- App build: 0.1.1 (1)",
            "- Status: complete",
            "",
            "1 files: 1 imported, 0 with warnings, 0 refused, 0 skipped",
            "",
        ])
        XCTAssertEqual(lines.dropFirst(10).first, "## book.epub")
        XCTAssertTrue(report.hasSuffix("\n"))
    }

    func testAReportWrittenMidRunSaysHowFarItIs() {
        let report = CorpusReportBuilder.report(context: context(found: 7, complete: false), entries: [imported()])
        XCTAssertTrue(report.contains("- Status: in progress, 1 of 7 files read so far"))
    }

    func testACutRunSaysSo() {
        let cut = CorpusReportBuilder.report(context: context(found: 350, limit: 200), entries: [imported()])
        XCTAssertTrue(cut.contains("- Cut: 350 files were found and only the first 200 are read"))
        let whole = CorpusReportBuilder.report(context: context(found: 200, limit: 200), entries: [imported()])
        XCTAssertFalse(whole.contains("Cut:"))
    }

    // MARK: - Paths

    func testAPathWithASpaceAndAccentsIsKeptWhole() {
        let entry = imported("Résumés/Mädchen im Café 2.epub")
        let section = text(of: entry)
        XCTAssertTrue(section.hasPrefix("## Résumés/Mädchen im Café 2.epub"))
    }

    func testTheReportNeverContainsTheFoldersFullPath() {
        let folder = URL(fileURLWithPath: "/Users/someone/secret/My Books", isDirectory: true)
        let sandbox = "/private/var/folders/zz/xx/T/corpus-sandbox"
        let hidden = [
            CorpusReportContext.HiddenPath(path: folder.path, replacement: "the folder"),
            CorpusReportContext.HiddenPath(path: sandbox, replacement: "the sandbox"),
        ]
        let context = self.context(folderName: folder.lastPathComponent, hidden: hidden)
        let refusal = "The file “a.epub” at \(folder.path)/a.epub and \(sandbox)/0/a.epub could not be read."
        let refused = CorpusFileEntry(relativePath: "a.epub", format: "EPUB", outcome: .refused(refusal), importSeconds: 0.1)
        let warned = imported("b.epub", dump: dump(title: "Under \(folder.path)", report: "Warning at \(sandbox)/1/b.epub"))
        let report = CorpusReportBuilder.report(context: context, entries: [refused, warned])
        XCTAssertTrue(report.contains("- Folder: My Books"))
        XCTAssertFalse(report.contains("/Users/someone/secret"), "The folder's full path must not appear")
        XCTAssertFalse(report.contains("someone"))
        XCTAssertFalse(report.contains(sandbox))
        XCTAssertTrue(report.contains("at the folder/a.epub and the sandbox/0/a.epub"))
    }

    func testTheLongerOfTwoNestedHiddenPathsIsReplacedFirst() {
        let hidden = [
            CorpusReportContext.HiddenPath(path: "/a/b", replacement: "SHORT"),
            CorpusReportContext.HiddenPath(path: "/a/b/c", replacement: "LONG"),
        ]
        XCTAssertEqual(CorpusReportBuilder.clean("see /a/b/c/d and /a/b/e", context(hidden: hidden)), "see LONG/d and SHORT/e")
    }

    // MARK: - Words, Not Marks

    func testNoSectionUsesATableOrEmoji() {
        let entries = [
            imported(),
            CorpusFileEntry(relativePath: "r", format: nil, outcome: .refused("no"), importSeconds: 0),
            CorpusFileEntry(relativePath: "s.ogg", format: "Audio", outcome: .skipped("Ogg"), importSeconds: nil),
            CorpusFileEntry(relativePath: "t", format: "PDF", outcome: .timedOut(seconds: 1), importSeconds: 1),
        ]
        let report = CorpusReportBuilder.report(context: context(found: 4), entries: entries)
        XCTAssertFalse(report.contains("|"), "A table cannot be read as one fact per line")
        XCTAssertTrue(report.unicodeScalars.allSatisfy { $0.value < 0x2000 || $0 == "“" || $0 == "”" })
    }
}
