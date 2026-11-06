import Foundation

/// TextMouth's own readers of the formats textutil reads, and which of them
/// this platform uses (the user, November 4, 2026: "small Text Mouth
/// readers for .doc /odt etc might be good for both so formatting
/// extraction is under our control"). iOS starts no textutil, so there each
/// format is read by its own reader or not at all; the Mac reads a format
/// with its own reader once that reader has been checked against
/// textutil's reading of the same files.
///
/// A reader turns a file into one HTML document, which
/// `TextutilDocumentReader` reads as it reads textutil's, except that it
/// restores nothing (`TextutilHTMLStructure`) and lines up no page breaks
/// (`TextutilPageBreaks`): the reader's own markup already holds them. The
/// document:
/// - names in its head the title (`<title>`) and the author
///   (`<meta name="author" content="…">`) the file gives, when it gives
///   them, which `TextutilDocumentReader.metadata(in:)` reads as it reads
///   textutil's;
/// - holds in its body the headings as `h1` to `h6`, the paragraphs as `p`,
///   emphasis as `em` and `strong`, lists as `ul`, `ol`, and `li`, and
///   tables as `table`, `tr`, and `td`, all text escaped;
/// - marks, when `includesPages` is true, each page as
///   `TextutilPageBreaks.insertPageBreaks(fromPlainText:into:)` marks
///   textutil's, so a format's pages stay the same when its reader changes:
///   an empty `<span role="doc-pagebreak" aria-label="N"></span>`, page 1 at
///   the start of the body of any document that holds a letter or digit,
///   whether or not it has a page break, and each later page, numbered on
///   from 2, right before its first letter or digit; a break with no letter
///   or digit after it begins no page, and a document with more than
///   `TextutilPageBreaks.maximumPages` breaks is read without pages.
///
/// Each reader adds its format to `html(of:as:includesPages:)`, behind a
/// switch of its own that is on for iOS and, once checked, for the Mac.
enum OwnDocumentReaders {
    /// Whether the router sends every format to textutil, whatever the own
    /// readers' switches say. It exists only for the tests that pin
    /// textutil's own behaviour with the format samples (its second run for
    /// pages, its one run per import, its refusal wording, the cancelling of
    /// its child): they bind it with
    /// `OwnDocumentReaders.$forcesTextutil.withValue(true)`, so that they go
    /// on testing textutil now that an own reader reads the samples. Like
    /// `DocumentByteLimit.$current` it is read on the caller's thread, where
    /// the route is decided, before any hop. Nothing else sets it, and false
    /// changes nothing.
    @TaskLocal static var forcesTextutil = false

    /// The HTML document TextMouth's own reader makes of the file at `url`,
    /// read as `format` (the format its bytes showed, which can differ from
    /// its name's: `TextutilDocumentReader`'s first step), or nil when this
    /// platform reads `format` with textutil.
    /// - Throws: what the format's reader throws for a file it cannot read.
    static func html(of url: URL, as format: TextutilInputFormat, includesPages: Bool) throws -> String? {
        // The tests that pin textutil's behaviour read everything with it.
        guard !forcesTextutil else { return nil }
        switch format {
        // A format read with TextMouth's own reader returns its HTML here.
        case .rtf, .rtfd:
            guard RTFDocumentReader.isOn else { return nil }
            return try RTFDocumentReader.html(of: url, as: format, includesPages: includesPages)
        case .doc:
            // Word 97-2003 (.doc and .dot); nil too for a Word 6 or Word 95
            // document, which textutil reads.
            guard WordDocumentReader.isOn else { return nil }
            return try WordDocumentReader.html(
                of: url, includesPages: includesPages, readsOldLayout: WordDocumentReader.readsWord6AndWord95
            )
        case .odt:
            // OpenDocument text (.odt and the .ott template).
            guard ODTDocumentReader.isOn else { return nil }
            return try ODTDocumentReader.html(of: url, includesPages: includesPages)
        case .wordml:
            // Word 2003 XML.
            guard WordMLDocumentReader.isOn else { return nil }
            return try WordMLDocumentReader.html(of: url, includesPages: includesPages)
        }
    }
}
