import XCTest
import SwiftSoup
@testable import TextMouth

/// TextMouth's own RTF reader against textutil's reading of the same files
/// (FMT47), on the Mac, where textutil runs in tests. The Mac keeps textutil
/// until the reader has the same words as textutil in every sample and at
/// least textutil's headings; these tests are that check, and their failure
/// messages list every difference.
final class RTFTextutilComparisonTests: XCTestCase {

    // MARK: - Helpers

    /// The folder textutil writes its hidden output in; every read must leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("RTFComparisonWork")
    }

    /// The Markdown of the file at `url`, read as `format`, as the reading
    /// text is made from textutil's HTML (the reader's own path).
    private func textutilMarkdown(of url: URL, as format: BookFormat) throws -> String {
        try TextutilDocumentReader.$temporaryRoot.withValue(work) {
            try TextutilDocumentReader.extract(from: url, bookFormat: format, includesPages: true).markdown
        }
    }

    /// The Markdown of TextMouth's own reading of the file at `url`, made by
    /// the same converter.
    private func ownMarkdown(of url: URL, as format: TextutilInputFormat) throws -> String {
        let html = try RTFDocumentReader.html(of: url, as: format, includesPages: true)
        return try HTMLToMarkdownConverter.convert(html, includesPages: true)
    }

    /// Markdown without its comments (page markers and heading annotations).
    private func withoutComments(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
    }

    /// The words of `markdown`: runs of letters and digits, in order.
    private func words(of markdown: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in withoutComments(markdown).unicodeScalars {
            if TextutilPageBreaks.isCounted(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The headings of `markdown`, as "level: text".
    private func headings(of markdown: String) -> [String] {
        withoutComments(markdown).split(separator: "\n").compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
            return "\(hashes.count): \(line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces))"
        }
    }

    /// Asserts that the two readings have the same words in the same order
    /// and that TextMouth's has every heading textutil's has, listing each
    /// difference.
    private func assertAsGoodAsTextutil(
        sample path: String,
        format: BookFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let copy = try copyOfFormatSample(path)
        let reader: TextutilInputFormat = format == .rtfd ? .rtfd : .rtf
        let textutil = try textutilMarkdown(of: copy, as: format)
        let own = try ownMarkdown(of: copy, as: reader)

        let textutilWords = words(of: textutil), ownWords = words(of: own)
        let wordDifferences = ownWords.difference(from: textutilWords).map { change -> String in
            switch change {
            case .insert(let offset, let word, _): return "+ \(word) (own word \(offset))"
            case .remove(let offset, let word, _): return "- \(word) (textutil word \(offset))"
            }
        }
        XCTAssertEqual(wordDifferences, [], "\(path): words differ (- textutil only, + own only)", file: file, line: line)

        let textutilHeadings = headings(of: textutil), ownHeadings = headings(of: own)
        let missing = textutilHeadings.filter { !ownHeadings.contains($0) }
        XCTAssertEqual(missing, [], "\(path): textutil's headings that the own reading lacks; own: \(ownHeadings)", file: file, line: line)
    }

    // MARK: - The Samples

    func testHeadingsSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "rtf/headings.rtf", format: .rtf)
    }

    func testPageBreaksSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "rtf/page-breaks.rtf", format: .rtf)
    }

    func testListAndTableSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "rtf/word-list-table.rtf", format: .rtf)
    }

    func testWordStylesSampleMatchesTextutil() throws {
        try assertAsGoodAsTextutil(sample: "rtf/word-styles.rtf", format: .rtf)
    }

    func testRTFDSamplesMatchTextutil() throws {
        try assertAsGoodAsTextutil(sample: "rtfd/headings.rtfd", format: .rtfd)
        try assertAsGoodAsTextutil(sample: "rtfd/with-image.rtfd", format: .rtfd)
    }

    /// The pages: every page break textutil finds, TextMouth's reading finds
    /// too, before the same words; it finds more where the file holds a
    /// \pagebb or a \sect that textutil loses.
    func testPageBreaksAreAtLeastTextutils() throws {
        let copy = try copyOfFormatSample("rtf/page-breaks.rtf")
        let textutil = try textutilMarkdown(of: copy, as: .rtf)
        let own = try ownMarkdown(of: copy, as: .rtf)
        /// The first word after each page marker.
        func firstWords(_ markdown: String) -> [String] {
            markdown.components(separatedBy: "<!-- page: ").dropFirst().compactMap { piece in
                words(of: String(piece.drop { $0 != ">" }.dropFirst())).first
            }
        }
        let ownFirstWords = firstWords(own)
        for word in firstWords(textutil) {
            XCTAssertTrue(ownFirstWords.contains(word), "Textutil begins a page at \(word); own pages begin at \(ownFirstWords)")
        }
        XCTAssertGreaterThanOrEqual(ownFirstWords.count, firstWords(textutil).count)
    }

    // MARK: - What TextMouth Writes

    /// RTF written by TextMouth's export reads as textutil reads it: the same
    /// words, and at least its headings (the writer gives them sizes and
    /// styles both).
    func testTheRTFExportWritersOutputMatchesTextutil() throws {
        let list = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [.paragraph([ExportRun("First item")])]),
            ExportListItem(blocks: [.paragraph([ExportRun("Second item")])])
        ])
        let rtf = try RTFExportWriter.rtf(of: ExportDocument(
            book: ExportBookDetails(title: "Harbour Pilots", author: "Odette Varga"),
            blocks: [
                .heading(ExportHeading(level: 1, runs: [ExportRun("Arrivals")], id: "arrivals")),
                .paragraph([ExportRun("Caf\u{E9} "), ExportRun("bold", isStrong: true), ExportRun(" slanted text, then\nnew line.")]),
                .heading(ExportHeading(level: 2, runs: [ExportRun("Quays")], id: "quays")),
                .list(list),
                .table(ExportTable(rows: [["Port", "Depth"], ["Hull", "9"]], hasHeaderRow: true)),
                .paragraph([ExportRun("The end.")])
            ]
        ))
        let folder = try makeSandboxDirectory("RTFComparisonExport")
        let url = folder.appendingPathComponent("Exported.rtf")
        try Data(rtf.utf8).write(to: url)
        let textutil = try textutilMarkdown(of: url, as: .rtf)
        let own = try ownMarkdown(of: url, as: .rtf)
        XCTAssertEqual(words(of: own), words(of: textutil))
        let missing = headings(of: textutil).filter { !headings(of: own).contains($0) }
        XCTAssertEqual(missing, [], "own headings: \(headings(of: own))")
    }

    // MARK: - Routing

    /// The test hook sends rich text, files and packages alike, to textutil
    /// whatever the reader's switch says, and changes nothing when false.
    func testTheTestHookSendsRichTextToTextutil() throws {
        let file = try copyOfFormatSample("rtf/headings.rtf")
        let package = try copyOfFormatSample("rtfd/headings.rtfd")
        XCTAssertFalse(OwnDocumentReaders.forcesTextutil)
        let forced = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            (
                try OwnDocumentReaders.html(of: file, as: .rtf, includesPages: false),
                try OwnDocumentReaders.html(of: package, as: .rtfd, includesPages: false)
            )
        }
        XCTAssertNil(forced.0)
        XCTAssertNil(forced.1)
        XCTAssertFalse(OwnDocumentReaders.forcesTextutil)
    }

    /// A file named .doc whose bytes are RTF is read by the RTF reader, and
    /// the router hands rich text to it exactly where the switch is on.
    func testAnRTFNamedDocIsReadAsRTF() throws {
        let copy = try copyOfFormatSample("rtf/word-styles.rtf", named: "Saved as RTF.doc")
        XCTAssertTrue(TextutilSourceCheck.beginsAsRTF(copy))
        let html = try RTFDocumentReader.html(of: copy, as: .rtf, includesPages: false)
        XCTAssertEqual(try rtfHeadings(html).first, "1: Chapter One: The Quay")
        // The router answers with the reader's HTML where the reader is on,
        // and with nil, so that textutil reads, where it is not.
        let routed = try OwnDocumentReaders.html(of: copy, as: .rtf, includesPages: false)
        XCTAssertEqual(routed != nil, RTFDocumentReader.isOn)
        if let routed { XCTAssertEqual(routed, html) }
        let package = try copyOfFormatSample("rtfd/headings.rtfd")
        let routedPackage = try OwnDocumentReaders.html(of: package, as: .rtfd, includesPages: false)
        XCTAssertEqual(routedPackage != nil, RTFDocumentReader.isOn)
    }
}
