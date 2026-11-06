import Foundation

// MARK: - The Word 97-2003 Reader

/// TextMouth's own reader of Word 97-2003 documents (.doc and the template
/// .dot, FMT47), compiled into both apps. It reads, from the specification
/// [MS-DOC] and the compound file [MS-CFB] beneath it, what the user wants
/// under TextMouth's control: the text, the real heading styles (Heading 1
/// to 9, and paragraph outline levels, which textutil's reading of a
/// document loses), bold and italic, hidden text and tracked deletions (not
/// read), lists, tables, footnotes, endnotes, text boxes, and page breaks. It writes one
/// HTML document in the form `OwnDocumentReaders` describes, which the shared
/// converter turns into the reading text.
///
/// The steps:
/// 1. open the compound file and take its `WordDocument` stream;
/// 2. read the File Information Block (`WordFileInformationBlock`), which
///    refuses a document protected by a password, and says whether the
///    document is Word 97's layout or Word 6's and Word 95's (their
///    structures are in the WordDocument stream itself, the text in a code
///    page, the properties in another form: `WordLegacySprm`); a document
///    older than Word 6 is left to textutil;
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

    /// Whether this platform reads Word 6 and Word 95 documents with this
    /// reader: iOS, which has no textutil, always; the Mac keeps textutil for
    /// them until the reader has been checked against textutil's reading of
    /// the same files (`WordDocumentComparisonTests`), which the branch that
    /// turns this on does. `OwnDocumentReaders` asks it; the reader's own
    /// entry points read the old layout whatever it says, so that the tests
    /// can.
    static var readsWord6AndWord95: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// How many characters are written between two asks whether the import
    /// was cancelled (`ImportCancellation`).
    private static let charactersBetweenCancellationChecks = 4096

    // MARK: Reading

    /// The HTML document of the Word 6 to Word 2003 document at `url`, or nil
    /// for one older than Word 6, which is left to textutil. The file is
    /// held to `DocumentByteLimit`.
    /// - Throws: `PasswordProtectedDocument`, `DocumentTooLargeError`,
    ///   `FileImportError.noTextToRead` for an empty file, and
    ///   `TextutilConverter.Failure.unreadable` for a file that is not a
    ///   readable Word 97-2003 document.
    static func html(of url: URL, includesPages: Bool, readsOldLayout: Bool = true) throws -> String? {
        try html(from: DocumentByteLimit.contents(of: url), includesPages: includesPages, readsOldLayout: readsOldLayout)
    }

    /// `speaksListNumbers` for the document at `url`, passed in so that both
    /// forms are tested.
    static func html(of url: URL, includesPages: Bool, speaksListNumbers: Bool) throws -> String? {
        try html(from: DocumentByteLimit.contents(of: url), includesPages: includesPages, speaksListNumbers: speaksListNumbers)
    }

    /// The HTML document of the Word 97-2003 document in `data`; see
    /// `html(of:includesPages:)`.
    static func html(
        from data: Data, includesPages: Bool, speaksListNumbers: Bool = WordDocumentReader.speaksListNumbers,
        readsOldLayout: Bool = true
    ) throws -> String? {
        do {
            // A document with more page breaks than pages are numbered is
            // read again without any.
            do {
                return try read(data, includesPages: includesPages, speaksListNumbers: speaksListNumbers, readsOldLayout: readsOldLayout)
            } catch is WordHTMLWriter.PageLimitExceeded {
                return try read(data, includesPages: false, speaksListNumbers: speaksListNumbers, readsOldLayout: readsOldLayout)
            }
        } catch is OLEDamage {
            throw TextutilConverter.Failure.unreadable(.doc)
        }
    }

    /// Reads `data` once.
    private static func read(_ data: Data, includesPages: Bool, speaksListNumbers: Bool, readsOldLayout: Bool) throws -> String? {
        let file = try CompoundFile(data)
        guard let documentData = try file.stream(named: "WordDocument") else {
            throw OLEDamage(reason: "the file has no WordDocument stream")
        }
        let document = OLEBytes(documentData)
        guard let fib = try WordFileInformationBlock.read(from: document) else { return nil }
        // A Word 6 or Word 95 document is left to textutil where the platform says so.
        guard fib.layout == .modern || readsOldLayout else { return nil }
        // Encrypted, whether by Word's password or by obfuscation: the text
        // cannot be read, and the listener is told what to do.
        guard !fib.isEncrypted else { throw PasswordProtectedDocument() }
        try ImportCancellation.throwIfCancelled()

        // Where the structures are: Word 97 keeps them in a table stream; Word 6
        // and Word 95 in the WordDocument stream itself, in properties of
        // another form (`dialect`) and text in a code page.
        let dialect: WordSprm.Dialect = fib.layout == .modern ? .modern : .legacy
        let table: OLEBytes
        let pieces: WordPieceTable
        // How a Word 6 or Word 95 document's characters are read; nil for Word 97's.
        var legacyCharacters: WordLegacyCharacters?
        switch fib.layout {
        case .modern:
            guard let tableData = try file.stream(named: fib.tableStreamName) else {
                throw OLEDamage(reason: "the file has no \(fib.tableStreamName) stream")
            }
            table = OLEBytes(tableData)
            // The text, through the piece table.
            guard let clx = try fib.range(of: .complexInformation, in: table) else { throw OLEDamage(reason: "the file has no CLX") }
            pieces = try WordPieceTable(clx: clx, table: table, document: document)
        case .legacy:
            table = document
            let characters = WordLegacyCharacters.characters(of: fib, in: document)
            legacyCharacters = characters
            // A document saved with Fast Save has a piece table; one saved in
            // full has its text in one piece between two offsets of the FIB.
            if fib.hasPieceTable, let clx = try fib.range(of: .complexInformation, in: table) {
                pieces = try WordPieceTable(clx: clx, table: table, document: document, characters: characters)
            } else {
                pieces = try WordPieceTable(contiguous: fib.legacyText, document: document, characters: characters)
            }
        }
        let textEnd = min(fib.mainTextLength, pieces.characterCount)

        // The formatting of a Word 6 or Word 95 document is a help to the listener and not the
        // text: a table that does not fit loses its formatting, not the document, as textutil
        // reads damaged files of this age. (Word 97's tables throw, as they always did.)
        func lenient<Value>(_ read: () throws -> Value, else fallback: Value) throws -> Value {
            guard fib.layout == .legacy else { return try read() }
            do { return try read() } catch is OLEDamage { return fallback }
        }

        // How many pages of a bin table the FIB says the file holds, for a document saved in full: the
        // pages beyond the last the table lists follow it. (A Fast Save document's pieces say where they are.)
        func followingPages(of structure: WordFileInformationBlock.Structure) -> Int {
            fib.hasPieceTable ? 0 : fib.declaredPageCount(of: structure)
        }

        // The styles, and the properties that name them.
        let styles = try lenient({ () -> WordStyleSheet in
            guard let range = try fib.range(of: .styleSheet, in: table) else { return .empty }
            return fib.layout == .modern ? try WordStyleSheet(range: range, table: table) : try WordStyleSheet(legacyRange: range, table: table)
        }, else: .empty)
        // The Data stream, where a paragraph's properties are when they do not fit its page.
        let data = fib.layout == .modern ? (try? file.stream(named: "Data")).map { OLEBytes($0) } : nil
        var paragraphs = try lenient({ () -> WordFormatRuns<WordParagraphFormat> in
            guard let range = try fib.range(of: .paragraphBinTable, in: table) else { return WordFormatRuns(runs: []) }
            return try WordDocumentProperties.paragraphRuns(
                binTable: range, table: table, document: document, pieces: pieces, limit: pieces.characterCount, data: data,
                dialect: dialect, declaredPageCount: followingPages(of: .paragraphBinTable)
            )
        }, else: WordFormatRuns(runs: []))
        let characters = try lenient({ () -> WordFormatRuns<WordCharacterFormat> in
            guard let range = try fib.range(of: .characterBinTable, in: table) else { return WordFormatRuns(runs: []) }
            return try WordDocumentProperties.characterRuns(
                binTable: range, table: table, document: document, pieces: pieces, limit: pieces.characterCount,
                dialect: dialect, declaredPageCount: followingPages(of: .characterBinTable)
            )
        }, else: WordFormatRuns(runs: []))
        // The code page of each stretch of a Word 6 or Word 95 document of one-byte characters.
        var codePages: WordLegacyCodePages?
        if let legacyCharacters, legacyCharacters.width == 1 {
            codePages = WordLegacyCodePages.build(
                characters: legacyCharacters, styles: styles, paragraphs: paragraphs, characterRuns: characters,
                pieces: pieces, document: document
            )
        }
        // The fonts, for the symbols: a symbol of the font named Symbol is a character with words to read, and
        // one of any other font (a picture) is not. A table that does not fit gives none, and every symbol is white space.
        var fonts = WordFontTable.none
        if let range = try? fib.range(of: .fontTable, in: table) {
            if fib.layout == .modern {
                fonts = (try? WordFontTable.modern(range: range, in: table)) ?? .none
            } else {
                fonts = (try? WordFontTable.legacy(range: range, in: table)) ?? .none
            }
        }
        let symbolFonts = fonts.symbolFonts
        // The lists, whose numbers Word does not store in the text. They are
        // a help to the listener and not the text: a list table that does
        // not fit loses the numbers, not the document.
        var lists = WordListTables.none
        let listFormats = try? fib.range(of: .listFormats, in: table)
        let listOverrides = try? fib.range(of: .listOverrides, in: table)
        if listFormats != nil || listOverrides != nil {
            lists = (try? WordListTables(listFormats: listFormats, listOverrides: listOverrides, table: table)) ?? .none
        }
        // A Word 6 or Word 95 paragraph carries its own numbering: give each a list instance.
        if let legacyCharacters {
            let numbered = WordLegacyNumbering.apply(to: paragraphs, characters: legacyCharacters)
            paragraphs = numbered.paragraphs
            lists = numbered.lists
        }
        let sections = try lenient({ () -> WordSections in
            guard let range = try fib.range(of: .sectionTable, in: table) else { return .none }
            return try WordSections(range: range, table: table, document: document, dialect: dialect)
        }, else: .none)

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

        // Writes the text of the stories `segments` (in order, none going back,
        // each a story of its own for the list numbers and the fields that
        // are open) and says whether it holds a letter or a digit.
        func write(_ segments: [(range: Range<Int>, isMain: Bool)]) throws -> (body: String, hasWords: Bool) {
            var writer = WordHTMLWriter(
                styles: styles, sections: sections, includesPages: includesPages,
                outputLimit: Int(DocumentByteLimit.current) * 2, paragraphs: paragraphs, characters: characters,
                lists: lists, numbersAreWords: speaksListNumbers, symbolFonts: symbolFonts
            )
            var charactersWritten = 0
            for segment in segments {
                try writer.beginStory(isMain: segment.isMain)
                try pieces.forEachCharacter(
                    from: segment.range.lowerBound, upTo: segment.range.upperBound, in: document, codePages: codePages
                ) { position, unit in
                    try writer.add(position: position, unit: unit)
                    // A cancelled import stops here, however long the document is.
                    charactersWritten += 1
                    if charactersWritten % Self.charactersBetweenCancellationChecks == 0 { try ImportCancellation.throwIfCancelled() }
                }
            }
            let body = try writer.finish(endingAt: segments.last?.range.upperBound ?? 0)
            return (body, writer.wroteCountedCharacter)
        }

        // The main story is the book. The footnotes, the endnotes, and the
        // text boxes of the main story follow it, in that order, as they
        // follow it in textutil's reading, so their words are not lost: a
        // person reading the document sees them, each note and box as a
        // story of its own. A note is read only if a person would see its
        // reference mark (not when it is in hidden or deleted text). The
        // headers, the comments, and the text boxes of the headers are left
        // out, since a header would repeat page furniture at the end of the
        // book. Only when all of that holds no words (a document whose text
        // is in a header, say) is every story read, in the order the file
        // keeps them, as textutil reads them.
        let main = 0..<textEnd
        let stories = try fib.stories(limit: pieces.characterCount)
        var segments: [(range: Range<Int>, isMain: Bool)] = [(main, true)]
        for note in shownNotes(of: stories.footnotes, references: .footnoteReferences, texts: .footnoteText) { segments.append((note, false)) }
        for note in shownNotes(of: stories.endnotes, references: .endnoteReferences, texts: .endnoteText) { segments.append((note, false)) }
        for box in WordNotes.boxRanges(of: stories.textBoxes, texts: try? fib.range(of: .textBoxText, in: table), in: table) {
            segments.append((box, false))
        }
        var written = try write(segments)
        if !written.hasWords, pieces.characterCount > textEnd {
            // Every story, and the characters after the last of them (or after the main
            // text, when the file names no story): a length that is too small leaves text
            // no story names, and a document must not lose it.
            let afterStories = stories.inFileOrder.last?.upperBound ?? textEnd
            let everyStory = stories.inFileOrder + (afterStories < pieces.characterCount ? [afterStories..<pieces.characterCount] : [])
            written = try write([(main, true)] + everyStory.map { ($0, false) })
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
