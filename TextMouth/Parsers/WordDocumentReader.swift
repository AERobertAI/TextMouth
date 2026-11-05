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

    /// Whether this platform reads Word 97-2003 documents with this reader:
    /// iOS, which has no textutil, always; the Mac once the reader has been
    /// checked against textutil's reading of the same files.
    static var isOn: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

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

    /// The HTML document of the Word 97-2003 document in `data`; see
    /// `html(of:includesPages:)`.
    static func html(from data: Data, includesPages: Bool) throws -> String? {
        do {
            // A document with more page breaks than pages are numbered is
            // read again without any.
            do {
                return try read(data, includesPages: includesPages)
            } catch is WordHTMLWriter.PageLimitExceeded {
                return try read(data, includesPages: false)
            }
        } catch is OLEDamage {
            throw TextutilConverter.Failure.unreadable(.doc)
        }
    }

    /// Reads `data` once.
    private static func read(_ data: Data, includesPages: Bool) throws -> String? {
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
                binTable: range, table: table, document: document, pieces: pieces, styles: styles, limit: pieces.characterCount
            )
        }
        var characters = WordFormatRuns<WordCharacterFormat>(runs: [])
        if let range = try fib.range(of: .characterBinTable, in: table) {
            characters = try WordDocumentProperties.characterRuns(
                binTable: range, table: table, document: document, pieces: pieces, styles: styles, limit: pieces.characterCount
            )
        }
        var sections = WordSections.none
        if let range = try fib.range(of: .sectionTable, in: table) {
            sections = try WordSections(range: range, table: table, document: document)
        }

        // Writes the text up to character `end` and says whether it holds a
        // letter or a digit.
        func write(upTo end: Int) throws -> (body: String, hasWords: Bool) {
            var writer = WordHTMLWriter(
                styles: styles, sections: sections, includesPages: includesPages,
                outputLimit: Int(DocumentByteLimit.current) * 2, paragraphs: paragraphs, characters: characters
            )
            try pieces.forEachCharacter(upTo: end, in: document) { position, unit in
                try writer.add(position: position, unit: unit)
            }
            let body = try writer.finish(endingAt: end)
            return (body, writer.wroteCountedCharacter)
        }

        // The main story, which is the book. Only when it holds no words at
        // all (a document whose text is in a text box, or a header) are the
        // stories after it read too, in the order the file keeps them
        // (footnotes, headers, comments, endnotes, text boxes, header text
        // boxes), as textutil reads them. A document with words in its main
        // story never reads its headers: they would repeat page furniture at
        // the end of the book.
        var written = try write(upTo: textEnd)
        if !written.hasWords, pieces.characterCount > textEnd {
            written = try write(upTo: pieces.characterCount)
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
