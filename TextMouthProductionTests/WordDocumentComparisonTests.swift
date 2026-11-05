import XCTest
import SwiftSoup
@testable import TextMouth

#if os(macOS)

/// The Word 97-2003 reader against textutil's reading of the same files
/// (FMT47), on every sample in `TestData/format-samples/doc` and `dot`: the
/// check that decides whether the Mac may read .doc with the reader instead
/// of textutil (`WordDocumentReader.isOn`). textutil runs in the tests, as
/// `TextutilPageTests` runs it.
///
/// Both readings are turned into reading text the way an import does, and
/// compared by their words and their headings.
final class WordDocumentComparisonTests: XCTestCase {

    // MARK: - The Samples

    private static let samples = [
        "doc/headings.doc",
        "doc/libreoffice-tdf104239_chapterNumbering.doc",
        "doc/libreoffice-tdf81705_outlineLevel.doc",
        "doc/page-breaks.doc",
        "dot/headings-synthetic.dot",
        "dot/libreoffice-tdf120761_zOrder.dot",
    ]

    /// The words textutil appends at the end of a document's text that the
    /// reader leaves out, by sample. textutil reads a document's headers and
    /// the text boxes of its headers as part of the text, after the body; the
    /// reader reads the body alone, since a header is page furniture that
    /// repeats on every page and would be read aloud at the end of the book.
    private static let wordsOnlyTextutilReads: [String: [String]] = [
        "doc/libreoffice-tdf104239_chapterNumbering.doc": ["Chapter", "numbering"],
        "dot/libreoffice-tdf120761_zOrder.dot": ["Blah", "blah", "blah"],
    ]

    /// The headings textutil's size guess finds that the reader does not,
    /// by sample. "Contents" in the outline-level sample is the title of a
    /// table of contents, set in Word's "TOC Heading" style, whose own outline
    /// level says it is body text; the reader trusts the author's styles,
    /// textutil sees only that the line is larger than the body.
    private static let headingsOnlyTextutilFinds: [String: Set<String>] = [
        "doc/libreoffice-tdf81705_outlineLevel.doc": [" Contents"],
    ]

    // MARK: - Helpers

    /// What an import of the sample makes of it, read by textutil, as the
    /// chapter the Markdown parses to.
    private func textutilChapter(_ sample: String) throws -> Chapter {
        let copy = try copyOfFormatSample(sample)
        // The router sends the sample to textutil even when the Mac reads
        // .doc with the reader.
        let markdown = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            try TextutilDocumentReader.extract(from: copy, bookFormat: .doc, includesPages: true).markdown
        }
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
    }

    /// The same, read by the Word reader and converted as an import converts
    /// a reader's HTML.
    private func readerChapter(_ sample: String) throws -> Chapter {
        let copy = try copyOfFormatSample(sample)
        let html = try XCTUnwrap(WordDocumentReader.html(of: copy, includesPages: true))
        let markdown = try HTMLToMarkdownConverter.convert(
            document: SwiftSoup.parse(html),
            readingFlow: PublicationSemantics.ReadingFlow(source: html),
            includesPages: true
        )
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
    }

    /// The words of `text`: its runs of letters and digits.
    private func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: - The Comparison

    func testTheReaderReadsTextutilsWordsInTheSameOrderOnEverySample() throws {
        var differences: [String] = []
        for sample in Self.samples {
            let expected = words(try textutilChapter(sample).text)
            let actual = words(try readerChapter(sample).text)
            // textutil's extra words come last; the reader does not read them.
            let leftOut = Self.wordsOnlyTextutilReads[sample] ?? []
            guard expected.count >= leftOut.count, Array(expected.suffix(leftOut.count)) == leftOut else {
                differences.append("\(sample): textutil's text does not end with \(leftOut)")
                continue
            }
            let comparable = Array(expected.dropLast(leftOut.count))
            if comparable != actual {
                differences.append("\(sample): textutil \(comparable.count) words, reader \(actual.count): "
                    + "textutil \(comparable.prefix(40)), reader \(actual.prefix(40))")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testTheReaderFindsAtLeastTextutilsHeadings() throws {
        var differences: [String] = []
        for sample in Self.samples {
            let textutil = try textutilChapter(sample).headings.map { "\($0.level): \($0.text)" }
            let reader = try readerChapter(sample).headings.map { "\($0.level): \($0.text)" }
            // Every heading textutil guesses is a heading of the reader's, at
            // any level; a level that differs is listed with the sample.
            let missing = Set(textutil.map { String($0.drop { $0 != " " }) })
                .subtracting(reader.map { String($0.drop { $0 != " " }) })
                .subtracting(Self.headingsOnlyTextutilFinds[sample] ?? [])
            if !missing.isEmpty {
                differences.append("\(sample): headings only textutil finds: \(missing.sorted()); textutil \(textutil), reader \(reader)")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testTheReaderGivesTheSamePagesAsTextutilOnThePageSample() throws {
        let textutil = try textutilChapter("doc/page-breaks.doc")
        let reader = try readerChapter("doc/page-breaks.doc")
        XCTAssertEqual(reader.pages.map(\.label), textutil.pages.map(\.label))
        XCTAssertEqual(reader.pages.map(\.characterOffset), textutil.pages.map(\.characterOffset))
    }
}

#endif
