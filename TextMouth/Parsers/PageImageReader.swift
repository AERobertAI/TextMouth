import CoreGraphics
import Foundation
import os

// MARK: - The Recognizer

/// Recognizes the text in a picture of a page. The reader asks it about each
/// page, decoded and flattened; tests supply their own to check what the
/// reader makes of what it finds without depending on Vision.
protocol PageImageTextRecognizer: Sendable {
    /// The lines of text in `image`, in reading order.
    /// - Throws: `PDFTextRecognitionError.unavailable` when recognition
    ///   cannot run in this process at all, or `.failed` when it failed on
    ///   this picture.
    func lines(in image: CGImage) throws -> [RecognizedTextLine]
}

/// Reads a page with Vision's text recognition, exactly as a scanned PDF's
/// page is read (`VisionTextRecognition`).
struct VisionPageImageTextRecognizer: PageImageTextRecognizer {
    func lines(in image: CGImage) throws -> [RecognizedTextLine] {
        try VisionTextRecognition.lines(in: image)
    }
}

// MARK: - Where the Pages Come From

/// The pages of a book of pictures, decoded one at a time: a picture file's
/// own (`PageImageFilePages`), or a comic book archive's pictures
/// (`PageImageArchive`).
protocol PageImageBook {
    /// What the book is, as its sentences name it.
    var subject: PageImageWording.Subject { get }
    /// How many pages it has, at least one.
    var pageCount: Int { get }
    /// The title of page `index`'s chapter (from 0) in a book of several
    /// pages.
    func title(ofPage index: Int) -> String
    /// The picture of page `index` (from 0), decoded and upright.
    /// - Throws: `PageImageError` for a page that cannot be read.
    func decodedPage(at index: Int) throws -> DecodedPage
}

/// The pages of a picture file: every page of a TIFF, or the one picture of
/// a PNG, JPEG, or HEIC file, each titled by its number.
struct PageImageFilePages: PageImageBook {
    /// The picture, its pages listed and nothing decoded yet.
    let source: PageImageSource

    /// The pages of the picture file at `url`.
    /// - Throws: `PageImageError` when it is no picture TextMouth reads.
    init(url: URL) throws {
        source = try PageImageSource(url: url)
    }

    var subject: PageImageWording.Subject { .picture }
    var pageCount: Int { source.pageIndexes.count }

    func title(ofPage index: Int) -> String {
        PageImageWording.pageTitle(index + 1)
    }

    func decodedPage(at index: Int) throws -> DecodedPage {
        try source.decodedPage(at: source.pageIndexes[index])
    }
}

// MARK: - The Reader

/// Reads pictures of pages (FMT34): a PNG, JPEG, HEIC, or TIFF picture, a
/// chapter for each page of a TIFF of several, and a comic book archive, its
/// pictures in order. Each page is decoded within `PageImageDecoding`'s
/// limits and read by text recognition, the same as a scanned PDF's
/// (`VisionTextRecognition`). Every page is a page of the book, its marker
/// written as a PDF's is.
///
/// A page takes up to seconds, so the import running on this thread is
/// told how many pages are read (`ImportPageProgress`), and its Cancel
/// stops the reading before the next page (`ImportCancellation`). A page that
/// cannot be read leaves the others to be read, and the report names it, as
/// a PDF's report names the pages OCR could not run on.
enum PageImageReader {
    /// A book of pictures' Markdown and the report of how each page was read.
    struct Extraction {
        /// The book's content.md.
        var markdown: String
        /// How each page was read, and those that could not be
        /// (`PDFExtractionDiagnostics`, which a PDF's pages share).
        var report: ExtractionReport
    }

    /// The recognizer `extract(from:format:)` reads pages with when its caller
    /// names none, as imports and cache rebuilds do: Vision's in the app; nil
    /// when text recognition is not available. Tests replace it, and put it
    /// back, to see how a book is read without depending on Vision.
    static var defaultRecognizer: (any PageImageTextRecognizer)? {
        get { defaultRecognizerStore.withLock { $0 } }
        set { defaultRecognizerStore.withLock { $0 = newValue } }
    }

    /// Holds `defaultRecognizer` under a lock, since readings on any thread
    /// read it.
    private static let defaultRecognizerStore = OSAllocatedUnfairLock<(any PageImageTextRecognizer)?>(
        initialState: VisionPageImageTextRecognizer()
    )

    /// What text recognition says when there is no recognizer to ask, as a
    /// PDF's reading says it.
    static let recognitionNotAvailable = "text recognition is not available" // l10n: no (a parser's damage reason: finishes a page's reason, inside the pages' translated warning)

    // MARK: - Reading the Pages

    /// What reading one page came to.
    private enum PageOutcome {
        /// Text recognition ran: the page's paragraphs, none when no text
        /// was found.
        case read([[String]])
        /// The page could not be read, for a reason of its own.
        case unreadable(PageImageError)
        /// Text recognition failed on this page, for `reason`.
        case recognitionFailed(String)
        /// Text recognition cannot run at all, for `reason`.
        case recognitionUnavailable(String)
    }

    /// `book`, read page by page.
    static func extract(
        _ book: any PageImageBook,
        includesPages: Bool,
        recognizer: (any PageImageTextRecognizer)?
    ) throws -> Extraction {
        let total = book.pageCount
        var pages: [PageImagePageText] = []
        var diagnoses: [PDFPageDiagnosis] = []
        var firstUnreadable: PageImageError?
        var firstRecognitionFailure: String?
        // Once text recognition proves unavailable, no later page asks it.
        var unavailableReason: String?

        try ImportPageProgress.pagesRead(0, of: total)
        for index in 0..<total {
            try ImportCancellation.throwIfCancelled()
            let number = index + 1
            let outcome: PageOutcome
            if let unavailableReason {
                outcome = .recognitionUnavailable(unavailableReason)
            } else {
                // Each page's pictures are large and temporary; draining them
                // page by page keeps a long book's memory flat.
                outcome = autoreleasepool { read(pageAt: index, of: book, with: recognizer) }
            }

            var paragraphs: [[String]] = []
            let recognition: PDFPageDiagnosis.Recognition
            switch outcome {
            case .read(let found):
                paragraphs = found
                recognition = found.isEmpty ? .foundNothing : .recognizedText
            case .unreadable(let error):
                firstUnreadable = firstUnreadable ?? error
                recognition = .couldNotRun(error.pageReason)
            case .recognitionFailed(let reason):
                firstRecognitionFailure = firstRecognitionFailure ?? reason
                recognition = .couldNotRun(reason)
            case .recognitionUnavailable(let reason):
                unavailableReason = reason
                recognition = .couldNotRun(reason)
            }
            pages.append(PageImagePageText(title: book.title(ofPage: index), paragraphs: paragraphs))
            diagnoses.append(PDFPageDiagnosis(
                pageNumber: number, source: paragraphs.isEmpty ? .none : .recognized, recognition: recognition
            ))
            try ImportPageProgress.pagesRead(number, of: total)
        }

        let diagnostics = PDFExtractionDiagnostics(pages: diagnoses, ocrUnavailableReason: unavailableReason, medium: .pictures)
        guard pages.contains(where: \.hasText) else {
            throw refusal(of: book, diagnostics: diagnostics, firstUnreadable: firstUnreadable,
                          firstRecognitionFailure: firstRecognitionFailure)
        }
        return Extraction(
            markdown: PageImageText.markdown(of: pages, includesPages: includesPages),
            report: ExtractionReport(container: book.subject.container, pdf: diagnostics)
        )
    }

    /// Reads the page at `index` of `book`: decoded, flattened onto white,
    /// and read; read again flattened onto black when nothing was found and
    /// the picture has transparency, where white would hide light print.
    private static func read(
        pageAt index: Int,
        of book: any PageImageBook,
        with recognizer: (any PageImageTextRecognizer)?
    ) -> PageOutcome {
        do {
            let decoded = try book.decodedPage(at: index)
            guard let recognizer else { return .recognitionUnavailable(recognitionNotAvailable) }
            var lines = try recognizer.lines(in: try decoded.flattened(onto: .white))
            if lines.isEmpty, decoded.hasAlpha {
                lines = try recognizer.lines(in: try decoded.flattened(onto: .black))
            }
            return .read(PageImageText.paragraphs(of: lines))
        } catch let error as PageImageError {
            return .unreadable(error)
        } catch PDFTextRecognitionError.unavailable(let reason) {
            return .recognitionUnavailable(reason)
        } catch PDFTextRecognitionError.failed(let reason) {
            return .recognitionFailed(reason)
        } catch {
            return .recognitionFailed("text recognition failed: \(error.localizedDescription)") // l10n: no (a parser's damage reason: finishes a page's reason, inside the pages' translated warning)
        }
    }

    /// Why a book on none of whose pages text was found imports nothing, in
    /// the most telling words: text recognition could not run; the one
    /// page's own refusal, for a book of one; the pages that could not be
    /// read, when some could not; or that no text was found.
    private static func refusal(
        of book: any PageImageBook,
        diagnostics: PDFExtractionDiagnostics,
        firstUnreadable: PageImageError?,
        firstRecognitionFailure: String?
    ) -> PageImageError {
        if let reason = diagnostics.ocrUnavailableReason {
            return .recognitionUnavailable(book.subject, reason: reason)
        }
        if book.pageCount == 1 {
            if let firstUnreadable { return firstUnreadable }
            if let firstRecognitionFailure { return .recognitionUnavailable(book.subject, reason: firstRecognitionFailure) }
        }
        if let problem = diagnostics.problem {
            return .noPageReadable(problem)
        }
        return .noText(book.subject, pageCount: book.pageCount)
    }
}
