import Foundation

// MARK: - The Word 97-2003 Reader

/// TextMouth's own reader of Word 97-2003 documents (.doc and the template
/// .dot, FMT47), compiled into both apps. It reads, from the specification
/// [MS-DOC] and the compound file [MS-CFB] beneath it, what the user wants
/// under TextMouth's control: the text, the real heading styles (Heading 1
/// to 9, and paragraph outline levels, which textutil's reading of a
/// document loses), bold and italic, tables, and page breaks. It writes one
/// HTML document in the form `OwnDocumentReaders` describes, which the shared
/// converter turns into the reading text.
///
/// The steps:
/// 1. open the compound file and take its `WordDocument` stream;
/// 2. read the File Information Block (`WordFileInformationBlock`), which
///    refuses a document protected by a password and leaves a Word 6 or
///    Word 95 document to textutil;
/// 3. read the table stream's structures: the piece table (`WordPieceTable`),
///    the style sheet (`WordStyleSheet`), the paragraph and character
///    properties (`WordDocumentProperties`), and the sections
///    (`WordSections`);
/// 4. write the text through the pieces, in order, with `WordHTMLWriter`;
/// 5. take the title and author from the SummaryInformation stream
///    (`WordSummaryInformation`).
///
/// A document is untrusted input: every offset, count, and index it holds is
/// checked, and one that does not fit ends the read with
/// `TextutilConverter.Failure.unreadable`, the sentence the textutil reader
/// gives for a document it cannot read.
///
/// Written from [MS-DOC], [MS-CFB], and [MS-OLEPS], which Microsoft's Open
/// Specification Promise lets anyone implement. Apache POI's HWPF (Apache 2.0)
/// and word-extractor (MIT) were read as maps of the algorithm, never copied.
enum WordDocumentReader {

    // MARK: The Switch

    /// Whether a list's numbers are written as words before their paragraphs
    /// ("A. Heading 1", "2.2.1. Clause"), so that a listener hears them, or
    /// the paragraphs are items of a list whose numbers are not heard, as the
    /// DOCX and rich text readers read a list (the reading text leaves out a
    /// list's markers). Off for now: the user was asked on November 6, 2026
    /// whether numbers should be read aloud (`humanQuestions/2026-11-06.md`,
    /// question 1), and nothing changes until they answer. The words form is
    /// whole and tested: if the answer is yes, this is the one line to change.
    static let speaksListNumbers = false

    /// Whether this platform reads Word 97-2003 documents with this reader:
    /// iOS, which has no textutil, always; the Mac once the reader has been
    /// checked against textutil's reading of the same files
    /// (`WordDocumentComparisonTests`), which it now is.
    static var isOn: Bool { true }

    // MARK: Reading

    /// The HTML document of the Word 97-2003 document at `url`, or nil for a
    /// Word 6 or Word 95 document, which is left to textutil. The file is
    /// held to `DocumentByteLimit`.
    /// - Throws: `PasswordProtectedDocument`, `DocumentTooLargeError`,
    ///   `FileImportError.noTextToRead` for an empty file, and
    ///   `TextutilConverter.Failure.unreadable` for a file that is not a
    ///   readable Word 97-2003 document.
    static func html(of url: URL, includesPages: Bool) throws -> String? {
        try html(from: DocumentByteLimit.contents(of: url), includesPages: includesPages)
    }

    /// `speaksListNumbers` for the document at `url`, passed in so that both
    /// forms are tested.
    static func html(of url: URL, includesPages: Bool, speaksListNumbers: Bool) throws -> String? {
        try html(from: DocumentByteLimit.contents(of: url), includesPages: includesPages, speaksListNumbers: speaksListNumbers)
    }

    /// The HTML document of the Word 97-2003 document in `data`; see
    /// `html(of:includesPages:)`.
    static func html(from data: Data, includesPages: Bool, speaksListNumbers: Bool = WordDocumentReader.speaksListNumbers) throws -> String? {
        do {
            // A document with more page breaks than pages are numbered is
            // read again without any.
            do {
                return try read(data, includesPages: includesPages, speaksListNumbers: speaksListNumbers)
            } catch is WordHTMLWriter.PageLimitExceeded {
                return try read(data, includesPages: false, speaksListNumbers: speaksListNumbers)
            }
        } catch is OLEDamage {
            throw TextutilConverter.Failure.unreadable(.doc)
        }
    }

    /// Reads `data` once.
    private static func read(_ data: Data, includesPages: Bool, speaksListNumbers: Bool) throws -> String? {
        let file = try CompoundFile(data)
        guard let documentData = try file.stream(named: "WordDocument") else {
            throw OLEDamage(reason: "the file has no WordDocument stream")
        }
        let document = OLEBytes(documentData)
        guard let fib = try WordFileInformationBlock.read(from: document) else { return nil }
        // Encrypted, whether by Word's password or by obfuscation: the text
        // cannot be read, and the listener is told what to do.
        guard !fib.isEncrypted else { throw PasswordProtectedDocument() }
        guard let tableData = try file.stream(named: fib.tableStreamName) else {
            throw OLEDamage(reason: "the file has no \(fib.tableStreamName) stream")
        }
        let table = OLEBytes(tableData)

        // The text, through the piece table.
        guard let clx = try fib.range(of: .complexInformation, in: table) else { throw OLEDamage(reason: "the file has no CLX") }
        let pieces = try WordPieceTable(clx: clx, table: table, document: document)
        let textEnd = min(fib.mainTextLength, pieces.characterCount)

        // The styles, and the properties that name them.
        var styles = WordStyleSheet.empty
        if let range = try fib.range(of: .styleSheet, in: table) { styles = try WordStyleSheet(range: range, table: table) }
        var paragraphs = WordFormatRuns<WordParagraphFormat>(runs: [])
        if let range = try fib.range(of: .paragraphBinTable, in: table) {
            paragraphs = try WordDocumentProperties.paragraphRuns(
                binTable: range, table: table, document: document, pieces: pieces, limit: pieces.characterCount
            )
        }
        var characters = WordFormatRuns<WordCharacterFormat>(runs: [])
        if let range = try fib.range(of: .characterBinTable, in: table) {
            characters = try WordDocumentProperties.characterRuns(
                binTable: range, table: table, document: document, pieces: pieces, limit: pieces.characterCount
            )
        }
        // The lists, whose numbers Word does not store in the text. They are
        // a help to the listener and not the text: a list table that does
        // not fit loses the numbers, not the document.
        var lists = WordListTables.none
        let listFormats = try? fib.range(of: .listFormats, in: table)
        let listOverrides = try? fib.range(of: .listOverrides, in: table)
        if listFormats != nil || listOverrides != nil {
            lists = (try? WordListTables(listFormats: listFormats, listOverrides: listOverrides, table: table)) ?? .none
        }
        var sections = WordSections.none
        if let range = try fib.range(of: .sectionTable, in: table) {
            sections = try WordSections(range: range, table: table, document: document)
        }

        // Whether the characters at these positions (in order) are hidden or
        // deleted text, for the notes whose reference marks stand there.
        func isNotShown(_ positions: [Int]) -> [Bool] {
            var characterCursor = characters.cursor()
            var paragraphCursor = paragraphs.cursor()
            return positions.map { position in
                let character = characterCursor.format(at: position) ?? WordCharacterFormat()
                let paragraph = paragraphCursor.format(at: position) ?? WordParagraphFormat()
                return character.isDeleted || styles.hides(character, in: paragraph)
            }
        }

        // The parts of the notes `story` that a person sees a reference to.
        func shownNotes(of story: Range<Int>, references: WordFileInformationBlock.Structure, texts: WordFileInformationBlock.Structure) -> [Range<Int>] {
            WordNotes.shownRanges(
                of: story,
                references: try? fib.range(of: references, in: table),
                texts: try? fib.range(of: texts, in: table),
                in: table, isNotShown: isNotShown
            )
        }

        // Writes the text of the character `ranges` (in order, none going
        // back) and says whether it holds a letter or a digit.
        func write(_ ranges: [Range<Int>]) throws -> (body: String, hasWords: Bool) {
            var writer = WordHTMLWriter(
                styles: styles, sections: sections, includesPages: includesPages,
                outputLimit: Int(DocumentByteLimit.current) * 2, paragraphs: paragraphs, characters: characters,
                lists: lists, numbersAreWords: speaksListNumbers
            )
            for range in ranges {
                try pieces.forEachCharacter(from: range.lowerBound, upTo: range.upperBound, in: document) { position, unit in
                    try writer.add(position: position, unit: unit)
                }
            }
            let body = try writer.finish(endingAt: ranges.last?.upperBound ?? 0)
            return (body, writer.wroteCountedCharacter)
        }

        // The main story is the book. The footnotes, the endnotes, and the
        // text boxes of the main story follow it, in that order, as they
        // follow it in textutil's reading, so their words are not lost: a
        // person reading the document sees them. The headers, the comments,
        // and the text boxes of the headers are left out, since a header
        // would repeat page furniture at the end of the book. Only when the
        // main story holds no words at all (a document whose text is in a
        // header, say) are all the stories after it read, in the order the
        // file keeps them, as textutil reads them.
        let main = 0..<textEnd
        var written = try write([main])
        if !written.hasWords {
            if pieces.characterCount > textEnd { written = try write([0..<pieces.characterCount]) }
        } else {
            // A note is read only if a person would see its reference mark:
            // not when the mark is in hidden or deleted text.
            let stories = try fib.followingStories(limit: pieces.characterCount)
            let following = shownNotes(of: stories.footnotes, references: .footnoteReferences, texts: .footnoteText)
                + shownNotes(of: stories.endnotes, references: .endnoteReferences, texts: .endnoteText)
                + (stories.textBoxes.isEmpty ? [] : [stories.textBoxes])
            if !following.isEmpty { written = try write([main] + following) }
        }
        let body = written.body

        // The names are a convenience: a damaged stream gives none.
        let summary = (try? file.stream(named: "\u{05}SummaryInformation")) ?? nil
        let names = WordSummaryInformation.names(in: summary)
        return Self.page(body: body, title: names.title, author: names.author)
    }

    // MARK: The Document

    /// The HTML document with `body`, naming `title` and `author` in its head
    /// when they are not empty.
    private static func page(body: String, title: String, author: String) -> String {
        var head = "<meta charset=\"utf-8\">"
        if !title.isEmpty { head += "<title>\(WordHTMLWriter.escaped(title))</title>" }
        if !author.isEmpty { head += "<meta name=\"author\" content=\"\(WordHTMLWriter.escaped(author))\">" }
        return "<!DOCTYPE html>\n<html><head>\(head)</head><body>\n\(body)</body></html>\n"
    }
}
