import Foundation

// MARK: - Web Archive Reader

/// Reads the main page of a Safari web archive (.webarchive), a property
/// list whose `WebMainResource` holds the page's bytes (`WebResourceData`),
/// their MIME type (`WebResourceMIMEType`), and their text encoding
/// (`WebResourceTextEncodingName`). The page's text goes to the HTML path
/// (or the text path), so its headings, lists, and tables arrive as they do
/// in an HTML book (FMT03).
///
/// Only the main page is read. `WebSubresources` (images, scripts, style
/// sheets), `WebSubframeArchives` (frames), and every URL in the archive
/// are never read, decoded, or fetched: the archive is untrusted input, and
/// nothing it names is followed. WebKit is not used, for the same reason
/// (it would load the page's resources).
enum WebArchiveReader {

    // MARK: Results

    /// The main page of an archive: its text, and whether that text is HTML
    /// (a web page) rather than plain text.
    struct MainPage: Equatable {
        let text: String
        let isHTML: Bool
    }

    /// Why an archive's main page cannot be read. Each sentence never names
    /// the file: an import's failure names it before the sentence
    /// (`ImportFailure`).
    enum Failure: LocalizedError, Equatable {
        /// The file is not a property list holding a main resource with data.
        case notAWebArchive
        /// The main resource is a file of another type (an image, a PDF),
        /// which has no text to read. `mimeType` is as the archive wrote it.
        case notAPage(mimeType: String)

        var errorDescription: String? {
            switch self {
            case .notAWebArchive:
                return "This file is not a web archive TextMouth can read. It may be damaged, or another kind of file."
            case .notAPage(let mimeType):
                return "This web archive holds a file of the type “\(mimeType)”, not a web page or text, so it has nothing to read."
            }
        }
    }

    // MARK: Reading

    /// The main page of the web archive at `url`. The bytes come through
    /// `DocumentByteLimit.contents(of:)`, so an empty file has no text to
    /// read and one past the limit is refused before it is read.
    /// - Throws: `FileImportError.noTextToRead`, `DocumentTooLargeError`,
    ///   the file system's error, or what `mainPage(in:fileName:)` throws.
    static func mainPage(of url: URL) throws -> MainPage {
        try mainPage(in: DocumentByteLimit.contents(of: url), fileName: url.lastPathComponent)
    }

    /// The main page of the web archive whose bytes are `data`; `fileName`
    /// is named in a text encoding error.
    /// - Throws: `Failure`, `FileImportError.noTextToRead` for an empty main
    ///   resource, or `TextEncodingError`.
    static func mainPage(in data: Data, fileName: String) throws -> MainPage {
        // Binary and XML property lists read alike; anything else, or a
        // list of another shape, is not an archive.
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let main = root["WebMainResource"] as? [String: Any],
              let bytes = main["WebResourceData"] as? Data
        else { throw Failure.notAWebArchive }

        // The type decides how the bytes are read. A missing or empty type
        // is read as HTML: Safari always writes one, other tools may not.
        let writtenType = trimmed(main["WebResourceMIMEType"])
        let isHTML: Bool
        switch normalizedType(writtenType) {
        case "", "text/html", "application/xhtml+xml": isHTML = true
        case "text/plain": isHTML = false
        default: throw Failure.notAPage(mimeType: writtenType)
        }
        guard !bytes.isEmpty else { throw FileImportError.noTextToRead }

        // The archive's own encoding name wins when the bytes read in it
        // (ISO Latin 1 and ASCII as Windows-1252, as browsers read them, by
        // the file decoder's one rule); otherwise the file decoder's rules
        // (byte-order mark, UTF-8, the page's own declaration, Windows-1252)
        // read them.
        if let encoding = TextFileDecoder.encoding(forLabel: trimmed(main["WebResourceTextEncodingName"])),
           let text = TextFileDecoder.decodedText(bytes, in: encoding) {
            let finished = TextFileDecoder.normalizingLineEndings(TextFileDecoder.droppingLeadingByteOrderMarks(text))
            return MainPage(text: finished, isHTML: isHTML)
        }
        // The old evidence: this reader has no page reader version to raise, so what
        // it reads does not change with the book decoder's newer rules
        // (`TextFileDecoder.Evidence.legacy`).
        let decoded = try TextFileDecoder.decode(
            bytes, fileName: fileName, format: isHTML ? .html : .txt, evidence: .legacy
        )
        return MainPage(text: decoded.text, isHTML: isHTML)
    }

    // MARK: Helpers

    /// A property list value as trimmed text: empty when it is missing or
    /// not a string, as the archive's fields are all optional.
    private static func trimmed(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `type` as a MIME type is compared: lowercased, without the
    /// parameters after a semicolon ("text/plain; charset=utf-8"), trimmed.
    private static func normalizedType(_ type: String) -> String {
        let base = type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
