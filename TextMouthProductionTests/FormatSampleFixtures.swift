import XCTest
@testable import TextMouth

/// The format samples in `TestData/format-samples` (FMT01, FMT03, FMT04,
/// FMT07, and FMT13), which came partly from outside: `samples.tsv` gives
/// each one's source. They are untrusted input that every importer must
/// survive, so a test never imports a sample where it lies and never
/// changes the samples' folder: it imports a copy in a folder of its own.
extension XCTestCase {
    /// The sample at `relativePath` inside `TestData/format-samples`, such
    /// as "rtf/headings.rtf" or the folder "rtfd/headings.rtfd".
    /// - Throws: `TestError.fileNotFound` when the sample is missing.
    func formatSampleURL(_ relativePath: String) throws -> URL {
        try requireFile("format-samples/\(relativePath)")
    }

    /// A copy of the sample at `relativePath`, a file or a folder (an RTFD
    /// or a NIMAS package), named `name`, or the sample's own name when
    /// that is nil, in a new folder of this test's own that is removed when
    /// the test ends. A name lets a test give a sample another extension,
    /// as a WordML sample needs to import as an .xml file.
    func copyOfFormatSample(_ relativePath: String, named name: String? = nil) throws -> URL {
        let sample = try formatSampleURL(relativePath)
        let folder = try makeSandboxDirectory("FormatSample")
        let copy = folder.appendingPathComponent(name ?? sample.lastPathComponent)
        try FileManager.default.copyItem(at: sample, to: copy)
        return copy
    }

    /// The book `url` imports as, through the import path Open Book takes
    /// (`FileImportService.importFileWithReport`), with its package removed
    /// from the hosted tests' library when the test ends.
    func importedForTest(_ url: URL) throws -> ImportedBook {
        let imported = try FileImportService.importFileWithReport(from: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        return imported
    }

    /// What the reader shows for `book`, read from its package as the
    /// reader reads it (`BookContentAnalysisService.load`).
    func openedContent(of book: Book) throws -> DocumentContent {
        try BookContentAnalysisService.load(book: book).content
    }

    /// The headings of `content`, chapter by chapter, as "level: label"
    /// lines, such as "1: Harbour Notes", for one comparison that names
    /// every heading.
    func headingLines(of content: DocumentContent) -> [String] {
        content.chapters.flatMap { chapter in
            chapter.headings.map { "\($0.level): \($0.text)" }
        }
    }

    /// Every chapter's text of `content`, joined by blank lines, for a
    /// test that looks for words wherever they fall.
    func allText(of content: DocumentContent) -> String {
        content.chapters.map(\.text).joined(separator: "\n\n")
    }
}
