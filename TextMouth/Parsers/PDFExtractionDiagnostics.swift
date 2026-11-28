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
/// appears only in images could not be read. A book of pictures of pages
/// (FMT34) reports its pages the same way, in sentences of its own.
struct PDFExtractionDiagnostics: Equatable, Sendable {
    /// What the pages are, which the sentences name them by.
    enum Medium: Equatable, Sendable {
        /// A PDF's pages, whose text may be embedded as well as pictured.
        case pdf
        /// Pictures of pages, whose every word is in the picture (FMT34).
        case pictures
    }

    /// Every page, in order.
    var pages: [PDFPageDiagnosis]
    /// Why OCR could not run at all during this extraction, when a page
    /// needed it and the app could not perform it. Nil when OCR was
    /// available, or when no page needed it.
    var ocrUnavailableReason: String?
    /// What the pages are: a PDF's unless said otherwise.
    var medium: Medium

    /// Diagnostics for `pages` of `medium`, with OCR unavailable for
    /// `ocrUnavailableReason` when one is given.
    init(pages: [PDFPageDiagnosis] = [], ocrUnavailableReason: String? = nil, medium: Medium = .pdf) {
        self.pages = pages
        self.ocrUnavailableReason = ocrUnavailableReason
        self.medium = medium
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
    /// "OCR could not run on 2 of 12 pages, so text found only in
    /// their images is missing: pages 3 and 7 (text recognition is not
    /// available)." Nil when the PDF was read in full. A book of pictures,
    /// whose every word is pictured, says it without the clause about text
    /// in images: "Text recognition could not read 1 of 3 pages: page 2
    /// (its picture could not be decoded)." (`PageImageWording.pagesNotRead`).
    /// Each case is a whole sentence of its own (FR34): "its" or "their"
    /// agrees with how many pages it names, and a page's reason inside the
    /// parentheses is a parser's English.
    var problem: String? {
        let failed = pagesWhereOCRCouldNotRun
        guard !failed.isEmpty else { return nil }
        if medium == .pictures {
            return PageImageWording.pagesNotRead(failed.count, of: pages.count, pages: failureGroups)
        }
        let total = pages.count
        let groups = failureGroups
        if failed.count == total {
            // Every page, which for one page is "the PDF's only page".
            return total == 1
                // Translators: Warning after an import of a PDF whose only page needed text recognition (OCR) where it could not run. %@ is the page and why, such as "page 1 (text recognition is not available)", the reason in English.
                ? InterfaceText.line("pdfExtractionDiagnostics.problem.page", "OCR could not run on the PDF's only page, so text found only in its images is missing: \(groups).")
                // Translators: Warning after an import of a PDF whose every page needed text recognition (OCR) where it could not run. %lld is how many pages the PDF has, two or more. %@ is the pages and why, such as "pages 3 and 7 (text recognition is not available)", the reasons in English.
                : InterfaceText.line("pdfExtractionDiagnostics.problem.allPages", "OCR could not run on all \(number: total) pages, so text found only in their images is missing: \(groups).")
        }
        // Translators: Warning after an import of a PDF where some pages needed text recognition (OCR) where it could not run. %1$@ is how many of them, one or more, written with digit grouping; %2$lld is how many pages the PDF has, two or more; %3$@ is the pages and why, such as "pages 3 and 7 (text recognition is not available)", the reasons in English.
        return InterfaceText.line("pdfExtractionDiagnostics.problem.pages", "OCR could not run on \(failed.count.interfaceFormatted()) of \(number: total) pages, so text found only in their images is missing: \(groups).")
    }

    /// `problem` in English for the debug log, which stays English whatever
    /// language the interface speaks (FR34).
    var logProblem: String? {
        let failed = pagesWhereOCRCouldNotRun
        guard !failed.isEmpty else { return nil }
        let groups = logFailureGroups
        if medium == .pictures {
            return "Text recognition could not read \(failed.count) of \(pages.count) pages: \(groups)." // l10n: no (debug log)
        }
        let count = failed.count == pages.count
            ? (pages.count == 1 ? "the PDF's only page" : "all \(pages.count) pages") // l10n: no (debug log)
            : "\(failed.count) of \(pages.count) pages" // l10n: no (debug log)
        return "OCR could not run on \(count), so text found only in \(failed.count == 1 ? "its" : "their") images is missing: \(groups)." // l10n: no (debug log)
    }

    /// Every diagnostic in sentences: how many pages had each source of text,
    /// where OCR found nothing, and where it could not run and why. For
    /// example: "Of 12 pages, 9 have embedded text only, 2 have OCR text
    /// only, and 1 has both embedded and OCR text. OCR found no text on page
    /// 4." No screen shows it yet, so it stays English.
    var summary: String {
        var sentences = [sourceSentence]
        let empty = pagesWhereOCRFoundNothing
        if !empty.isEmpty {
            sentences.append("OCR found no text on \(Self.pagePhrase(empty)).") // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        }
        if !pagesWhereOCRCouldNotRun.isEmpty {
            sentences.append("OCR could not run on \(failureGroups).") // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        }
        return sentences.joined(separator: " ")
    }

    /// The pages, in order and without repeats, as runs: a page alone, or the
    /// first and last of three or more consecutive pages, which are said as
    /// a range ("1 to 4"). Ranges use "to" rather than a dash, which speech
    /// may read as "minus".
    private static func pageRuns(of pageNumbers: [Int]) -> [(first: Int, last: Int?)] {
        let numbers = Array(Set(pageNumbers)).sortedStably()
        var runs: [(first: Int, last: Int?)] = []
        var start = 0
        while start < numbers.count {
            // Extend the run while each page follows the one before it.
            var end = start
            while end + 1 < numbers.count, numbers[end + 1] == numbers[end] + 1 {
                end += 1
            }
            if end - start >= 2 {
                runs.append((numbers[start], numbers[end]))
                start = end + 1
            } else {
                runs.append((numbers[start], nil))
                start += 1
            }
        }
        return runs
    }

    /// "page 3", "pages 3 and 7", or "pages 1 to 4, 7, and 9": the pages,
    /// in order and without repeats, with each run of three or more
    /// consecutive pages said as a range, or "no pages" when there are
    /// none. Page numbers are identifiers, written without digit grouping.
    static func pagePhrase(_ pageNumbers: [Int]) -> String {
        let runs = pageRuns(of: pageNumbers)
        guard !runs.isEmpty else {
            // Translators: Names an empty set of a PDF's pages, in a sentence about which pages were read.
            return InterfaceText.line("pdfExtractionDiagnostics.pagePhrase.noPages", "no pages")
        }
        var items: [String] = []
        for run in runs {
            if let last = run.last {
                // Translators: A range of three or more consecutive pages of a PDF, in a list of pages. %1$@ is the first page and %2$@ the last, identifiers written without digit grouping.
                items.append(InterfaceText.line("common.valueToValue", "\(String(run.first)) to \(String(last))"))
            } else {
                items.append(String(run.first))
            }
        }
        let list = CountWording.list(items)
        // Every page of the runs counts, so "pages 1 to 4" is plural.
        let single = runs.count == 1 && runs[0].last == nil
        return single
            // Translators: Names one page of a PDF, in a sentence about which pages were read. %@ is the page's number, an identifier written without digit grouping.
            ? InterfaceText.line("pdfExtractionDiagnostics.pagePhrase.one", "page \(list)")
            // Translators: Names several pages of a PDF, in a sentence about which pages were read. %@ is a list of page numbers and ranges, such as "3 and 7" or "1 to 4, 7, and 9".
            : InterfaceText.line("pdfExtractionDiagnostics.pagePhrase.pages", "pages \(list)")
    }

    /// `pagePhrase` in English for the debug log (FR34).
    static func logPagePhrase(_ pageNumbers: [Int]) -> String {
        let runs = pageRuns(of: pageNumbers)
        guard !runs.isEmpty else { return "no pages" } // l10n: no (debug log)
        let items = runs.map { run in
            run.last.map { "\(run.first) to \($0)" } ?? "\(run.first)" // l10n: no (debug log)
        }
        let list = CountWording.list(items, locale: Locale(identifier: "en_US"))
        return "\(runs.count == 1 && runs[0].last == nil ? "page" : "pages") \(list)" // l10n: no (debug log)
    }

    // MARK: Sentence Parts

    /// How many pages had each source of text: "Of 12 pages, 9 have
    /// embedded text only and 3 have OCR text only." When one source
    /// accounts for every page it says so ("All 12 pages have embedded text
    /// only."), and a one-page PDF says "Its only page has ….".
    private var sourceSentence: String {
        let total = pages.count
        guard total > 0 else { return "The PDF has no pages." } // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        let counts: [(count: Int, description: String)] = [
            (pagesWithEmbeddedTextOnly.count, "embedded text only"), // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
            (pagesWithOCRTextOnly.count, "OCR text only"), // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
            (pagesWithEmbeddedAndOCRText.count, "both embedded and OCR text"), // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
            (pagesWithoutText.count, "no text") // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        ].filter { $0.count > 0 }

        if counts.count == 1, let only = counts.first {
            return total == 1
                ? "Its only page has \(only.description)." // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
                : "All \(total) pages have \(only.description)." // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        }
        let parts = counts.map { "\($0.count) \($0.count == 1 ? "has" : "have") \($0.description)" } // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
        return "Of \(total) pages, \(CountWording.list(parts, locale: Locale(identifier: "en_US")))." // l10n: no (not shown: no screen reads `summary` yet; English like a parser's report)
    }

    /// The pages OCR could not run on, grouped by reason in the order each
    /// reason first appears.
    private var pagesGroupedByReason: [(reason: String, pages: [Int])] {
        var reasons: [String] = []
        var pagesByReason: [String: [Int]] = [:]
        for page in pages {
            guard let reason = page.couldNotRunReason else { continue }
            if pagesByReason[reason] == nil { reasons.append(reason) }
            pagesByReason[reason, default: []].append(page.pageNumber)
        }
        return reasons.map { (reason: $0, pages: pagesByReason[$0] ?? []) }
    }

    /// The pages OCR could not run on, grouped by reason in the order each
    /// reason first appears: "pages 3 and 7 (reason); page 9 (other reason)".
    /// The reasons are a parser's English.
    private var failureGroups: String {
        var text = ""
        for (index, group) in pagesGroupedByReason.enumerated() {
            // Translators: One group of a PDF's pages that text recognition (OCR) could not run on, with the reason. %1$@ is the pages, such as "pages 3 and 7", and %2$@ the reason, a phrase in English.
            let item = InterfaceText.line("common.valueInParentheses", "\(Self.pagePhrase(group.pages)) (\(group.reason))")
            // Groups are told one after another, separated by a semicolon.
            if index == 0 {
                text = item
            } else {
                // Translators: Joins two groups of a PDF's pages that text recognition (OCR) could not run on, each with its reason: the pages and reason, a semicolon, then the next.
                text = InterfaceText.line("common.valueSemicolonValue", "\(text); \(item)")
            }
        }
        return text
    }

    /// `failureGroups` in English for the debug log (FR34).
    private var logFailureGroups: String {
        pagesGroupedByReason.map { "\(Self.logPagePhrase($0.pages)) (\($0.reason))" }.joined(separator: "; ") // l10n: no (debug log)
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
