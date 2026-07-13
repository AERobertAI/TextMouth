import XCTest
@testable import TextMouth

/// Regression coverage for the formats advertised by the production app.
final class BookFormatTests: XCTestCase {
    /// Hosted tests must never initialize services against the user's real data.
    func testProductionTestsUseIsolatedDataDirectory() {
        XCTAssertTrue(TextMouthPaths.root.path.contains("TextMouthTests-"))
        XCTAssertNotEqual(TextMouthPaths.root.standardizedFileURL, TextMouthPaths.defaultRoot.standardizedFileURL)
    }

    /// Legacy binary Word documents are not Office Open XML archives and cannot
    /// be parsed by DOCXParser, so they must not be detected as DOCX input.
    func testLegacyDocIsNotAdvertisedAsDOCX() {
        let legacyURL = URL(fileURLWithPath: "/tmp/legacy.doc")

        XCTAssertNil(BookFormat.detect(from: legacyURL))
        XCTAssertFalse(BookFormat.docx.fileExtensions.contains("doc"))
        XCTAssertFalse(
            FileImportService.supportedTypes.contains {
                $0.identifier == "com.microsoft.word.doc"
            }
        )
    }

    /// Removing legacy DOC support must not affect supported DOCX documents.
    func testDOCXRemainsSupported() {
        let docxURL = URL(fileURLWithPath: "/tmp/document.docx")

        XCTAssertEqual(BookFormat.detect(from: docxURL), .docx)
        XCTAssertTrue(BookFormat.docx.fileExtensions.contains("docx"))
    }
}
