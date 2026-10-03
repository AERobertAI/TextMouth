import CoreGraphics
import Foundation

/// Merges the lines OCR recognized on a page into the page's embedded text
/// (TODO T09).
///
/// Embedded text is kept as it is. An OCR line joins it only when it adds
/// something: a line that repeats embedded text is dropped, whether it
/// matches an embedded line once both are normalized (case, accents,
/// spacing, and punctuation ignored), repeats a phrase of the page's
/// embedded text that OCR broke into lines differently, or sits where
/// embedded text already sits (OCR reading text drawn over a picture,
/// however it misreads it). A line with no letters or digits has nothing to
/// read and is dropped too.
///
/// The lines that remain go where they appear on the shown page, between
/// whole paragraphs of embedded text: each goes before the first paragraph
/// that begins below it, so a picture's words are never spliced into the
/// middle of a paragraph.
enum PDFPageTextMerger {
    /// An OCR line counts as embedded text already when at least this
    /// share of its box lies under embedded text lines.
    static let duplicateCoverage: CGFloat = 0.5
    /// An OCR line whose normalized text is at least this long is a repeat
    /// when it appears anywhere in the page's normalized embedded text.
    /// Shorter lines ("EXIT", "2") must match a whole embedded line, so a
    /// word that also occurs in a sentence is not mistaken for a repeat.
    static let minimumPhraseLength = 16

    /// A page's merged Markdown and how many OCR lines it gained.
    struct Result: Equatable {
        /// The page's Markdown: its embedded text, with the OCR lines that
        /// add something placed among its paragraphs.
        var markdown: String
        /// How many OCR lines were added. Zero when OCR added nothing, so
        /// the page's text is its embedded text alone.
        var addedLineCount: Int
    }

    /// The page's Markdown from its embedded `lines`, with the lines in
    /// `recognized` that add something placed where they appear.
    /// - Parameters:
    ///   - lines: the page's embedded text lines, as the paragraph joiner
    ///     reads them.
    ///   - lineBounds: where each of `lines` is, in default user space, nil
    ///     where unknown. When it does not have one entry per line, or any
    ///     paragraph's position is unknown, the OCR lines that add
    ///     something follow all the embedded text.
    ///   - recognized: OCR lines in reading order, region by region.
    ///   - rotation: the page's `/Rotate`, which decides what is "below".
    static func merge(
        lines: [PDFTextParser.TextLine],
        lineBounds: [CGRect?],
        recognized: [PDFRecognizedLine],
        rotation: Int
    ) -> Result {
        let blocks = PDFTextParser.paragraphBlocks(lines)
        let bounds = lineBounds.count == lines.count ? lineBounds : []
        let added = linesAddingText(recognized, to: lines, at: bounds.compactMap { $0 })
        guard !added.isEmpty else {
            return Result(markdown: PDFTextParser.markdown(of: blocks), addedLineCount: 0)
        }

        // Where each paragraph begins on the shown page, or nil when any
        // paragraph's position is unknown.
        let starts: [CGRect]? = {
            guard !bounds.isEmpty else { return nil }
            let shown = blocks.map { block in
                bounds[block.firstLine].map { PDFPageGeometry.upright($0, rotation: rotation) }
            }
            return shown.contains { $0 == nil } ? nil : shown.compactMap { $0 }
        }()

        // Slot k holds the OCR lines read just before paragraph k; the
        // last slot holds those after every paragraph.
        var slots = [[String]](repeating: [], count: blocks.count + 1)
        for line in added {
            let slot = starts.map { slotIndex(for: line, among: $0, rotation: rotation) } ?? blocks.count
            slots[slot].append(line.text)
        }

        var chunks: [String] = []
        for (index, block) in blocks.enumerated() {
            if !slots[index].isEmpty { chunks.append(recognizedChunk(slots[index])) }
            chunks.append(block.markdown)
        }
        if let trailing = slots.last, !trailing.isEmpty {
            chunks.append(recognizedChunk(trailing))
        }
        return Result(
            markdown: chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            addedLineCount: added.count
        )
    }

    /// The lines of `recognized` that add text the page's embedded `lines`
    /// (found at `embeddedBounds`) do not already hold, in their order.
    static func linesAddingText(
        _ recognized: [PDFRecognizedLine],
        to lines: [PDFTextParser.TextLine],
        at embeddedBounds: [CGRect]
    ) -> [PDFRecognizedLine] {
        let lineKeys = lines.map { normalized($0.text) }
        let knownLines = Set(lineKeys)
        let pageKey = lineKeys.joined()
        return recognized.filter { line in
            let key = normalized(line.text)
            if key.isEmpty || knownLines.contains(key) { return false }
            if key.count >= minimumPhraseLength && pageKey.contains(key) { return false }
            return PDFPageGeometry.coveredFraction(of: line.bounds, by: embeddedBounds) < duplicateCoverage
        }
    }

    /// `text` reduced to what OCR and embedded text can be compared on:
    /// letters and digits only, with case, accents, and character widths
    /// folded. Markdown emphasis and spacing disappear with the rest of
    /// the punctuation.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    // MARK: - Placement

    /// The index of the first paragraph `line` comes before on the shown
    /// page, or `starts.count` when it comes after them all. A line comes
    /// before a paragraph whose first line begins lower down, or at the
    /// same height (within half the OCR line's height) but further right.
    private static func slotIndex(for line: PDFRecognizedLine, among starts: [CGRect], rotation: Int) -> Int {
        let shown = PDFPageGeometry.upright(line.bounds, rotation: rotation)
        let tolerance = max(1, shown.height / 2)
        return starts.firstIndex { start in
            shown.maxY > start.maxY + tolerance
                || (abs(shown.maxY - start.maxY) <= tolerance && shown.minX < start.minX)
        } ?? starts.count
    }

    /// OCR lines as a paragraph of their own, one line each, written the
    /// way the paragraph joiner writes its paragraphs and the way a
    /// scanned page's lines have always been written.
    private static func recognizedChunk(_ texts: [String]) -> String {
        "\n\(texts.joined(separator: "\n"))\n"
    }
}
