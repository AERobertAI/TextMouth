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
/// compared by their words, their headings, and their pages. A difference
/// that the reader makes on purpose is named in a table below, with the
/// reason a listener would accept; any other difference fails the test and
/// is listed in its message.
final class WordDocumentComparisonTests: XCTestCase {

    // MARK: - The Samples

    /// The samples the reader leaves to textutil (it returns nil): Word 6 and
    /// Word 95 documents, whose older layout [MS-DOC] does not describe.
    private static let leftToTextutil: Set<String> = [
        "doc/libreoffice-tdf150197_anlv2ListFormat.doc",
        // wIdent 0xA699 and nFib 0x68: a layout of Word 95 or older.
        "doc/poi-Bug51944.doc",
    ]

    /// Every sample of the `doc` and `dot` folders, as "folder/name".
    private func allSamples() throws -> [String] {
        try ["doc", "dot"].flatMap { folder -> [String] in
            let names = try FileManager.default.contentsOfDirectory(atPath: formatSampleURL(folder).path)
            return names.filter { !$0.hasPrefix(".") }.sorted().map { "\(folder)/\($0)" }
        }
    }

    // MARK: - Known Differences

    /// The words textutil puts at the end of a document's text that the
    /// reader leaves out, by sample: the text of its headers. A header is page
    /// furniture that repeats on every page, and read once at the end of the
    /// book it would be noise; the reader reads the body (with its footnotes,
    /// endnotes, and text boxes), and reads the headers and the text boxes of
    /// the headers only when the body holds no words at all.
    private static let wordsOnlyTextutilReads: [String: [String]] = [
        "doc/libreoffice-tdf104239_chapterNumbering.doc": ["Chapter", "numbering"],
        // Its header holds a PAGE field, whose instruction textutil reads as a word too.
        "doc/libreoffice-tdf139495_tinyHeader.doc": ["Tiny", "header", "PAGE", "PAGE", "1"],
        // The first-page header of the section that hides it, and the one it
        // inherits, read once each at the end.
        "doc/libreoffice-fdo77844.doc": [
            "This", "is", "a", "first", "page", "header", "which", "should", "be", "hidden", "This", "is", "a", "first",
            "page", "header", "in", "section", "1", "but", "hidden", "there", "inherited", "by", "section", "2", "and",
            "shown", "there",
        ],
    ]

    /// The runs of words inside a document's text that textutil reads and the
    /// reader does not, by sample: the instructions of fields. A field's code
    /// (TITLE, SAVEDATE, and the switch MERGEFORMAT) is never words to be
    /// heard; the reader keeps the field's result alone, as Word shows it,
    /// and textutil's cleaning of instructions misses these forms.
    private static let instructionWordsOnlyTextutilReads: [String: [[String]]] = [
        "doc/libreoffice-tdf98284_softLockedFields.doc": [
            ["TITLE", "MERGEFORMAT"], ["SAVEDATE", "MERGEFORMAT"], ["LASTSAVEDBY", "MERGEFORMAT"], ["PRINTDATE", "MERGEFORMAT"],
        ],
        // The instruction of the field that anchors each drawing (SHAPE).
        "doc/poi-textboxes.doc": [["SHAPE"], ["SHAPE"]],
    ]

    /// The headings textutil's size guess finds that the reader does not, by
    /// sample. "Contents" in the outline-level sample is the title of a table
    /// of contents, set in Word's "TOC Heading" style, whose own outline level
    /// says it is body text; the reader trusts the author's styles, textutil
    /// sees only that the line is larger than the body.
    ///
    /// The other known difference is the header text textutil appends (above),
    /// which its size guess then reads as headings.
    ///
    /// In the fast-saved POI sample a form's company line is bold and larger
    /// than the body in the first of two identical forms, where textutil
    /// guesses it to be a heading, and Heading 1 only through the piece
    /// modifiers (`Pcd.prm`) of its paragraph mark in the second, which the
    /// reader reads and textutil does not (it shows that line as body text).
    /// The document therefore has a real heading, so the reader makes no
    /// guess by size, and the first form's line is a bold paragraph.
    ///
    /// The whole body of the text box sample is the one cell of a table that
    /// lays the page out, and the reader never guesses a heading inside a
    /// table, where a larger or bold line is as likely a cell's label as a
    /// heading; textutil guesses the title and the two bold lines of the
    /// signature.
    private static let headingsOnlyTextutilFinds: [String: Set<String>] = [
        "doc/libreoffice-tdf81705_outlineLevel.doc": ["Contents"],
        "doc/libreoffice-tdf139495_tinyHeader.doc": ["Tiny header", "PAGE", "PAGE 1"],
        "doc/poi-rasp.doc": ["Открытое акционерное общество «ХХХХХХХХХХХ»"],
        "doc/poi-textboxes.doc": ["INFORMACJA O WYBORZE NAJKORZYSTNIEJSZEJ OFERTY", "Wójt Gminy", "mgr inż. Jacek Brygman"],
    ]

    /// The numbers the reader writes at the start of paragraphs that Word
    /// numbers by list formatting when `WordDocumentReader.speaksListNumbers`
    /// is on, in the order they come, by sample. Word stores no number in
    /// such a paragraph's text and textutil reads none; the reader then writes
    /// the level's own number text ("A.", "2.2.1.") as the first words of the
    /// paragraph. By default (the switch off) the reader writes none of them
    /// and the samples read as textutil's words; the words form is compared
    /// by `testWithNumbersAsWordsTheReaderReadsTextutilsWordsAfterItsNumbers`,
    /// which takes each of these off the front of its paragraph and requires
    /// the rest to be textutil's words; a number missing from the reader's
    /// text, or left over, fails it. (Bullets add no words.)
    private static let listNumbersOnlyReaderReads: [String: [String]] = [
        "doc/libreoffice-tdf104239_chapterNumbering.doc": ["A.", "I.", "a.", "i.", "A.I.a.i..1"],
        "doc/libreoffice-list-nolevel.doc": ["1.", "1.1", "2.", "2.1"],
        "doc/libreoffice-tdf106541_chapterNumbering.doc": ["1", "1.1", "2", "2.1"],
        "doc/poi-lists.doc": ["1.", "2.", "3.", "1.", "2.", "2.1.", "2.2.", "2.2.1.", "2.2.2.", "2.2.2.1.", "2.2.3.", "3."],
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
    /// a reader's HTML; nil when the reader leaves the sample to textutil.
    private func readerChapter(_ sample: String, numbersAreWords: Bool = WordDocumentReader.speaksListNumbers) throws -> Chapter? {
        let copy = try copyOfFormatSample(sample)
        guard let html = try WordDocumentReader.html(of: copy, includesPages: true, speaksListNumbers: numbersAreWords) else { return nil }
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

    /// The words of the reader's reading of `sample` without the list
    /// numbers it writes (`listNumbersOnlyReaderReads`).
    private func readerWords(_ sample: String, _ chapter: Chapter, numbersAreWords: Bool = WordDocumentReader.speaksListNumbers) -> [String] {
        var numbers = numbersAreWords ? Self.listNumbersOnlyReaderReads[sample] ?? [] : []
        guard !numbers.isEmpty else { return words(chapter.text) }
        var paragraphs: [String] = []
        for paragraph in chapter.text.components(separatedBy: "\n\n") {
            var text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = numbers.first, text.hasPrefix(number + " ") {
                text = String(text.dropFirst(number.count + 1))
                numbers.removeFirst()
            }
            paragraphs.append(text)
        }
        XCTAssertEqual(numbers, [], "\(sample): list numbers the reader did not write")
        return words(paragraphs.joined(separator: " "))
    }

    /// The words of a heading line such as "2: Tiny  header", without its
    /// level, with every run of white space as one space, and without the
    /// list number `sample`'s reading puts before it.
    private func headingText(_ line: String, in sample: String) -> String {
        let text = line.drop { $0 != " " }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for number in WordDocumentReader.speaksListNumbers ? Self.listNumbersOnlyReaderReads[sample] ?? [] : [] where text.hasPrefix(number + " ") {
            return String(text.dropFirst(number.count + 1))
        }
        return text
    }

    /// The pages of `chapter` as "label@offset" lines.
    private func pageLines(_ chapter: Chapter) -> [String] {
        chapter.pages.map { "\($0.label)@\($0.characterOffset)" }
    }

    // MARK: - The Comparison

    func testTheSamplesTheReaderLeavesToTextutilAreExactlyTheListedOnes() throws {
        var left: Set<String> = []
        for sample in try allSamples() where try readerChapter(sample) == nil { left.insert(sample) }
        XCTAssertEqual(left, Self.leftToTextutil)
    }

    func testTheReaderReadsTextutilsWordsInTheSameOrderOnEverySample() throws {
        var differences: [String] = []
        for sample in try allSamples() where !Self.leftToTextutil.contains(sample) {
            let expected = words(try textutilChapter(sample).text)
            let actual = readerWords(sample, try XCTUnwrap(readerChapter(sample)))
            // textutil's extra words come last; the reader does not read them.
            let leftOut = Self.wordsOnlyTextutilReads[sample] ?? []
            guard expected.count >= leftOut.count, Array(expected.suffix(leftOut.count)) == leftOut else {
                differences.append("\(sample): textutil's text does not end with \(leftOut)")
                continue
            }
            var comparable = Array(expected.dropLast(leftOut.count))
            // The runs of field instructions textutil reads, taken out once each.
            for run in Self.instructionWordsOnlyTextutilReads[sample] ?? [] {
                guard let start = comparable.indices.first(where: { comparable[$0...].starts(with: run) }) else {
                    differences.append("\(sample): textutil's text lacks the instruction \(run)")
                    continue
                }
                comparable.removeSubrange(start..<start + run.count)
            }
            print("DOCCMP words \(sample): textutil \(comparable.count), reader \(actual.count)")
            if comparable != actual {
                differences.append("\(sample): textutil \(comparable.count) words, reader \(actual.count): "
                    + "textutil \(comparable.prefix(60)), reader \(actual.prefix(60))")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testWithNumbersAsWordsTheReaderReadsTextutilsWordsAfterItsNumbers() throws {
        // The words form of the list numbers, whatever the switch is: every
        // other word is textutil's, in order, and every number is there.
        for sample in Self.listNumbersOnlyReaderReads.keys.sorted() {
            let leftOut = Self.wordsOnlyTextutilReads[sample] ?? []
            let expected = Array(words(try textutilChapter(sample).text).dropLast(leftOut.count))
            let chapter = try XCTUnwrap(readerChapter(sample, numbersAreWords: true))
            XCTAssertEqual(readerWords(sample, chapter, numbersAreWords: true), expected, sample)
        }
    }

    func testTheReaderFindsAtLeastTextutilsHeadings() throws {
        var differences: [String] = []
        for sample in try allSamples() where !Self.leftToTextutil.contains(sample) {
            let textutil = try textutilChapter(sample).headings.map { "\($0.level): \($0.text)" }
            let reader = try XCTUnwrap(readerChapter(sample)).headings.map { "\($0.level): \($0.text)" }
            print("DOCCMP headings \(sample): textutil \(textutil), reader \(reader)")
            // Every heading textutil guesses is a heading of the reader's, at
            // any level; a level that differs is listed with the sample.
            let missing = Set(textutil.map { headingText($0, in: sample) })
                .subtracting(reader.map { headingText($0, in: sample) })
                .subtracting(Self.headingsOnlyTextutilFinds[sample] ?? [])
            if !missing.isEmpty {
                differences.append("\(sample): headings only textutil finds: \(missing.sorted()); textutil \(textutil), reader \(reader)")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }

    func testTheReaderGivesTheSamePagesAsTextutilOnEverySample() throws {
        var differences: [String] = []
        for sample in try allSamples() where !Self.leftToTextutil.contains(sample) {
            let textutil = pageLines(try textutilChapter(sample))
            let reader = pageLines(try XCTUnwrap(readerChapter(sample)))
            print("DOCCMP pages \(sample): textutil \(textutil), reader \(reader)")
            if textutil.count != reader.count {
                differences.append("\(sample): textutil pages \(textutil), reader pages \(reader)")
            }
        }
        XCTAssertEqual(differences, [], differences.joined(separator: "\n"))
    }
}

#endif
