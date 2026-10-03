import Foundation
import PDFKit
import Vision
import AppKit

// MARK: - Error Types

/// Errors that can occur when parsing a PDF file
enum PDFParserError: LocalizedError {
    case fileNotFound(String)
    case cannotOpenPDF
    case noTextContent
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "PDF file not found at: \(path)"
        case .cannotOpenPDF: return "The PDF file could not be opened."
        case .noTextContent: return "No text content could be extracted from the PDF."
        case .ocrFailed(let msg): return "OCR failed: \(msg)"
        }
    }
}

// MARK: - PDF Parser

/// Parses text-based and scanned PDF files into Markdown.
/// Uses PDFKit for text extraction with font-based heading detection,
/// PDFOutline for table of contents, and Vision OCR as a fallback
/// for scanned/image-only pages.
enum PDFTextParser {

    // MARK: - Public API

    /// Parse a PDF file into DocumentContent for reading/playback
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let metadata = readMetadata(from: url)
        let title = metadata?.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? "Unknown"

        let content = try MarkdownDocParser.parse(markdown: markdown, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// Extract Markdown from a PDF file. Main entry point for MarkdownCacheService.
    /// Uses PDFKit text extraction with font-based heading detection.
    /// Falls back to Vision OCR for pages with no embedded text.
    static func extractMarkdown(from url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFParserError.fileNotFound(url.path)
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFParserError.cannotOpenPDF
        }

        // Try outline-based chapter extraction first
        let outline = extractOutline(from: document)

        // When the PDF has an outline, use that for headings and extract
        // page text without font-based heading detection (avoids false positives
        // from LaTeX/design fonts that use slightly different sizes for first
        // paragraphs, drop caps, etc.). Only use font heuristics when there's
        // no outline to provide structure.
        let hasOutline = !outline.isEmpty
        var allPageTexts: [(pageIndex: Int, markdown: String, wasOCR: Bool)] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }

            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if pageText.count >= 10 {
                if hasOutline {
                    // Outline provides structure — extract plain text with inline
                    // formatting (bold/italic) but no heading detection
                    let markdown = extractPlainMarkdownFromPage(page)
                    allPageTexts.append((i, markdown, false))
                } else {
                    // No outline — use font analysis for heading detection
                    let markdown = extractMarkdownFromTextPage(page)
                    allPageTexts.append((i, markdown, false))
                }
            } else {
                // Possibly scanned page — try OCR
                let ocrText = performOCR(on: page)
                if !ocrText.isEmpty {
                    allPageTexts.append((i, ocrText, true))
                }
            }
        }

        guard !allPageTexts.isEmpty else {
            throw PDFParserError.noTextContent
        }

        // If we have an outline, use it to insert chapter markers
        if hasOutline {
            return buildMarkdownWithOutline(
                pageTexts: allPageTexts,
                outline: outline,
                document: document
            )
        }

        // No outline — just concatenate page text (with font-based headings)
        return allPageTexts.map { $0.markdown }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Plain Text Extraction (for PDFs with outline)

    /// Extract text from a PDF page with bold/italic inline formatting but
    /// no heading detection. Used when the PDF has an outline that provides
    /// reliable chapter structure, avoiding false heading positives from font
    /// size variations.
    private static func extractPlainMarkdownFromPage(_ page: PDFPage) -> String {
        guard let attrString = page.attributedString else {
            return page.string ?? ""
        }

        var lines: [TextLine] = []
        var currentLineText = ""
        let bodyFontSize = detectBodyFontSize(in: attrString)
        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let text = attrString.attributedSubstring(from: range).string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("\n") else {
                return
            }

            let font = attrs[.font] as? NSFont
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

        return joinLinesIntoParagraphs(lines)
    }

    // MARK: - Text Page Extraction (with heading detection)

    /// A single line of text extracted from the PDF with its formatting metadata
    struct TextLine {
        var text: String
        var isHeading: Bool
        var headingLevel: Int
        var fontSize: CGFloat
    }

    /// Extract Markdown from a text-based PDF page using font attribute analysis
    /// to detect headings, bold, and italic formatting.
    /// Joins consecutive body-text lines into paragraphs (PDFs have hard line
    /// breaks at each visual line, which we need to unwrap).
    private static func extractMarkdownFromTextPage(_ page: PDFPage) -> String {
        guard let attrString = page.attributedString else {
            return page.string ?? ""
        }

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

            let font = attrs[.font] as? NSFont
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

        // Fourth pass: join consecutive body-text lines into paragraphs.
        // PDF line breaks are visual, not semantic — a line that doesn't end
        // with sentence-ending punctuation and is followed by another body line
        // at the same font size is likely a continuation of the same paragraph.
        return joinLinesIntoParagraphs(lines)
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
            guard let font = value as? NSFont else { return }
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

    // MARK: - OCR

    /// Perform OCR on a PDF page using Vision framework.
    /// Renders the page to an image and runs text recognition.
    private static func performOCR(on page: PDFPage) -> String {
        // Render page to CGImage at 2x scale for better OCR accuracy
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        guard width > 0 && height > 0 else { return "" }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "" }

        // White background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale and draw the PDF page
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else { return "" }

        // Run Vision OCR
        var recognizedText = ""
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // Sort observations top-to-bottom, left-to-right for reading order
            let sorted = observations.sorted { a, b in
                // Vision uses bottom-left origin, so higher y = higher on page
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.midX < b.boundingBox.midX
            }

            var lines: [String] = []
            for observation in sorted {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)
            }
            recognizedText = lines.joined(separator: "\n")
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // If perform() throws, the callback never fires, so signal
            // the semaphore here to avoid a deadlock
            semaphore.signal()
            print("Warning: Vision OCR failed for page: \(error.localizedDescription)")
        }
        semaphore.wait()

        return recognizedText
    }

    // MARK: - Outline / Table of Contents

    /// Outline entry extracted from PDF bookmarks
    struct OutlineEntry {
        var title: String
        var level: Int     // 0-based depth in the outline tree
        var pageIndex: Int // zero-based page index
    }

    /// Extract the table of contents from a PDF's outline/bookmarks
    static func extractOutline(from document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }

        var entries: [OutlineEntry] = []
        traverseOutline(root, depth: -1, document: document, entries: &entries)
        return entries
    }

    /// Recursively traverse the PDF outline tree
    private static func traverseOutline(
        _ outline: PDFOutline,
        depth: Int,
        document: PDFDocument,
        entries: inout [OutlineEntry]
    ) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !label.isEmpty, let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                entries.append(OutlineEntry(
                    title: label,
                    level: max(0, depth + 1),
                    pageIndex: pageIndex
                ))
            }

            traverseOutline(child, depth: depth + 1, document: document, entries: &entries)
        }
    }

    // MARK: - Outline-Based Markdown Assembly

    /// Build Markdown with chapter markers derived from the PDF outline.
    /// Inserts heading markers at the appropriate page boundaries.
    private static func buildMarkdownWithOutline(
        pageTexts: [(pageIndex: Int, markdown: String, wasOCR: Bool)],
        outline: [OutlineEntry],
        document: PDFDocument
    ) -> String {
        // Build a map from page index → outline entries that start on that page
        var pageOutlineMap: [Int: [OutlineEntry]] = [:]
        for entry in outline {
            pageOutlineMap[entry.pageIndex, default: []].append(entry)
        }

        var markdown = ""

        for (pageIndex, pageMarkdown, _) in pageTexts {
            var cleanedPageMarkdown = pageMarkdown

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
