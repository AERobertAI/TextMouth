import Foundation

// MARK: - Omissions

/// A chapter that a book's reading order names but whose text could not be
/// read. Reading stays tolerant, so the book's other chapters are still read;
/// each chapter left out is recorded as one of these, so an import can say
/// exactly what is missing instead of passing the surviving chapters off as
/// the whole book.
///
/// Nothing here is specific to one format: EPUB reports its spine this way,
/// and DAISY content files or DOCX parts can report through the same type.
struct ExtractionOmission: Equatable, Sendable {
    /// Why a chapter's text is not in the extracted book.
    enum Reason: Equatable, Sendable {
        /// The package lists the chapter's file, but no file is at that path.
        case missingMember
        /// The file is present, but its data could not be decoded: its
        /// compressed data is damaged, or it does not match its checksum.
        case unreadableMember
        /// The file was read, but its markup could not be turned into text.
        case malformedMarkup
        /// The reading order names an item for which the package lists no
        /// file, so there is nothing to read.
        case unlistedItem
        /// The file is a document of a type the app cannot read as text,
        /// named by its declared media type ("text/plain"), which is empty
        /// when the package declares none. Resources such as images are not
        /// chapters, so they never have this reason.
        case unsupportedMediaType(String)
    }

    /// The chapter's position in the reading order, counting from 1: the
    /// number a reader hears ("chapter 7").
    var chapterNumber: Int
    /// The chapter's file: its path inside the book's package, or, for an
    /// item with no file listed, the name the reading order gives it.
    var member: String
    /// Why the chapter could not be read.
    var reason: Reason
}

// MARK: - Report

/// What a tolerant extraction could not read, with a sentence that says so
/// aloud. An import presents the sentence as a warning and keeps the original
/// file; cache rebuilds record it in the debug log.
///
/// A PDF's report also says how each page's text was read (`pdf`): from
/// its embedded text, by OCR, both, or neither, and where OCR found
/// nothing or could not run (TODO T09).
struct ExtractionReport: Equatable, Sendable {
    /// Names the book in the report's sentences, completing "is missing
    /// from …" ("this EPUB book"), as `PackageDamage` names the container of
    /// a damaged file.
    var container: String
    /// How many chapters the reading order names, whether or not they could
    /// be read. Resources in the reading order, such as images, are not
    /// chapters and are not counted.
    var chapterCount: Int
    /// Chapters that were read but hold no text, such as a cover page. A
    /// blank chapter is not a problem, so it is counted here and never
    /// reported as an omission.
    var blankChapterCount: Int
    /// The chapters that could not be read, in reading order.
    var omissions: [ExtractionOmission]
    /// How each page of a PDF was read; nil for every other format.
    var pdf: PDFExtractionDiagnostics?

    /// A report of `chapterCount` chapters, `blankChapterCount` of them
    /// blank, with `omissions` left out, and, for a PDF, how its pages were
    /// read. The defaults describe an extraction with nothing to report, as
    /// formats that do not report yet produce.
    init(
        container: String = "this book",
        chapterCount: Int = 0,
        blankChapterCount: Int = 0,
        omissions: [ExtractionOmission] = [],
        pdf: PDFExtractionDiagnostics? = nil
    ) {
        self.container = container
        self.chapterCount = chapterCount
        self.blankChapterCount = blankChapterCount
        self.omissions = omissions
        self.pdf = pdf
    }

    /// Whether everything the source holds was read: every chapter the
    /// reading order names and, for a PDF, every page that needed OCR.
    var isComplete: Bool { omissions.isEmpty && (pdf?.isComplete ?? true) }

    /// What could not be read, for a reader to hear: one sentence naming
    /// every chapter left out, its file, and why, for example: "2 of 14
    /// chapters could not be read: chapter 7 (“OEBPS/ch07.xhtml”) is missing
    /// from this EPUB book; chapter 9 (“OEBPS/ch09.xhtml”) is damaged or
    /// incomplete." For a PDF, the sentence names the pages OCR could not
    /// run on (see `PDFExtractionDiagnostics.problem`).
    var message: String {
        var sentences: [String] = []
        if !omissions.isEmpty {
            let problems = omissions.map(describe).joined(separator: "; ")
            sentences.append("\(summary): \(problems).")
        }
        if let pageProblem = pdf?.problem {
            sentences.append(pageProblem)
        }
        guard sentences.isEmpty else { return sentences.joined(separator: " ") }
        return pdf == nil ? "Every chapter was read." : "Every page was read."
    }

    // MARK: Sentence Parts

    /// How many chapters could not be read, out of how many. When no chapter
    /// could be read the summary says so plainly rather than "3 of 3".
    private var summary: String {
        // A report whose chapter count was never filled in has no total to
        // give, and must not claim an impossible one such as "2 of 0".
        guard chapterCount >= omissions.count else {
            let count = CountWording.phrase(omissions.count, singular: "chapter", plural: "chapters")
            return "\(count) could not be read"
        }
        guard omissions.count == chapterCount else {
            return "\(omissions.count) of \(chapterCount) chapters could not be read"
        }
        return chapterCount == 1
            ? "The only chapter could not be read"
            : "None of the \(chapterCount) chapters could be read"
    }

    /// One omission as a clause: the chapter's number, its file in curly
    /// quotation marks as `PackageDamage` quotes file names, and the problem.
    private func describe(_ omission: ExtractionOmission) -> String {
        "chapter \(omission.chapterNumber) (“\(omission.member)”) \(problem(omission.reason))"
    }

    /// The words that complete "chapter N (“file”) …" for each reason.
    /// A damaged file uses the phrase every format's damage messages use.
    private func problem(_ reason: ExtractionOmission.Reason) -> String {
        switch reason {
        case .missingMember:
            return "is missing from \(container)"
        case .unreadableMember:
            return "is damaged or incomplete"
        case .malformedMarkup:
            return "has markup that could not be read"
        case .unlistedItem:
            return "has no file listed in \(container)"
        case .unsupportedMediaType(let type):
            return type.isEmpty
                ? "has no media type, so TextMouth cannot read it"
                : "is a “\(type)” file, which TextMouth cannot read"
        }
    }
}
