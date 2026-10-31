import AppKit
import PDFKit
import XCTest
@testable import TextMouth

/// Production-backed ports of the complete legacy PDF parser and edge-case suites.
final class LegacyPDFParserTests: XCTestCase {
    func testFormattedPDFFixtureExists() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture("test_formatted.pdf").path))
    }

    func testOutlinedPDFFixtureExists() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture("test_with_outline.pdf").path))
    }

    func testFormattedPDFFixtureHasReasonableSize() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture("test_formatted.pdf").path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 1_000)
    }

    func testPDFBookFormatDetection() {
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/test.PDF")), .pdf)
    }

    func testDoubleBodySizeIsH1() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(24, bodySize: 12), 1)
    }

    func testOneAndHalfBodySizeIsH2() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(18, bodySize: 12), 2)
    }

    func testOnePointTwoBodySizeIsH3() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(14.5, bodySize: 12), 3)
    }

    func testOnePointFifteenBodySizeIsH4() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(13.9, bodySize: 12), 4)
    }

    func testBarelyLargerFontIsH5() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(13, bodySize: 12), 5)
    }

    func testZeroBodySizeDefaultsToH2() {
        XCTAssertEqual(PDFTextParser.headingLevelFromFontSize(14, bodySize: 0), 2)
    }

    func testBodyFontDetectionPicksMostCommonSize() {
        XCTAssertEqual(PDFTextParser.mostCommonFontSize(in: [12: 5_000, 18: 200, 24: 50]), 12)
    }

    func testBodyFontDetectionHandlesSingleSize() {
        XCTAssertEqual(PDFTextParser.mostCommonFontSize(in: [11: 1_000]), 11)
    }

    func testBodyFontDetectionDefaultsWhenEmpty() {
        XCTAssertEqual(PDFTextParser.mostCommonFontSize(in: [:]), 12)
    }

    func testHeadingDeduplicationIsCaseInsensitive() {
        let result = PDFTextParser.removeHeadingDuplicate("Preface", from: "PREFACE\n\nSome body text about the topic.")
        XCTAssertFalse(result.contains("PREFACE"))
        XCTAssertTrue(result.contains("Some body text"))
    }

    func testHeadingDeduplicationRemovesShortSubstringMatch() {
        let result = PDFTextParser.removeHeadingDuplicate("Part I: Introduction", from: "Part I\n\nContent follows here.")
        XCTAssertFalse(result.contains("Part I"))
        XCTAssertTrue(result.contains("Content follows"))
    }

    func testHeadingDeduplicationPreservesLongContainingLine() {
        let text = "This is a long paragraph that mentions Chapter 1 Introduction in the middle of it."
        XCTAssertEqual(PDFTextParser.removeHeadingDuplicate("Chapter 1 Introduction", from: text), text)
    }

    func testHeadingDeduplicationPreservesUnrelatedText() {
        let text = "Some completely unrelated text.\n\nAnother paragraph."
        XCTAssertEqual(PDFTextParser.removeHeadingDuplicate("Chapter 1", from: text), text)
    }

    func testLineJoiningMergesContinuationLines() {
        let result = join([
            line("This is the beginning of a long paragraph that"),
            line("continues on the next line with more content."),
        ])
        XCTAssertTrue(result.contains("paragraph that continues"))
    }

    func testLineJoiningBreaksAtHeadings() {
        let result = join([
            line("End of previous section."),
            line("New Section", headingLevel: 2, fontSize: 18),
            line("Beginning of new section."),
        ])
        XCTAssertTrue(result.contains("## New Section"))
        XCTAssertFalse(result.contains("section.New"))
    }

    func testLineJoiningBreaksAtFontSizeChanges() {
        let result = join([line("Normal text here."), line("Different sized text.", fontSize: 16)])
        XCTAssertFalse(result.contains("here. Different"))
    }

    func testLineJoiningBreaksAtBulletedListItems() {
        let result = join([line("Introduction:"), line("- First item"), line("- Second item")])
        XCTAssertTrue(result.contains("- First item"))
        XCTAssertTrue(result.contains("- Second item"))
    }

    func testLineJoiningBreaksAtNumberedListItems() {
        let result = join([line("Steps:"), line("1. Do this first"), line("2. Then do that")])
        XCTAssertTrue(result.contains("1. Do this first"))
        XCTAssertFalse(result.contains("Steps: 1."))
    }

    func testLineJoiningBreaksAtLikelyNewParagraph() {
        let result = join([line("End of paragraph."), line("New paragraph start.")])
        XCTAssertFalse(result.contains("paragraph. New paragraph"))
    }

    func testPDFMetadataReturnsTitleOnly() throws {
        let url = try makePDF(title: "My Book", author: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = PDFTextParser.readMetadata(from: url)
        XCTAssertEqual(metadata?.title, "My Book")
        XCTAssertEqual(metadata?.author, "")
    }

    func testPDFMetadataReturnsAuthorOnly() throws {
        let url = try makePDF(title: "", author: "Author Name")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = PDFTextParser.readMetadata(from: url)
        XCTAssertEqual(metadata?.title, "")
        XCTAssertEqual(metadata?.author, "Author Name")
    }

    func testPDFMetadataReturnsNilWhenBothFieldsEmpty() throws {
        let url = try makePDF(title: "", author: "")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(PDFTextParser.readMetadata(from: url))
    }

    // MARK: - Fixture Markdown

    /// The formatted fixture reads exactly as it always has: headings from
    /// font sizes, inline emphasis, and lines joined into paragraphs.
    func testFormattedFixtureReadsAsItAlwaysHas() throws {
        XCTAssertEqual(try PDFTextParser.extractMarkdown(from: fixture("test_formatted.pdf")), Self.formattedMarkdown)
    }

    /// The outlined fixture reads exactly as it always has: headings from
    /// its outline, with the page text read without heading detection.
    func testOutlinedFixtureReadsAsItAlwaysHas() throws {
        XCTAssertEqual(try PDFTextParser.extractMarkdown(from: fixture("test_with_outline.pdf")), Self.outlinedMarkdown)
    }

    // MARK: - Outline Order and Depth

    /// The outline's entries come in document order with their depths as
    /// levels, however they nest: each entry before those nested in it,
    /// which come before its next sibling. An entry without a label or a
    /// destination is left out, and the entries nested in it are still read.
    func testOutlineEntriesKeepTheirOrderAndLevelsHoweverTheyNest() {
        let document = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        let root = PDFOutline()
        let partOne = Self.outlineEntry("Part One", on: firstPage, under: root)
        let chapterOne = Self.outlineEntry("Chapter One", on: firstPage, under: partOne)
        Self.outlineEntry("Section 1.1", on: secondPage, under: chapterOne)
        let unlabelled = Self.outlineEntry("   ", on: secondPage, under: partOne)
        Self.outlineEntry("Section 2.1", on: secondPage, under: unlabelled)
        let unplaced = Self.outlineEntry("No destination", on: nil, under: root)
        Self.outlineEntry("Appendix", on: secondPage, under: unplaced)
        Self.outlineEntry("Part Two", on: secondPage, under: root)
        document.outlineRoot = root

        XCTAssertEqual(Self.describe(PDFTextParser.extractOutline(from: document)), [
            "0 Part One p0", "1 Chapter One p0", "2 Section 1.1 p1", "2 Section 2.1 p1", "1 Appendix p1", "0 Part Two p1"
        ])
    }

    /// An outline nesting 5,000 entries, each the only child of the one
    /// before, is read on a worker thread's 512 KiB stack, where an import
    /// reads it, giving every entry in order at its depth. The walk once
    /// called itself for every level, which overflowed that stack and ended
    /// TextMouth. Only the test holds the document, so it is released on the
    /// test's own thread, never on the small stack.
    func testOutlineNestedThousandsDeepIsReadOnAWorkerStack() {
        let depth = 5_000
        let document = Self.documentWithNestedOutline(depth: depth)
        let lent = LentPDFDocument(document)

        let entries = onWorkerSizedStack {
            autoreleasepool {
                lent.document.map { LegacyPDFParserTests.describe(PDFTextParser.extractOutline(from: $0)) } ?? []
            }
        }

        XCTAssertEqual(entries?.count, depth)
        XCTAssertTrue(
            entries == (0..<depth).map { "\($0) Level \($0) p0" },
            "the entries are not Level 0 to Level \(depth - 1), in order, each at its depth"
        )
        withExtendedLifetime(document) {}
    }

    /// A PDF file whose outline nests 5,000 entries is read on a worker
    /// thread's 512 KiB stack, where an import reads it, with every entry a
    /// heading, the deepest at the deepest heading level. PDFKit releases an
    /// outline one nested call per level once its entries have been read,
    /// so until the extraction took the outline apart, releasing the
    /// document overflowed that stack and ended TextMouth.
    func testAPDFWithAnOutlineNestedThousandsDeepIsReadOnAWorkerStack() throws {
        let depth = 5_000
        let source = try XCTUnwrap(PDFDocument(url: fixture("test_formatted.pdf")))
        let firstPage = try XCTUnwrap(source.page(at: 0))
        source.outlineRoot = Self.nestedOutline(depth: depth, on: firstPage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(source.write(to: url))

        let markdown = onWorkerSizedStack { (try? PDFTextParser.extract(from: url, recognizer: nil))?.markdown ?? "" }

        XCTAssertEqual(markdown?.contains("# Level 0\n"), true)
        XCTAssertEqual(markdown?.contains("###### Level \(depth - 1)\n"), true)
    }

    /// Each outline entry as "level title p<page index>".
    private static func describe(_ entries: [PDFTextParser.OutlineEntry]) -> [String] {
        entries.map { "\($0.level) \($0.title) p\($0.pageIndex)" }
    }

    /// A new outline entry labelled `label`, naming the top of `page`, or
    /// nothing when it is nil, added after the other children of `parent`.
    @discardableResult
    private static func outlineEntry(_ label: String, on page: PDFPage?, under parent: PDFOutline) -> PDFOutline {
        let entry = PDFOutline()
        entry.label = label
        if let page {
            entry.destination = PDFDestination(page: page, at: .zero)
        }
        parent.insertChild(entry, at: parent.numberOfChildren)
        return entry
    }

    /// An outline root holding `depth` entries, each the only child of the
    /// one before, labelled "Level 0" on down, each naming the top of `page`.
    private static func nestedOutline(depth: Int, on page: PDFPage) -> PDFOutline {
        let root = PDFOutline()
        var parent = root
        for level in 0..<depth {
            parent = outlineEntry("Level \(level)", on: page, under: parent)
        }
        return root
    }

    /// A one-page document whose outline nests `depth` entries
    /// (`nestedOutline(depth:on:)`).
    private static func documentWithNestedOutline(depth: Int) -> PDFDocument {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        document.outlineRoot = nestedOutline(depth: depth, on: page)
        return document
    }

    /// The Markdown `test_formatted.pdf` has always been read as.
    private static let formattedMarkdown = """
        # The Seasonal Almanac


        *by Dorothy Whitfield*

        # Chapter 1: Spring


        Spring arrives not as a single event but as a sequence of small awakenings. The soil loosens before the first shoots appear. Birdsong returns before the leaves do. The careful observer notices these precursors and prepares accordingly. The **equinox** marks the astronomical beginning, but the *practical* start of spring varies by latitude, altitude, and local microclimate. A gardener in the lowlands may be planting weeks before one in the hills.

        ## Early Planting


        Root vegetables tolerate cool soil better than fruiting crops. Begin with radishes, carrots, and turnips. These can be sown directly as soon as the ground can be worked.

        ### Soil Preparation


        Turn the soil to a depth of eight inches. Incorporate compost at a ratio of one part compost to three parts native soil. Test pH if possible — most vegetables prefer 6.0 to 7.0.

        # Chapter 2: Summer


        The long days of summer demand attention to watering schedules above all else. Most garden plants require approximately one inch of water per week, delivered consistently rather than in sporadic heavy doses.

        ## Heat Management


        Mulch serves double duty in summer: it retains moisture and suppresses weeds. Apply two to three inches of organic mulch around established plants, keeping it away from stems to prevent rot.

        # Chapter 3: Autumn


        The harvest season rewards patience and planning. Crops planted in spring reach maturity, and the **second planting window** opens for cool-weather crops that will carry through early winter.

        ## Preserving the Harvest


        Canning, drying, and root-cellaring each suit different produce. Tomatoes and fruits preserve well in jars. Herbs dry readily in bundled bunches hung in a warm, dry space with good airflow.
        """

    /// The Markdown `test_with_outline.pdf` has always been read as.
    private static let outlinedMarkdown = """
        # The Seasonal Almanac


        # Chapter 1: Spring


        ## Early Planting

        **The Seasonal Almanac**

        *by Dorothy Whitfield*

        **Chapter 1: Spring**

        Spring arrives not as a single event but as a sequence of small awakenings.

        **Early Planting**

        Root vegetables tolerate cool soil better than fruiting crops.


        # Chapter 2: Summer


        ## Heat Management

        **Chapter 2: Summer**

        The long days of summer demand attention to watering schedules.

        **Heat Management**

        Mulch serves double duty in summer: it retains moisture and suppresses weeds.


        # Chapter 3: Autumn

        **Chapter 3: Autumn**

        The harvest season rewards patience and planning.
        """

    private func line(_ text: String, headingLevel: Int? = nil, fontSize: CGFloat = 12) -> PDFTextParser.TextLine {
        PDFTextParser.TextLine(
            text: text,
            isHeading: headingLevel != nil,
            headingLevel: headingLevel ?? 0,
            fontSize: fontSize
        )
    }

    private func join(_ lines: [PDFTextParser.TextLine]) -> String {
        PDFTextParser.joinLinesIntoParagraphs(lines)
    }

    /// The URL of an optional `TestData` fixture, skipping the test when the file is missing.
    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: testFilePath(name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name)")
        }
        return url
    }

    private func makePDF(title: String, author: String) throws -> URL {
        let document = try XCTUnwrap(PDFDocument(url: fixture("test_formatted.pdf")))
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title,
            PDFDocumentAttribute.authorAttribute: author,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }
}

/// A PDF document a test lends to a worker thread without handing it a
/// reference: the test keeps the only one, so the document is never
/// released on the worker's small stack, however the threads' endings fall.
/// `@unchecked Sendable`: the test's thread waits while the worker thread
/// reads the document, so only one thread uses it at a time.
private final class LentPDFDocument: @unchecked Sendable {
    /// The document, while the test holds it.
    private(set) weak var document: PDFDocument?

    /// Lends `document`, which the caller keeps.
    init(_ document: PDFDocument) {
        self.document = document
    }
}
