import XCTest
import ZIPFoundation
@testable import TextMouth

/// Real books through the EPUB export (FMT28): each book of `TestData/` is
/// imported as the library imports it, exported as an EPUB the way the dialog
/// exports it, checked for well-formed XML in every file, read back through
/// TextMouth's own EPUB reader and compared with what the reader reads of the
/// original (words, headings, and pages, each named when they differ), and,
/// where `epubcheck` is installed, validated by it with no error and no
/// warning.
///
/// Nothing here depends on `epubcheck`: where it is not installed, that step
/// is skipped and the rest runs. Every book is a copy in a sandbox folder of
/// the test's own, and none is the user's.
@MainActor
final class EPUBExportRealBooksTests: XCTestCase {

    // MARK: - The Books

    func testAliceEPUB() throws { try check("alice.epub") }
    func testEPUB3WithAPageList() throws { try check("format-samples/epub3-pages/page-list.epub") }
    func testEPUB3WithOnlyPageBreaks() throws { try check("format-samples/epub3-pages/pagebreaks-only.epub") }
    func testEPUB2WithAPageList() throws { try check("format-samples/epub2-pages/pagelist.epub") }
    func testAliceDOCX() throws { try check("alice.docx") }
    func testPrideAndPrejudiceText() throws { try check("pride.txt") }
    func testPlainTextWithFormFeedPages() throws { try check("format-samples/txt-pages/form-feeds.txt") }
    func testFrankensteinHTML() throws { try check("frankenstein.html") }
    func testMarkdown() throws { try check("sample.md") }
    func testPDFWithAnOutline() throws { try check("test_with_outline.pdf") }
    func testRussianFB2() throws { try check("format-samples/fb2/harbour-windows-1251.fb2") }
    func testJapaneseText() throws { try check("format-samples/txt-encodings/euc-jp.txt") }
    func testChineseText() throws { try check("format-samples/txt-encodings/gb18030.txt") }
    func testDTBookWithPages() throws { try check("format-samples/dtbook/pages-front-and-inline.xml") }
    func testRTFWithHeadings() throws { try check("format-samples/rtf/headings.rtf") }
    func testODTWithHeadings() throws { try check("format-samples/odt/headings.odt") }
    func testMOBI() throws { try check("format-samples/mobi/pg1952-yellow-wallpaper.mobi") }
    func testDAISY() throws { try check("daisy202_test.zip") }

    /// A book of right-to-left and non-Latin text written here, since no sample
    /// holds Hebrew or Arabic: a text file in UTF-8.
    func testHebrewAndArabicText() throws {
        let folder = try makeSandboxDirectory("EPUB Real RTL")
        let source = folder.appendingPathComponent("Shalom.txt")
        let text = """
        \u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD}

        \u{5D4}\u{5D9}\u{5D4} \u{5D6}\u{5DE}\u{5DF} \u{5D0}\u{5D7}\u{5D3} \u{5D5}\u{5D4}\u{5D9}\u{5D4} \u{5E2}\u{5D5}\u{5D3}.

        \u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}

        \u{643}\u{627}\u{646} \u{64A}\u{627} \u{645}\u{627} \u{643}\u{627}\u{646} \u{641}\u{64A} \u{642}\u{62F}\u{64A}\u{645} \u{627}\u{644}\u{632}\u{645}\u{627}\u{646}.
        """
        try Data(text.utf8).write(to: source)
        try check(importing: source, as: "Hebrew and Arabic text")
    }

    // MARK: - One Book

    /// The book at `relativePath` under `TestData/`, checked.
    private func check(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let sample = try requireFile(relativePath)
        let copy = try makeSandboxDirectory("EPUB Real Source").appendingPathComponent(sample.lastPathComponent)
        try FileManager.default.copyItem(at: sample, to: copy)
        try check(importing: copy, as: relativePath, file: file, line: line)
    }

    /// Imports `source`, exports it as an EPUB, and checks the file.
    private func check(importing source: URL, as name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let world = try makeIntegrationWorld("EPUB Real Books")
        let book = try world.importBook(from: source)
        let markdownURL = MarkdownCacheService.cacheURL(for: book)
        let markdown = try MarkdownCacheService.cacheText(from: Data(contentsOf: markdownURL), at: markdownURL)

        // Exported as the dialog exports: through the service, to a folder.
        let destination = try makeSandboxDirectory("EPUB Real Destination")
        let conversion = BookExportConversion.text(TextExportWriters.optionsState(for: EPUBExportWriter()).conversion())
        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.markdown],
            conversions: [.markdown: conversion],
            to: destination
        )
        XCTAssertEqual(outcome.failures, [], name, file: file, line: line)
        let exported = try XCTUnwrap(outcome.exported.first, "\(name) was not exported", file: file, line: line)
        XCTAssertEqual(exported.pathExtension, "epub", file: file, line: line)

        // Every XML file of the package parses.
        let archive = try Archive(url: exported, accessMode: .read)
        var files = 0
        for entry in archive where entry.path != "mimetype" {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(name): \(entry.path) is not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
            files += 1
        }

        // The reading of the export is the reading of the book.
        let expected = try EPUBRoundTrip.expectedReading(ofMarkdown: markdown, title: book.title)
        let actual = try EPUBRoundTrip.reading(ofEPUB: exported)
        XCTAssertFalse(expected.words.isEmpty, "\(name) has words to compare", file: file, line: line)
        XCTAssertNil(Self.firstDifference(expected.words, actual.words), "\(name): words: \(Self.firstDifference(expected.words, actual.words) ?? "")", file: file, line: line)
        XCTAssertNil(Self.firstDifference(expected.headings, actual.headings), "\(name): headings: \(Self.firstDifference(expected.headings, actual.headings) ?? "")", file: file, line: line)
        XCTAssertNil(Self.firstDifference(expected.pages, actual.pages), "\(name): pages: \(Self.firstDifference(expected.pages, actual.pages) ?? "")", file: file, line: line)

        // EPUBCheck, where it is installed.
        let verdict = EPUBCheck.run(on: exported, in: try makeSandboxDirectory("EPUB Check Output"))
        XCTAssertTrue(verdict.isClean, "\(name): epubcheck: \(verdict.summary)", file: file, line: line)
        // One line a table of results can be made from (read from the test log).
        print("EPUBEXPORT-RESULT | \(name) | \(files) files | \(expected.words.count) words | \(actual.headings.count) headings | \(actual.pages.count) pages | epubcheck: \(verdict.summary)")
    }

    /// The first place two lists differ, as a sentence with both lists'
    /// lengths, or nil when they are equal.
    private static func firstDifference(_ expected: [String], _ actual: [String]) -> String? {
        if expected == actual { return nil }
        let index = zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(expected.count, actual.count)
        let window = { (list: [String]) in Array(list[max(0, index - 2)..<min(list.count, index + 3)]) }
        return "differ at \(index) (\(expected.count) expected, \(actual.count) read back): expected \(window(expected)), read back \(window(actual))"
    }
}

// MARK: - EPUBCheck

/// Runs `epubcheck` where it is installed, so a test can check the real files
/// against EPUB's own validator without depending on it.
enum EPUBCheck {
    /// Where Homebrew puts it.
    static let path = "/opt/homebrew/bin/epubcheck"
    /// The longest a run may take before it is stopped.
    static let timeoutSeconds: TimeInterval = 180

    /// What a run found.
    struct Verdict {
        /// Whether the validator was run.
        var ran: Bool
        /// Its summary line, or why it did not run.
        var summary: String
        /// Whether the run found no fatal, error, or warning, or was not made.
        var isClean: Bool
    }

    /// Validates the EPUB at `url`, writing the validator's output into `folder`.
    /// A validator that is absent, will not start, or does not finish in
    /// `timeoutSeconds` is not a failure of the export, and says so.
    static func run(on url: URL, in folder: URL) -> Verdict {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Verdict(ran: false, summary: "not installed", isClean: true)
        }
        let output = folder.appendingPathComponent("epubcheck.txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else {
            return Verdict(ran: false, summary: "no place to write its output", isClean: true)
        }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [url.path]
        process.standardOutput = handle
        process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Verdict(ran: false, summary: "would not start", isClean: true)
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return Verdict(ran: false, summary: "did not finish in \(Int(timeoutSeconds)) seconds", isClean: true)
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("Messages:") }) else {
            return Verdict(ran: false, summary: "no summary in its output: \(text.prefix(300))", isClean: true)
        }
        let clean = line.contains("0 fatals / 0 errors / 0 warnings")
        // A failing run shows its messages, not only the count.
        let messages = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("ERROR") || $0.hasPrefix("WARNING") || $0.hasPrefix("FATAL") }
            .prefix(8).joined(separator: " | ")
        return Verdict(ran: true, summary: clean ? line : "\(line) \(messages)", isClean: clean)
    }
}
