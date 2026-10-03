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

    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestData/\(name)")
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
