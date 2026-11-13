import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os

// MARK: - Error Types

/// Errors that can occur when parsing a PDF file
enum PDFParserError: LocalizedError {
    case fileNotFound(String)
    case cannotOpenPDF
    /// The PDF opens but is locked by a password TextMouth does not have,
    /// so PDFKit gives its pages neither text nor a drawing.
    case passwordProtected
    case noTextContent
    /// No page has embedded text, and OCR could not run where it was
    /// needed, for this reason.
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "PDF file not found at: \(path)"
        case .cannotOpenPDF: return "The PDF file could not be opened."
        case .passwordProtected: return "This PDF needs a password to open."
        case .noTextContent: return "No text content could be extracted from the PDF."
        case .ocrFailed(let reason):
            return "No text could be read from the PDF: it has no embedded text, and OCR could not run (\(reason))."
        }
    }
}

// MARK: - PDF Parser

/// Parses text-based and scanned PDF files into Markdown.
/// Uses PDFKit for text extraction with font-based heading detection,
/// PDFOutline for table of contents, and OCR (Vision, through
/// `PDFPageTextRecognizer`) for text that a page shows only as pixels.
///
/// The text embedded in a page is always kept, however short. OCR reads a
/// page with no embedded text in full, and on a page with some it reads
/// only the pictures that may hold more (`PDFRecognitionPlan`); what it
/// adds is merged in reading order without repeating embedded text
/// (`PDFPageTextMerger`). Each page's outcome is reported (TODO T09).
enum PDFTextParser {

    // MARK: - Public API

    /// Parse a PDF file into DocumentContent for reading/playback
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let metadata = readMetadata(from: url)
        let title = metadata?.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? Book.unknownAuthor

        let content = try MarkdownDocParser.parse(markdown: markdown, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// Extract Markdown from a PDF file, reading pictures with the default
    /// recognizer (Vision's in the app). Its one caller, `parse(url:)`, reads
    /// no page markers, so none are written (PG06).
    static func extractMarkdown(from url: URL) throws -> String {
        try extract(from: url, includesPages: false).markdown
    }

    /// The recognizer `extract(from:)` reads pictures with when its caller
    /// names none, as imports and cache rebuilds do: Vision's in the app;
    /// nil when OCR is not available. Tests replace it, and put it back, to
    /// see how a PDF whose pictures cannot be read is imported and cached.
    static var defaultRecognizer: (any PDFPageTextRecognizer)? {
        get { defaultRecognizerStore.withLock { $0 } }
        set { defaultRecognizerStore.withLock { $0 = newValue } }
    }

    /// Holds `defaultRecognizer` under a lock, since extractions on any
    /// thread read it.
    private static let defaultRecognizerStore = OSAllocatedUnfairLock<(any PDFPageTextRecognizer)?>(
        initialState: VisionPDFTextRecognizer()
    )

    /// A PDF's Markdown and the report of how each of its pages was read.
    struct Extraction {
        /// The whole document's Markdown.
        var markdown: String
        /// How each page's text was obtained, and the pages whose pictures
        /// OCR could not read (see `PDFExtractionDiagnostics`).
        var report: ExtractionReport
    }

    /// Extract Markdown from a PDF file with the report of how each page was
    /// read. Uses PDFKit text extraction with font-based heading detection,
    /// or the outline's headings when the PDF has one.
    /// - Parameter recognizer: reads text in pictures (by default,
    ///   `defaultRecognizer`); nil when OCR is not available, so pictures go
    ///   unread and the report says why.
    /// - Parameter includesPages: whether a page marker (PG06) is written
    ///   before every page's text: with the page's label from the PDF's
    ///   `/PageLabels` ("i", "ii", "1", "A-1"), or its number when it has
    ///   none. A page without text keeps its marker. False writes exactly
    ///   what cache format 3.0.7 wrote.
    /// - Throws: `PDFParserError.passwordProtected` when the PDF is locked
    ///   by a password, `.ocrFailed` when no page has embedded text
    ///   and OCR could not run, `.noTextContent` when there is no text at
    ///   all, or why the file could not be opened.
    static func extract(
        from url: URL,
        recognizer: (any PDFPageTextRecognizer)? = defaultRecognizer,
        includesPages: Bool = true
    ) throws -> Extraction {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFParserError.fileNotFound(url.path)
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFParserError.cannotOpenPDF
        }
        // A PDF locked by a password opens, but its pages give no text and
        // cannot be drawn, so without this check it would be reported as a
        // failure of OCR. Say what is true: it needs a password. (A PDF that
        // restricts only copying or printing is not locked and reads as usual.)
        guard !document.isLocked else {
            throw PDFParserError.passwordProtected
        }
        // However the extraction ends, the outline it read is taken apart
        // before the document is released (`takeApartOutline(of:)`).
        defer { takeApartOutline(of: document) }

        // Try outline-based chapter extraction first
        let outline = extractOutline(from: document)

        // When the PDF has an outline, use that for headings and extract
        // page text without font-based heading detection (avoids false positives
        // from LaTeX/design fonts that use slightly different sizes for first
        // paragraphs, drop caps, etc.). Only use font heuristics when there's
        // no outline to provide structure.
        let hasOutline = !outline.isEmpty
        var pageTexts: [PageText] = []
        var diagnoses: [PDFPageDiagnosis] = []
        var ocr = OCRSession(recognizer: recognizer)
        // Every page's label as PDFKit gives it, in page order, one entry
        // per page whether or not it has text (PG06). It stays empty, and
        // so marks nothing, when pages are not included: `pageTexts` holds
        // only the pages with text, as it always did, so the output without
        // pages is untouched. An empty label means "use the page's number".
        var pageLabels: [String] = []

        for i in 0..<document.pageCount {
            let page = document.page(at: i)
            if includesPages { pageLabels.append(page?.label ?? "") }
            guard let page else { continue }
            // Each page's text, attributes, and pictures are temporary;
            // draining them page by page keeps a long PDF's memory flat.
            let reading = autoreleasepool {
                readPage(page, number: i + 1, detectsHeadings: !hasOutline, ocr: &ocr)
            }
            diagnoses.append(reading.diagnosis)
            if !reading.markdown.isEmpty {
                pageTexts.append(PageText(pageIndex: i, markdown: reading.markdown))
            }
        }

        let diagnostics = PDFExtractionDiagnostics(pages: diagnoses, ocrUnavailableReason: ocr.unavailableReason)
        guard !pageTexts.isEmpty else {
            // Without embedded text anywhere, OCR was the only way to read
            // the PDF: say why it could not, when that is what happened.
            if let reason = diagnostics.firstOCRFailureReason {
                throw PDFParserError.ocrFailed(reason)
            }
            throw PDFParserError.noTextContent
        }

        let markdown: String
        if hasOutline {
            // If we have an outline, use it to insert chapter markers
            markdown = buildMarkdownWithOutline(
                pageTexts: pageTexts,
                outline: outline,
                document: document,
                pageLabels: includesPages ? pageLabels : nil
            )
        } else if includesPages {
            // No outline, with a marker before every page (PG06).
            markdown = buildMarkdownWithPageMarkers(pageTexts: pageTexts, pageLabels: pageLabels)
        } else {
            // No outline — just concatenate page text (with font-based headings)
            markdown = pageTexts.map(\.markdown)
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Extraction(markdown: markdown, report: ExtractionReport(container: "this PDF", pdf: diagnostics))
    }

    /// Read metadata (title, author) from PDF document attributes
    static func readMetadata(from url: URL) -> PDFMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attrs = document.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Return metadata if at least one field is populated
        guard !title.isEmpty || !author.isEmpty else { return nil }
        return PDFMetadata(title: title, author: author)
    }

    // MARK: - Reading One Page

    /// One page's Markdown, kept with the index of the page it came from
    /// until the document is assembled.
    struct PageText {
        var pageIndex: Int
        var markdown: String
    }

    /// What reading one page produced: its Markdown (empty when it holds no
    /// text) and how its text was obtained.
    private struct PageReading {
        var markdown: String
        var diagnosis: PDFPageDiagnosis
    }

    /// Reads one page. Its embedded text is always kept, however short. A
    /// page with none is read whole by OCR, as a scanned page is. A page
    /// with some has OCR read only the pictures that may hold more
    /// (`PDFRecognitionPlan`), and what OCR finds there is merged in
    /// reading order without repeating embedded text (`PDFPageTextMerger`).
    private static func readPage(
        _ page: PDFPage,
        number: Int,
        detectsHeadings: Bool,
        ocr: inout OCRSession
    ) -> PageReading {
        let lines = embeddedLines(of: page, detectsHeadings: detectsHeadings)
        guard !lines.isEmpty else {
            return readScannedPage(page, number: number, ocr: &ocr)
        }

        // Pictures are found from the page's drawing operators. Only a page
        // that draws some needs to know where its lines are.
        let images = page.pageRef.map(PDFPageImageScanner.imageRects(on:)) ?? []
        let lineBounds = images.isEmpty ? [] : bounds(of: lines, on: page)
        let regions = images.isEmpty ? [] : PDFRecognitionPlan.regions(
            images: images,
            visibleBounds: visibleBounds(of: page),
            embeddedLines: lineBounds.compactMap { $0 },
            rotation: page.rotation
        )
        guard !regions.isEmpty else {
            let diagnosis = PDFPageDiagnosis(pageNumber: number, source: .embedded, recognition: .notNeeded)
            return PageReading(markdown: joinLinesIntoParagraphs(lines), diagnosis: diagnosis)
        }

        let recognition = ocr.recognize(regions, on: page)
        let merged = PDFPageTextMerger.merge(
            lines: lines, lineBounds: lineBounds, recognized: recognition.lines, rotation: page.rotation
        )
        let diagnosis = PDFPageDiagnosis(
            pageNumber: number,
            source: merged.addedLineCount > 0 ? .both : .embedded,
            recognition: recognition.outcome
        )
        return PageReading(markdown: merged.markdown, diagnosis: diagnosis)
    }

    /// Reads a page that has no embedded text by OCR of the whole shown
    /// page, since a scan's text may be drawn in any way. Each recognized
    /// line becomes a line of Markdown, as scanned pages have always been
    /// written.
    private static func readScannedPage(_ page: PDFPage, number: Int, ocr: inout OCRSession) -> PageReading {
        let recognition = ocr.recognize([visibleBounds(of: page)], on: page)
        let diagnosis = PDFPageDiagnosis(
            pageNumber: number,
            source: recognition.lines.isEmpty ? .none : .recognized,
            recognition: recognition.outcome
        )
        return PageReading(markdown: recognition.lines.map(\.text).joined(separator: "\n"), diagnosis: diagnosis)
    }

    /// The page's embedded text as the lines the paragraph joiner reads,
    /// with headings detected from font sizes when `detectsHeadings`. Empty
    /// when the page's text is nothing but white space. Any other text is
    /// kept, however short: a title, a folio, or a caption is never
    /// replaced by OCR's reading of it (TODO T09), as it was when a page
    /// with fewer than 10 characters was taken for a scan.
    private static func embeddedLines(of page: PDFPage, detectsHeadings: Bool) -> [TextLine] {
        guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let attributed = page.attributedString else {
            // PDFKit gives an attributed string whenever it gives text;
            // should it not, the text is still kept, as body text.
            return unformattedLines(in: text)
        }
        return detectsHeadings ? formattedLines(in: attributed) : plainLines(in: attributed)
    }

    /// The part of `page` that is shown: its crop box within its media box.
    private static func visibleBounds(of page: PDFPage) -> CGRect {
        let media = page.bounds(for: .mediaBox)
        let shown = page.bounds(for: .cropBox).intersection(media)
        return shown.isNull || shown.isEmpty ? media : shown
    }

    /// Where each of `lines` is on `page`, in default user space, nil for a
    /// line PDFKit gives no bounds for. The lines are found again in the
    /// page's text, because the paragraph joiner's lines are exactly that
    /// text's lines holding more than spaces and tabs, in order. Empty when
    /// the two do not correspond, so the lines' positions go unused.
    private static func bounds(of lines: [TextLine], on page: PDFPage) -> [CGRect?] {
        guard let text = page.string else { return [] }
        let ranges = nonBlankLineRanges(in: text as NSString)
        guard ranges.count == lines.count else { return [] }
        return ranges.map { range in
            guard let selection = page.selection(for: range) else { return nil }
            let rect = selection.bounds(for: page)
            return rect.isEmpty ? nil : rect
        }
    }

    /// The range of every line of `text` (lines end at "\n") that holds more
    /// than spaces and tabs, without its leading and trailing spaces and
    /// tabs, in order. These are the lines the line readers below turn into
    /// `TextLine`s.
    static func nonBlankLineRanges(in text: NSString) -> [NSRange] {
        let content = CharacterSet.whitespaces.inverted
        var ranges: [NSRange] = []
        var lineStart = 0
        while true {
            let rest = NSRange(location: lineStart, length: text.length - lineStart)
            let newline = text.range(of: "\n", options: [], range: rest)
            let lineEnd = newline.location == NSNotFound ? text.length : newline.location
            let line = NSRange(location: lineStart, length: lineEnd - lineStart)
            let first = text.rangeOfCharacter(from: content, options: [], range: line)
            if first.location != NSNotFound {
                let last = text.rangeOfCharacter(from: content, options: .backwards, range: line)
                ranges.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            }
            guard newline.location != NSNotFound else { return ranges }
            lineStart = lineEnd + 1
        }
    }

    /// The lines of plain text, each trimmed of spaces and tabs, as body
    /// text in the default body size: how a page is read in the unexpected
    /// case that PDFKit gives its text without attributes.
    private static func unformattedLines(in text: String) -> [TextLine] {
        let bodySize = mostCommonFontSize(in: [:])
        return nonBlankLineRanges(in: text as NSString).map { range in
            TextLine(
                text: (text as NSString).substring(with: range),
                isHeading: false, headingLevel: 0, fontSize: bodySize
            )
        }
    }

    // MARK: - OCR

    /// OCR for one document. Once OCR proves unavailable, later pages are
    /// not asked again; each records the same reason instead.
    private struct OCRSession {
        /// What OCR recognized on one page, and why it could not read all
        /// of what it was asked to.
        struct PageRecognition {
            /// The recognized lines, region by region, each in reading order.
            var lines: [PDFRecognizedLine] = []
            /// The first reason a region could not be read; nil when every
            /// region was.
            var failure: String?

            /// What OCR did on the page, for the page's diagnosis. A page
            /// with any region left unread could not be read in full.
            var outcome: PDFPageDiagnosis.Recognition {
                if let failure { return .couldNotRun(failure) }
                return lines.isEmpty ? .foundNothing : .recognizedText
            }
        }

        /// What OCR says when there is no recognizer to ask.
        static let notAvailable = "text recognition is not available"

        /// Recognizes text in pictures; nil when this process has no OCR.
        let recognizer: (any PDFPageTextRecognizer)?
        /// Why OCR cannot run, once a page has needed it and found it
        /// unavailable; nil until then.
        private(set) var unavailableReason: String?

        init(recognizer: (any PDFPageTextRecognizer)?) {
            self.recognizer = recognizer
        }

        /// Reads `regions` of `page`, in order. A region that cannot be read
        /// is recorded and the others are still read, unless OCR turns out
        /// to be unavailable, which ends the reading of this page and of
        /// every later one.
        mutating func recognize(_ regions: [CGRect], on page: PDFPage) -> PageRecognition {
            var result = PageRecognition()
            for region in regions {
                guard unavailableReason == nil, let recognizer else {
                    let reason = unavailableReason ?? Self.notAvailable
                    unavailableReason = reason
                    result.failure = result.failure ?? reason
                    break
                }
                do {
                    result.lines += try recognizer.recognizeLines(in: region, of: page)
                } catch let error as PDFTextRecognitionError {
                    if case .unavailable(let reason) = error { unavailableReason = reason }
                    result.failure = result.failure ?? error.reason
                } catch {
                    result.failure = result.failure ?? "text recognition failed: \(error.localizedDescription)"
                }
            }
            return result
        }
    }

    // MARK: - Plain Text Extraction (for PDFs with outline)

    /// The lines of a PDF page's text (`attrString`) with bold/italic inline
    /// formatting but no heading detection. Used when the PDF has an outline
    /// that provides reliable chapter structure, avoiding false heading
    /// positives from font size variations. `joinLinesIntoParagraphs` turns
    /// the lines into the page's Markdown.
    private static func plainLines(in attrString: NSAttributedString) -> [TextLine] {
        var lines: [TextLine] = []
        var currentLineText = ""
        let bodyFontSize = detectBodyFontSize(in: attrString)
        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let text = attrString.attributedSubstring(from: range).string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("\n") else {
                return
            }

            let font = attrs[.font] as? PlatformFont
            let fontSize = font?.pointSize ?? bodyFontSize
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let isItalic = font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false

            let segments = text.components(separatedBy: "\n")
            for (segIndex, segment) in segments.enumerated() {
                if segIndex > 0 {
                    let trimmed = currentLineText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        lines.append(TextLine(text: trimmed, isHeading: false,
                                              headingLevel: 0, fontSize: fontSize))
                    }
                    currentLineText = ""
                }

                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                var formatted = trimmed
                if isBold && isItalic {
                    formatted = "***\(formatted)***"
                } else if isBold {
                    formatted = "**\(formatted)**"
                } else if isItalic {
                    formatted = "*\(formatted)*"
                }

                if !currentLineText.isEmpty { currentLineText += " " }
                currentLineText += formatted
            }
        }

        let finalTrimmed = currentLineText.trimmingCharacters(in: .whitespaces)
        if !finalTrimmed.isEmpty {
            lines.append(TextLine(text: finalTrimmed, isHeading: false,
                                  headingLevel: 0,
                                  fontSize: detectBodyFontSize(in: attrString)))
        }

        return lines
    }

    // MARK: - Text Page Extraction (with heading detection)

    /// A single line of text extracted from the PDF with its formatting metadata
    struct TextLine {
        var text: String
        var isHeading: Bool
        var headingLevel: Int
        var fontSize: CGFloat
    }

    /// The lines of a text-based PDF page's text (`attrString`), using font
    /// attribute analysis to detect headings, bold, and italic formatting.
    /// `joinLinesIntoParagraphs` turns the lines into the page's Markdown,
    /// joining consecutive body-text lines into paragraphs (PDFs have hard
    /// line breaks at each visual line, which we need to unwrap).
    private static func formattedLines(in attrString: NSAttributedString) -> [TextLine] {
        // First pass: determine the body font size (most common size)
        let bodyFontSize = detectBodyFontSize(in: attrString)

        // Second pass: build an array of text lines with formatting metadata
        var lines: [TextLine] = []
        var currentLineText = ""
        var currentLineIsHeading = false
        var currentHeadingLevel = 0
        var currentFontSize: CGFloat = bodyFontSize

        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let text = attrString.attributedSubstring(from: range).string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("\n") else {
                return
            }

            let font = attrs[.font] as? PlatformFont
            let fontSize = font?.pointSize ?? bodyFontSize
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let isItalic = font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false

            let isHeading = fontSize > bodyFontSize * 1.15 && bodyFontSize > 0
            let headingLevel = headingLevelFromFontSize(fontSize, bodySize: bodyFontSize)

            let segments = text.components(separatedBy: "\n")
            for (segIndex, segment) in segments.enumerated() {
                if segIndex > 0 {
                    // Newline boundary — flush current line
                    let trimmed = currentLineText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        lines.append(TextLine(
                            text: trimmed,
                            isHeading: currentLineIsHeading,
                            headingLevel: currentHeadingLevel,
                            fontSize: currentFontSize
                        ))
                    }
                    currentLineText = ""
                    currentLineIsHeading = false
                    currentHeadingLevel = 0
                    currentFontSize = bodyFontSize
                }

                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                // Apply inline formatting — but skip bold/italic on headings
                // since the # prefix already conveys emphasis
                var formatted = trimmed
                if !isHeading {
                    if isBold && isItalic {
                        formatted = "***\(formatted)***"
                    } else if isBold {
                        formatted = "**\(formatted)**"
                    } else if isItalic {
                        formatted = "*\(formatted)*"
                    }
                }

                if isHeading {
                    currentLineIsHeading = true
                    currentHeadingLevel = max(currentHeadingLevel, headingLevel)
                }
                currentFontSize = fontSize

                if !currentLineText.isEmpty { currentLineText += " " }
                currentLineText += formatted
            }
        }

        // Flush final line
        let finalTrimmed = currentLineText.trimmingCharacters(in: .whitespaces)
        if !finalTrimmed.isEmpty {
            lines.append(TextLine(
                text: finalTrimmed,
                isHeading: currentLineIsHeading,
                headingLevel: currentHeadingLevel,
                fontSize: currentFontSize
            ))
        }

        // Third pass: demote "headings" that are too long to be real headings.
        // Real chapter/section headings are typically short — a line with 80+
        // characters in a slightly larger font is more likely body text than a
        // heading (common in LaTeX PDFs where first paragraphs use a different size).
        for idx in lines.indices where lines[idx].isHeading {
            if lines[idx].text.count > 80 {
                lines[idx].isHeading = false
                lines[idx].headingLevel = 0
            }
        }

        // The fourth pass, joining consecutive body-text lines into
        // paragraphs, is `joinLinesIntoParagraphs`.
        return lines
    }

    /// One heading or paragraph of a page's Markdown, as the paragraph
    /// joiner writes it, with the line it begins with, so that text read
    /// from the page's pictures can be placed between whole paragraphs
    /// (TODO T09).
    struct ParagraphBlock: Equatable {
        /// The block's Markdown with the line breaks around it, exactly as
        /// it is joined into the page.
        var markdown: String
        /// The index, among the lines joined, of the block's first line.
        var firstLine: Int
    }

    /// Join an array of text lines into Markdown, merging consecutive body-text
    /// lines into single paragraphs where appropriate.
    static func joinLinesIntoParagraphs(_ lines: [TextLine]) -> String {
        markdown(of: paragraphBlocks(lines))
    }

    /// The Markdown of a page's `blocks`, joined in order.
    static func markdown(of blocks: [ParagraphBlock]) -> String {
        blocks.map(\.markdown).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Join an array of text lines into headings and paragraphs, merging
    /// consecutive body-text lines into single paragraphs where appropriate.
    /// PDF line breaks are visual, not semantic — a line that doesn't end
    /// with sentence-ending punctuation and is followed by another body line
    /// at the same font size is likely a continuation of the same paragraph.
    static func paragraphBlocks(_ lines: [TextLine]) -> [ParagraphBlock] {
        var blocks: [ParagraphBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let firstLine = i

            if line.isHeading {
                // Headings always stand alone
                let prefix = String(repeating: "#", count: max(1, min(line.headingLevel, 6)))
                blocks.append(ParagraphBlock(markdown: "\n\(prefix) \(line.text)\n\n", firstLine: firstLine))
                i += 1
                continue
            }

            // Body text — accumulate continuation lines into a single paragraph
            var paragraph = line.text
            while i + 1 < lines.count {
                let nextLine = lines[i + 1]

                // Stop joining if the next line is a heading
                if nextLine.isHeading { break }

                // Stop joining if there's a significant font size change
                // (suggests a different text block)
                if abs(nextLine.fontSize - line.fontSize) > 1.0 { break }

                // Stop joining if the current paragraph ends with sentence-ending
                // punctuation followed by a blank-ish next line, or looks like a
                // list item / standalone short line
                let endsWithTerminator = paragraph.hasSuffix(".")
                    || paragraph.hasSuffix("!")
                    || paragraph.hasSuffix("?")
                    || paragraph.hasSuffix(":")
                    || paragraph.hasSuffix(";")

                let nextIsShort = nextLine.text.count < 40
                let nextStartsCapital = nextLine.text.first?.isUppercase ?? false

                // If current ends with a period and next starts with a capital,
                // it's likely a new paragraph
                if endsWithTerminator && nextStartsCapital && nextIsShort { break }

                // If the next line looks like a list item, keep it separate
                if nextLine.text.hasPrefix("•") || nextLine.text.hasPrefix("-")
                    || nextLine.text.hasPrefix("–") {
                    break
                }

                // Numbered list item detection (e.g. "1.", "2.", "3.")
                let nextTrimmed = nextLine.text.trimmingCharacters(in: .whitespaces)
                if let firstChar = nextTrimmed.first, firstChar.isNumber {
                    let prefix = nextTrimmed.prefix(while: { $0.isNumber })
                    if nextTrimmed.dropFirst(prefix.count).hasPrefix(".") { break }
                }

                // Otherwise, join this line into the current paragraph
                paragraph += " " + nextLine.text
                i += 1
            }

            blocks.append(ParagraphBlock(markdown: "\n\(paragraph)\n", firstLine: firstLine))
            i += 1
        }

        return blocks
    }

    /// Detect the most common font size in an attributed string (the "body" size)
    private static func detectBodyFontSize(in attrString: NSAttributedString) -> CGFloat {
        var sizeCounts: [CGFloat: Int] = [:]
        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            let roundedSize = (font.pointSize * 2).rounded() / 2 // Round to nearest 0.5
            let charCount = range.length
            sizeCounts[roundedSize, default: 0] += charCount
        }

        return mostCommonFontSize(in: sizeCounts)
    }

    /// Select the font size accounting for the most extracted characters.
    static func mostCommonFontSize(in sizeCounts: [CGFloat: Int]) -> CGFloat {
        sizeCounts.max(by: { $0.value < $1.value })?.key ?? 12.0
    }

    /// Map a font size to a heading level relative to the body font size.
    /// Thresholds calibrated against common PDF heading conventions:
    /// 24pt/11pt=2.18→h1, 18pt/11pt=1.64→h2, 14pt/11pt=1.27→h3
    static func headingLevelFromFontSize(_ fontSize: CGFloat, bodySize: CGFloat) -> Int {
        guard bodySize > 0 else { return 2 }
        let ratio = fontSize / bodySize

        if ratio >= 1.9 { return 1 }       // ~2x body size → h1 (e.g. 24pt/11pt)
        if ratio >= 1.5 { return 2 }       // ~1.5x+ → h2 (e.g. 18pt/11pt)
        if ratio >= 1.2 { return 3 }       // ~1.2x+ → h3 (e.g. 14pt/11pt)
        if ratio >= 1.15 { return 4 }      // barely larger → h4
        return 5
    }

    // MARK: - Outline / Table of Contents

    /// Outline entry extracted from PDF bookmarks
    struct OutlineEntry {
        var title: String
        var level: Int     // 0-based depth in the outline tree
        var pageIndex: Int // zero-based page index
    }

    /// Extract the table of contents from a PDF's outline/bookmarks.
    /// Reading every entry leaves PDFKit holding them all, which
    /// `extract(from:)` takes apart before it releases the document
    /// (`takeApartOutline(of:)`).
    static func extractOutline(from document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }

        var entries: [OutlineEntry] = []
        traverseOutline(root, depth: -1, document: document, entries: &entries)
        return entries
    }

    /// Append the entries below `outline`, whose own depth is `depth` (the
    /// root's is -1), to `entries` in document order: each labelled entry
    /// with a destination, at its depth.
    ///
    /// The walk keeps its own stack of the entries still to visit, each with
    /// its depth, rather than calling itself for every level: PDFKit serves
    /// an outline of any depth, and imports run on a worker thread's 512 KiB
    /// stack, which such a call chain overflowed. Children are pushed last
    /// first, so they are visited in document order.
    private static func traverseOutline(
        _ outline: PDFOutline,
        depth: Int,
        document: PDFDocument,
        entries: inout [OutlineEntry]
    ) {
        /// The entries directly below `parent`, last first, each with
        /// `depth`, the depth they are at.
        func pending(under parent: PDFOutline, depth: Int) -> [(outline: PDFOutline, depth: Int)] {
            (0..<parent.numberOfChildren).reversed().compactMap { index in
                parent.child(at: index).map { ($0, depth) }
            }
        }
        var stack = pending(under: outline, depth: depth + 1)
        while let (child, childDepth) = stack.popLast() {
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !label.isEmpty, let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                entries.append(OutlineEntry(
                    title: label,
                    level: max(0, childDepth),
                    pageIndex: pageIndex
                ))
            }

            stack += pending(under: child, depth: childDepth + 1)
        }
    }

    /// Take `document`'s outline apart, deepest entries first, so that
    /// releasing the document never recurses. PDFKit makes an outline's
    /// entries as they are read, and `extractOutline(from:)` reads them all;
    /// it then releases them one nested call per level, about 480 bytes of
    /// stack each, so a PDF whose outline nests some 1,100 levels deep
    /// overflowed the 512 KiB stack of the worker thread an import runs on
    /// when the document was released, ending TextMouth. The file is never
    /// written, so it keeps its outline.
    ///
    /// Every entry is gathered with an explicit stack, parents before their
    /// children; in the reverse of that order each entry comes after all of
    /// its descendants, so removing the entries from their parents in that
    /// order leaves none holding another by the time they are released.
    private static func takeApartOutline(of document: PDFDocument) {
        guard let root = document.outlineRoot else { return }
        var entries: [PDFOutline] = []
        var stack = [root]
        while let entry = stack.popLast() {
            entries.append(entry)
            stack += (0..<entry.numberOfChildren).compactMap { entry.child(at: $0) }
        }
        for entry in entries.reversed() where entry !== root {
            entry.removeFromParent()
        }
    }

    // MARK: - Outline-Based Markdown Assembly

    /// Write the marker of the page at `pageIndex` (PG06) as a block of its
    /// own, so it adds no reading text: the page's label from `pageLabels`,
    /// or its number when the label is empty. An index outside `pageLabels`
    /// gets its number too, so no index can trap.
    private static func writePageMarker(pageIndex: Int, pageLabels: [String], into markdown: inout String) {
        let label = pageLabels.indices.contains(pageIndex)
            ? plainNumberLabel(pageLabels[pageIndex], ordinal: pageIndex + 1)
            : ""
        let marker = MarkdownPageMarker(label: label, ordinal: pageIndex + 1)
        MarkdownMarkerWriter.write(marker.markdown, inline: false, into: &markdown)
    }

    /// The characters a locale may put between the thousands of a number:
    /// comma, period, apostrophe, right single quotation mark, space,
    /// no-break space, and narrow no-break space.
    private static let groupingSeparators: Set<Unicode.Scalar> = [
        ",", ".", "'", "\u{2019}", " ", "\u{00A0}", "\u{202F}",
    ]

    /// A page label PDFKit wrote by formatting the page's own number for a
    /// locale ("1,000", "1.000", "1 000": the thousandth page of a PDF that
    /// names no labels), as plain ASCII digits ("1000"). Page 1,000 of 2,000
    /// would not count as a whole number among the book's pages, so "Page
    /// 1,000 of 999" would be spoken.
    ///
    /// Only a label that is the page's own number, `ordinal` (its 1-based
    /// place in the PDF), is changed: PDFKit writes that number with the
    /// locale's grouping only when the PDF names no labels (checked on this
    /// Mac: the thousandth page reads "1,000" in en_US, "1.000" in de_DE, and
    /// "1" and a narrow no-break space and "000" in fr_FR, while a PDF's own
    /// decimal labels, such as 1000 from `/St 1000`, come out plain in en_US
    /// and de_DE). A label the PDF gave that looks like a grouped number is
    /// not that number: "1.100" on page 100, from the prefix "1." and the
    /// number 100, stays as it is, and is not the whole number 1100 that
    /// "of N" would take the book to run to.
    ///
    /// The label must also be one to three ASCII digits followed by one or
    /// more groups of a grouping separator and exactly three ASCII digits,
    /// whatever the locale; any other label (roman numerals, "A-1", "12",
    /// "1,5", "1,00") is returned as PDFKit gave it.
    static func plainNumberLabel(_ label: String, ordinal: Int) -> String {
        var digits = ""
        var leadingDigits = 0         // digits before the first separator
        var digitsSinceSeparator = 0  // digits since the last separator
        var separators = 0
        for scalar in label.unicodeScalars {
            if (Unicode.Scalar("0")...Unicode.Scalar("9")).contains(scalar) {
                digits.unicodeScalars.append(scalar)
                digitsSinceSeparator += 1
                if separators == 0 { leadingDigits += 1 }
            } else if groupingSeparators.contains(scalar), digitsSinceSeparator > 0,
                      separators > 0 ? digitsSinceSeparator == 3 : leadingDigits <= 3 {
                // A separator ends a group: the first of one to three digits,
                // then only groups of exactly three.
                separators += 1
                digitsSinceSeparator = 0
            } else {
                return label
            }
        }
        // The label must end on a complete group of three digits, and say
        // the page's own number, written as numbers are written: "0.100" on
        // page 100 is not that number with its leading zero kept.
        guard separators > 0, digitsSinceSeparator == 3, digits == String(ordinal) else { return label }
        return digits
    }

    /// Join the pages of a PDF without an outline (PG06): each page's marker,
    /// then its text when it has any, with the paragraph break between
    /// pages that the plain join writes. Taking the markers (and the blank
    /// lines after them) back out leaves exactly that plain join.
    /// - Parameters:
    ///   - pageTexts: The pages that have text, in page order.
    ///   - pageLabels: The label of every page, with or without text.
    private static func buildMarkdownWithPageMarkers(pageTexts: [PageText], pageLabels: [String]) -> String {
        let textByPage = Dictionary(
            pageTexts.map { ($0.pageIndex, $0.markdown) },
            uniquingKeysWith: { first, _ in first }
        )
        var markdown = ""
        for pageIndex in pageLabels.indices {
            writePageMarker(pageIndex: pageIndex, pageLabels: pageLabels, into: &markdown)
            if let text = textByPage[pageIndex] {
                markdown += text + "\n\n"
            }
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build Markdown with chapter markers derived from the PDF outline.
    /// Inserts heading markers at the appropriate page boundaries.
    /// - Parameter pageLabels: The label of every page (PG06): when not nil,
    ///   each page's marker is written before that page's headings and text,
    ///   and a page without text gets its marker alone (its outline headings
    ///   are still left out). Nil writes no markers.
    private static func buildMarkdownWithOutline(
        pageTexts: [PageText],
        outline: [OutlineEntry],
        document: PDFDocument,
        pageLabels: [String]?
    ) -> String {
        // Build a map from page index → outline entries that start on that page
        var pageOutlineMap: [Int: [OutlineEntry]] = [:]
        for entry in outline {
            pageOutlineMap[entry.pageIndex, default: []].append(entry)
        }

        var markdown = ""

        // With pages, every page is visited so a page without text keeps its
        // marker; without, only the pages with text, as before.
        let textByPage = Dictionary(
            pageTexts.map { ($0.pageIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pageIndexes = pageLabels.map { Array($0.indices) } ?? pageTexts.map(\.pageIndex)

        for pageIndex in pageIndexes {
            if let pageLabels {
                writePageMarker(pageIndex: pageIndex, pageLabels: pageLabels, into: &markdown)
            }
            guard let pageText = textByPage[pageIndex] else { continue }
            var cleanedPageMarkdown = pageText.markdown

            // Insert outline headings for this page
            if let entries = pageOutlineMap[pageIndex] {
                for entry in entries {
                    let level = min(entry.level + 1, 6) // outline depth 0 → h1
                    let prefix = String(repeating: "#", count: level)
                    markdown += "\n\(prefix) \(entry.title)\n\n"

                    // Remove the heading text from the page content to avoid
                    // duplication (the page text often contains the same text
                    // as the outline entry, possibly in different case)
                    cleanedPageMarkdown = removeHeadingDuplicate(
                        entry.title, from: cleanedPageMarkdown
                    )
                }
            }

            let trimmed = cleanedPageMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                markdown += trimmed + "\n\n"
            }
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove a heading's duplicate text from page content.
    /// The outline heading is authoritative; the page text may contain the same
    /// words in different case (e.g. "PREFACE" vs outline "Preface").
    static func removeHeadingDuplicate(_ heading: String, from text: String) -> String {
        let headingLower = heading.lowercased()
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmedLower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Remove lines that are just the heading text (case-insensitive)
            // Also handle lines like "PART I" matching outline "Part I. The Special Theory..."
            if trimmedLower == headingLower { continue }
            // Check if the heading contains this short line (e.g. outline "I. Physical Meaning..."
            // and page has standalone "I" or "PHYSICAL MEANING OF GEOMETRICAL PROPOSITIONS")
            if !trimmedLower.isEmpty && trimmedLower.count <= headingLower.count
                && headingLower.contains(trimmedLower) && trimmedLower.count < 60 {
                continue
            }
            result.append(line)
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Metadata

/// Basic metadata extracted from PDF document attributes
struct PDFMetadata {
    var title: String
    var author: String
}
