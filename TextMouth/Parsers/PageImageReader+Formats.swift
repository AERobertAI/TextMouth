import Foundation

// MARK: - The Reader as the Formats Call It

extension PageImageReader {
    /// The book of `format` (`.picture` or `.comic`) at `url`, read, as the
    /// Markdown cache reads it (FMT34): a picture file's pages, or a comic
    /// book archive's pictures.
    /// - Parameter includesPages: whether page markers are written (PG06).
    /// - Parameter recognizer: reads each page; nil when text recognition is
    ///   not available.
    /// - Throws: `PageImageError` when the file is no book of pictures
    ///   TextMouth reads, or no text can be found in it; `ImportCancelled`
    ///   when the import reading it is cancelled.
    static func extract(
        from url: URL,
        format: BookFormat,
        includesPages: Bool = true,
        recognizer: (any PageImageTextRecognizer)? = defaultRecognizer
    ) throws -> Extraction {
        let book: any PageImageBook = format == .comic ? try PageImageArchive(url: url) : try PageImageFilePages(url: url)
        return try extract(book, includesPages: includesPages, recognizer: recognizer)
    }

    /// The book of `format` at `url` as the reader shows it, read straight
    /// from its file without pages, as a PDF's direct parse is: the content a
    /// book that has no content.md is read as (`BookParser`). Its chapters are
    /// made by the cache's own reading of the same Markdown, so the two never
    /// differ. A comic book archive is titled by its ComicInfo.xml when it
    /// names a title, and every other book by its file's name.
    static func parse(url: URL, format: BookFormat) throws -> DocumentContent {
        let markdown = try extract(from: url, format: format, includesPages: false).markdown
        let names = format == .comic ? PageImageArchive.metadata(ofArchiveAt: url) : nil
        return MarkdownCacheService.parseMultiChapterMarkdown(
            markdown,
            bookTitle: names?.title ?? url.deletingPathExtension().lastPathComponent,
            bookAuthor: names?.author ?? Book.unknownAuthor
        )
    }
}
