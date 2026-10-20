import AppKit
import Foundation

// MARK: - The Word 97-2003 Writer (FMT19)

/// Writes a text book as a Word 97-2003 document (.doc), for the many
/// readers and devices that open only that format.
///
/// Word's binary format is a compound file of interlocking tables, and
/// TextMouth does not write it itself: a hand-made one that Word refuses to
/// open, or opens wrongly, would be worse than none. Apple's `.docFormat`
/// writer makes it instead, from the attributed string Apple's RTF reader
/// makes of `RTFExportWriter`'s text. Going through the RTF means the two
/// writers can never differ in how a book looks: the walker's
/// `ExportDocument` is the only source of both.
///
/// The cost is that Apple's writer makes a heading larger bold text with no
/// heading style, so Word's navigation pane does not list it. A reader that
/// needs the outline levels takes the RTF writer's file, which Word opens
/// and saves as .docx itself.
///
/// Apple's RTF reader and `.docFormat` writer need no main thread (only
/// its HTML reader does), so the export may call this one off it.
struct WordDocExportWriter: TextExportWriter {
    let id = "doc"
    let name = "Word 97-2003 (.doc)"
    let fileExtension = "doc"
    let hint = "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."

    /// Writes the Word document of `document` as a new file at `url`; a file
    /// already there is an error, and is left as it was.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let data = try Self.wordData(of: document, cancellation: cancellation)
        // `.withoutOverwriting` makes a file that is already there an error.
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// The bytes of the Word 97-2003 document of `document`. A stop passes
    /// through as `CancellationError`; any error of Apple's reader or writer
    /// becomes a `TextExportError`.
    private static func wordData(of document: ExportDocument, cancellation: BookExportCancellation) throws -> Data {
        do {
            // The one source: the RTF, read back as Apple reads any RTF.
            let rtf = try RTFExportWriter.rtf(of: document, cancellation: cancellation)
            let attributed = try NSAttributedString(
                data: Data(rtf.utf8),
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            try cancellation.checkCancelled()

            // The title and author go in the file's properties.
            var properties: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.docFormat,
                .title: document.book.title,
            ]
            if let author = document.book.author {
                properties[.author] = author
            }
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: properties
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TextExportError("The book's text could not be made into a Word 97-2003 document.")
        }
    }
}
