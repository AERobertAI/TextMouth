import Foundation

// MARK: - TextMouth's Own Reader of Rich Text

/// TextMouth's own reader of Rich Text Format documents (FMT47): `.rtf`
/// files and the `TXT.rtf` inside an `.rtfd` package. It turns a document
/// into the HTML `OwnDocumentReaders` describes, and runs in both apps, with
/// no `textutil` and no AppKit.
///
/// Compared with textutil's reading, which this reader replaces where
/// `isOn` says so:
/// - the headings are the document's own: the style sheet's "heading 1" to
///   "heading 9" and `\outlinelevelN`. A document that names none keeps the
///   headings textutil's reading finds by size (`RTFSizeHeadings`);
/// - bold and italic in body text are `strong` and `em`;
/// - lists are lists, and the number or bullet a list item shows is not read
///   as one of its words; tables are tables;
/// - page breaks (`\page`, `\pagebb`, and a `\sect` that begins a page)
///   are pages, where textutil's HTML loses them;
/// - headers, footers, footnotes, hidden text, pictures, and objects are not
///   read, and a field is read for its result alone.
///
/// The specification is Microsoft's Rich Text Format 1.9.1 (2008), free to
/// implement under the Open Specification Promise. The reader is written
/// from it; the open-source readers named in the brief (rtf-parser,
/// rtf.js, striprtf) were maps of the problem only, and none of their code
/// is used.
enum RTFDocumentReader {

    /// Whether this platform reads rich text with this reader: iOS, which has
    /// no textutil, always, and the Mac since the reader was checked against
    /// textutil's reading of every sample (`RTFTextutilComparisonTests`: the
    /// same words, and at least textutil's headings).
    static var isOn: Bool { true }

    // MARK: Entry points

    /// The HTML document of the rich text at `url`: the file itself, or, for
    /// an `.rtfd` package (`format` is `.rtfd` and `url` is a folder), the
    /// `TXT.rtf` inside it, whose attachments are left alone.
    /// - Parameters:
    ///   - format: the format the file's bytes showed (`.rtf` or `.rtfd`).
    ///   - includesPages: whether page-break elements are written.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for a file, or text, past
    ///   `DocumentByteLimit`, the file system's error for a file that cannot
    ///   be read, and `TextutilConverter.Failure.unreadable` for a file that
    ///   is not rich text by its first bytes (as textutil would fail on it)
    ///   or a package with no `TXT.rtf`.
    static func html(of url: URL, as format: TextutilInputFormat, includesPages: Bool) throws -> String {
        let file = try documentFile(at: url, as: format)
        // The bytes are read first: an empty file is "no text to read", as
        // it is when textutil reads it, and one past the limit is too large.
        let bytes = try DocumentByteLimit.contents(of: file)
        guard TextutilSourceCheck.beginsAsRTF(file) else {
            throw TextutilConverter.Failure.unreadable(format)
        }
        return try html(from: bytes, includesPages: includesPages)
    }

    /// The HTML document of the rich text in `data`, which the caller has
    /// held to the byte limit.
    /// - Throws: `TextutilConverter.Failure.unreadable` for groups nested
    ///   too deeply, and `DocumentTooLargeError` for text past the limit.
    static func html(from data: Data, includesPages: Bool) throws -> String {
        var interpreter = RTFInterpreter(
            bytes: Array(data),
            includesPages: includesPages,
            limit: DocumentByteLimit.current
        )
        let document = try interpreter.read()
        return RTFHTMLWriter.html(of: document, includesPages: includesPages)
    }

    // MARK: The file

    /// The name of the file that holds an RTFD package's text.
    private static let packageTextName = "TXT.rtf"

    /// The file to read for `url`: for an `.rtfd` that is a folder, its
    /// `TXT.rtf`; otherwise `url` itself (a flat `.rtfd` file is rich text
    /// as well).
    /// - Throws: `TextutilConverter.Failure.unreadable` when the package
    ///   holds no `TXT.rtf`, or holds a link in its place: a link could
    ///   point anywhere on the disk.
    private static func documentFile(at url: URL, as format: TextutilInputFormat) throws -> URL {
        var isFolder: ObjCBool = false
        guard format == .rtfd,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue else {
            return url
        }
        // The name is matched without regard to case, as the file system
        // may be case-sensitive.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard let name = names.first(where: { $0.caseInsensitiveCompare(packageTextName) == .orderedSame }) else {
            throw TextutilConverter.Failure.unreadable(format)
        }
        let text = url.appendingPathComponent(name)
        let isLink = (try? text.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        guard !isLink else { throw TextutilConverter.Failure.unreadable(format) }
        return text
    }
}
