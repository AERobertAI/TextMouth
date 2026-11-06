import Foundation

// MARK: - TextMouth's Own Reader of Word 2003 XML

/// TextMouth's own reader of Word 2003 XML documents (FMT53): one XML file,
/// `w:wordDocument`, that Word 2003 saves as "Word XML Document" and that
/// textutil writes as WordML. It turns a document into the HTML
/// `OwnDocumentReaders` describes, and runs in both apps, with no `textutil`
/// and no AppKit. `WordMLReader` lists what it reads and what it leaves out.
///
/// Compared with textutil's reading, which this reader replaces where `isOn`
/// says so: the headings are the document's own (the styles "heading 1" to
/// "heading 9", and outline levels), where textutil guesses them from sizes;
/// lists, tables, and emphasis are kept; page breaks are pages; hidden text,
/// tracked deletions, comments, headers, and footers are not read; notes
/// follow the text.
///
/// The format is Microsoft's Word 2003 XML (WordprocessingML 2003), published
/// with the Office 2003 XML Reference Schemas. The reader is written from it
/// and from the shape of the files textutil writes, with no other reader's
/// code; the words and paragraphs are gathered by the same code as the
/// OpenDocument reader's (`OfficeBlockWriter`).
///
/// A file that cannot be read ends the read with
/// `TextutilConverter.Failure.unreadable(.wordml)`; one past the byte limit
/// with `DocumentTooLargeError`.
enum WordMLDocumentReader {
    /// Whether this platform reads Word 2003 XML with this reader: iOS, which
    /// has no textutil, always; the Mac once the reader has been checked
    /// against textutil's reading of the same files
    /// (`WordMLReaderTests.testSamplesMatchTextutil`).
    static var isOn: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// The HTML document of the Word 2003 XML file at `url`, held to the byte
    /// limit.
    /// - Parameter includesPages: whether page-break elements are written.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError`, the file system's error, and
    ///   `TextutilConverter.Failure.unreadable` for a file that is not a
    ///   readable Word 2003 XML document.
    static func html(of url: URL, includesPages: Bool) throws -> String {
        try html(from: DocumentByteLimit.contents(of: url), includesPages: includesPages)
    }

    /// The HTML document of the Word 2003 XML in `data`, which the caller has
    /// held to the byte limit.
    static func html(from data: Data, includesPages: Bool) throws -> String {
        // The sections' types are stated at their ends, so the pages they
        // begin are found by a first pass, when pages are asked for.
        let sections = includesPages ? try WordMLSectionScanner.scan(data) : []
        let reader = WordMLReader(
            data: data, file: "the document", includesPages: includesPages, limit: DocumentByteLimit.current,
            sectionsStartPages: sections
        )
        try reader.read()
        let body = try reader.finish()
        var document = RTFDocument()
        document.blocks = body.blocks
        document.pageBreaks = body.pageBreaks
        document.title = reader.title
        document.author = reader.author
        return RTFHTMLWriter.html(of: document, includesPages: includesPages)
    }
}
