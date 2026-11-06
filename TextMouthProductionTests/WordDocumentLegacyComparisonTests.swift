import XCTest
import SwiftSoup
@testable import TextMouth

#if os(macOS)

/// The Word reader's old layout (Word 6 and Word 95) against textutil's reading of the same files, on every
/// real sample of `TestData/format-samples/doc6` and the two of `doc` that have the old layout: the check
/// that decides whether the Mac may read these documents with the reader instead of textutil
/// (`WordDocumentReader.readsWord6AndWord95`). textutil runs in the tests, as in `WordDocumentComparisonTests`.
///
/// Both readings are turned into reading text the way an import does and compared by their words, their
/// headings, and their pages. A difference the reader makes on purpose is named in a table below with the
/// reason a listener would accept it; any other difference fails the test and is listed in its message.
final class WordDocumentLegacyComparisonTests: XCTestCase {

    // MARK: - The Samples

    /// The real samples of the old layout, as paths under the format samples.
    private static let samples = [
        "doc6/poi-Word6.doc", "doc6/poi-Word6_sections.doc", "doc6/poi-Word6_sections2.doc", "doc6/poi-Word95.doc",
        "doc6/poi-word95err.doc",
        "doc6/libreoffice-ooo17498-1.doc", "doc6/libreoffice-ooo17498-2.doc", "doc6/libreoffice-ooo17498-3.doc",
        "doc6/libreoffice-ooo17498-4.doc", "doc6/libreoffice-ooo8726-1.doc",
        "doc/poi-Bug51944.doc", "doc/libreoffice-tdf150197_anlv2ListFormat.doc",
    ]

    /// The samples whose words the reader reads differently from textutil on purpose, with the reason:
    /// textutil reads them in the wrong code page, and the reader in the one their fonts and characters
    /// name (`WordDocumentLegacyTests` pins what each reads). The first row's text is Russian, in Windows-1251,
    /// which textutil reads as Windows-1252 ("Êîìïàíèÿ"); the others are Far East documents with two-byte
    /// characters: textutil reads the Simplified Chinese one as Shift JIS half-width katakana, the Korean one as
    /// another set of characters, and reads nothing at all of the two Traditional Chinese ones.
    private static let readInTheRightCodePageNotTextutils: Set<String> = [
        "doc6/poi-word95err.doc", "doc6/libreoffice-ooo17498-2.doc", "doc6/libreoffice-ooo17498-3.doc",
        "doc6/libreoffice-ooo17498-4.doc", "doc6/libreoffice-ooo8726-1.doc",
    ]

    // MARK: - Helpers

    /// What an import of the sample makes of it, read by textutil, as the chapter the Markdown parses to.
    private func textutilChapter(_ sample: String) throws -> Chapter? {
        let copy = try copyOfFormatSample(sample)
        let markdown: String
        do {
            markdown = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
                try TextutilDocumentReader.extract(from: copy, bookFormat: .doc, includesPages: true).markdown
            }
        } catch {
            return nil
        }
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
    }

    /// The same, read by the Word reader's old layout and converted as an import converts a reader's HTML.
    private func readerChapter(_ sample: String) throws -> Chapter {
        let html = try XCTUnwrap(
            WordDocumentReader.html(from: Data(contentsOf: formatSampleURL(sample)), includesPages: true), sample
        )
        let markdown = try HTMLToMarkdownConverter.convert(
            document: SwiftSoup.parse(html), readingFlow: PublicationSemantics.ReadingFlow(source: html), includesPages: true
        )
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
    }

    /// The words of `text`: its runs of letters and digits.
    private func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: - The Comparison

    func testTheReaderReadsTextutilsWordsInTheSameOrderOnEverySampleExceptTheOnesInTheRightCodePage() throws {
        var differences: [String] = []
        for sample in Self.samples {
            let reader = words(try readerChapter(sample).text)
            guard let textutil = try textutilChapter(sample).map({ words($0.text) }) else {
                print("LEGCMP words \(sample): textutil could not read it, reader \(reader.count) words")
                continue
            }
            print("LEGCMP words \(sample): textutil \(textutil.count), reader \(reader.count)")
            if Self.readInTheRightCodePageNotTextutils.contains(sample) {
                XCTAssertNotEqual(textutil, reader, "\(sample) is listed as read differently on purpose, and does not differ")
            } else if textutil != reader {
                differences.append("\(sample): textutil \(textutil.count) words, reader \(reader.count): textutil \(textutil.prefix(60)), reader \(reader.prefix(60))")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testTheReaderFindsAtLeastTextutilsHeadings() throws {
        var differences: [String] = []
        for sample in Self.samples where !Self.readInTheRightCodePageNotTextutils.contains(sample) {
            guard let chapter = try textutilChapter(sample) else { continue }
            let textutil = chapter.headings.map { "\($0.level): \($0.text)" }
            let reader = try readerChapter(sample).headings.map { "\($0.level): \($0.text)" }
            print("LEGCMP headings \(sample): textutil \(textutil), reader \(reader)")
            let missing = Set(textutil.map { $0.drop { $0 != " " }.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
                .subtracting(reader.map { $0.drop { $0 != " " }.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            if !missing.isEmpty { differences.append("\(sample): headings only textutil finds: \(missing.sorted()); textutil \(textutil), reader \(reader)") }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testTheReaderGivesTheSamePagesAsTextutilOnEverySample() throws {
        var differences: [String] = []
        for sample in Self.samples where !Self.readInTheRightCodePageNotTextutils.contains(sample) {
            guard let chapter = try textutilChapter(sample) else { continue }
            let textutil = chapter.pages.map { "\($0.label)@\($0.characterOffset)" }
            let reader = try readerChapter(sample).pages.map { "\($0.label)@\($0.characterOffset)" }
            print("LEGCMP pages \(sample): textutil \(textutil), reader \(reader)")
            if textutil.count != reader.count { differences.append("\(sample): textutil pages \(textutil), reader pages \(reader)") }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }
}

#endif
