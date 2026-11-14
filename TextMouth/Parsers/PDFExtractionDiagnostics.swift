import Foundation

// MARK: - One Page

/// How one page of a PDF was read: where its text came from (the text
/// embedded in the PDF, optical character recognition (OCR) of the page's
/// images, both, or neither) and what OCR did there (TODO T09).
struct PDFPageDiagnosis: Equatable, Sendable {
    /// Where the text a page contributed came from.
    enum TextSource: Equatable, Sendable {
        /// Only text embedded in the PDF.
        case embedded
        /// Only text OCR recognized, as on a scanned page.
        case recognized
        /// Embedded text, with text OCR recognized in the page's images
        /// added where it was not already embedded.
        case both
        /// No text from either.
        case none
    }

    /// What OCR did on a page.
    enum Recognition: Equatable, Sendable {
        /// Nothing on the page needed OCR: it has embedded text and no
        /// picture that could hold more.
        case notNeeded
        /// OCR ran and recognized text, though all of it may have been
        /// embedded already.
        case recognizedText
        /// OCR ran and recognized nothing, as for a photograph without
        /// words or a blank scan.
        case foundNothing
        /// The page needed OCR, but it could not run, for this reason.
        case couldNotRun(String)
    }

    /// The page's number, counting from 1: the number a reader hears.
    var pageNumber: Int
    /// Where the page's text came from.
    var source: TextSource
    /// What OCR did on the page.
    var recognition: Recognition
}

// MARK: - The Document

/// How every page of a PDF was read, with sentences that say so aloud.
/// An `ExtractionReport` carries it for a PDF so the Library can show
/// where a book's text came from, and so an import can warn when text that
/// appears only in images could not be read.
struct PDFExtractionDiagnostics: Equatable, Sendable {
    /// Every page, in order.
    var pages: [PDFPageDiagnosis]
    /// Why OCR could not run at all during this extraction, when a page
    /// needed it and the app could not perform it. Nil when OCR was
    /// available, or when no page needed it.
    var ocrUnavailableReason: String?

    /// Diagnostics for `pages`, with OCR unavailable for
    /// `ocrUnavailableReason` when one is given.
    init(pages: [PDFPageDiagnosis] = [], ocrUnavailableReason: String? = nil) {
        self.pages = pages
        self.ocrUnavailableReason = ocrUnavailableReason
    }

    // MARK: Page Lists

    /// Pages whose text all came from the PDF's embedded text.
    var pagesWithEmbeddedTextOnly: [Int] { pageNumbers { $0.source == .embedded } }
    /// Pages whose text all came from OCR.
    var pagesWithOCRTextOnly: [Int] { pageNumbers { $0.source == .recognized } }
    /// Pages with embedded text and text OCR added from their images.
    var pagesWithEmbeddedAndOCRText: [Int] { pageNumbers { $0.source == .both } }
    /// Pages with no text at all.
    var pagesWithoutText: [Int] { pageNumbers { $0.source == .none } }
    /// Pages where OCR ran but recognized nothing.
    var pagesWhereOCRFoundNothing: [Int] { pageNumbers { $0.recognition == .foundNothing } }
    /// Pages that needed OCR where it could not run, so text that appears
    /// only in their images is missing.
    var pagesWhereOCRCouldNotRun: [Int] { pageNumbers { $0.couldNotRunReason != nil } }

    /// Whether every page was read in full: OCR ran wherever a page needed
    /// it. A page OCR found nothing on was still read.
    var isComplete: Bool { pagesWhereOCRCouldNotRun.isEmpty }

    /// The first reason OCR could not run on a page, or nil when it ran
    /// wherever it was needed.
    var firstOCRFailureReason: String? { pages.lazy.compactMap(\.couldNotRunReason).first }

    // MARK: Sentences

    /// One sentence for a reader to hear when text may be missing: how many
    /// pages OCR could not run on, then those pages and why, for example:
    /// "OCR could not run on 2 of 12 pages, so text that appears only in
    /// their images is missing: pages 3 and 7 (text recognition is not
    /// available)." Nil when the PDF was read in full.
    var problem: String? {
        let failed = pagesWhereOCRCouldNotRun
        guard !failed.isEmpty else { return nil }
        let pronoun = failed.count == 1 ? "its" : "their"
        return "\(failureCount(failed.count)), so text that appears only in \(pronoun) images is missing: "
            + "\(failureGroups)."
    }

    /// Every diagnostic in sentences, for the Library to show: how many
    /// pages had each source of text, where OCR found nothing, and where it
    /// could not run and why. For example: "Of 12 pages, 9 have embedded
    /// text only, 2 have OCR text only, and 1 has both embedded and OCR
    /// text. OCR found no text on page 4."
    var summary: String {
        var sentences = [sourceSentence]
        let empty = pagesWhereOCRFoundNothing
        if !empty.isEmpty {
            sentences.append("OCR found no text on \(Self.pagePhrase(empty)).")
        }
        if !pagesWhereOCRCouldNotRun.isEmpty {
            sentences.append("OCR could not run on \(failureGroups).")
        }
        return sentences.joined(separator: " ")
    }

    /// "page 3", "pages 3 and 7", or "pages 1 to 4, 7, and 9": the pages,
    /// in order and without repeats, with each run of three or more
    /// consecutive pages said as a range, or "no pages" when there are
    /// none. Ranges use "to" rather than a dash, which speech may read as
    /// "minus".
    static func pagePhrase(_ pageNumbers: [Int]) -> String {
        let numbers = Array(Set(pageNumbers)).sortedStably()
        guard !numbers.isEmpty else { return "no pages" }
        var items: [String] = []
        var start = 0
        while start < numbers.count {
            // Extend the run while each page follows the one before it.
            var end = start
            while end + 1 < numbers.count, numbers[end + 1] == numbers[end] + 1 {
                end += 1
            }
            if end - start >= 2 {
                items.append("\(numbers[start]) to \(numbers[end])")
                start = end + 1
            } else {
                items.append("\(numbers[start])")
                start += 1
            }
        }
        return "\(numbers.count == 1 ? "page" : "pages") \(CountWording.list(items))"
    }

    // MARK: Sentence Parts

    /// How many pages had each source of text: "Of 12 pages, 9 have
    /// embedded text only and 3 have OCR text only." When one source
    /// accounts for every page it says so ("All 12 pages have embedded text
    /// only."), and a one-page PDF says "Its only page has ….".
    private var sourceSentence: String {
        let total = pages.count
        guard total > 0 else { return "The PDF has no pages." }
        let counts: [(count: Int, description: String)] = [
            (pagesWithEmbeddedTextOnly.count, "embedded text only"),
            (pagesWithOCRTextOnly.count, "OCR text only"),
            (pagesWithEmbeddedAndOCRText.count, "both embedded and OCR text"),
            (pagesWithoutText.count, "no text")
        ].filter { $0.count > 0 }

        if counts.count == 1, let only = counts.first {
            return total == 1
                ? "Its only page has \(only.description)."
                : "All \(total) pages have \(only.description)."
        }
        let parts = counts.map { "\($0.count) \($0.count == 1 ? "has" : "have") \($0.description)" }
        return "Of \(total) pages, \(CountWording.list(parts))."
    }

    /// "OCR could not run on 2 of 12 pages", or, when it could not run on
    /// any of them, "… on all 12 pages" or "… on the PDF's only page".
    private func failureCount(_ failed: Int) -> String {
        let total = pages.count
        if failed == total {
            return total == 1 ? "OCR could not run on the PDF's only page" : "OCR could not run on all \(total) pages"
        }
        return "OCR could not run on \(failed) of \(total) pages"
    }

    /// The pages OCR could not run on, grouped by reason in the order each
    /// reason first appears: "pages 3 and 7 (reason); page 9 (other reason)".
    private var failureGroups: String {
        var reasons: [String] = []
        var pagesByReason: [String: [Int]] = [:]
        for page in pages {
            guard let reason = page.couldNotRunReason else { continue }
            if pagesByReason[reason] == nil { reasons.append(reason) }
            pagesByReason[reason, default: []].append(page.pageNumber)
        }
        return reasons
            .map { "\(Self.pagePhrase(pagesByReason[$0] ?? [])) (\($0))" }
            .joined(separator: "; ")
    }

    /// The page numbers of the pages that satisfy `condition`, in order.
    private func pageNumbers(where condition: (PDFPageDiagnosis) -> Bool) -> [Int] {
        pages.filter(condition).map(\.pageNumber)
    }
}

private extension PDFPageDiagnosis {
    /// Why OCR could not run on this page, or nil when it ran or was not
    /// needed.
    var couldNotRunReason: String? {
        if case .couldNotRun(let reason) = recognition { return reason }
        return nil
    }
}
