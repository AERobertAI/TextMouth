import XCTest

/// A braille book on the iPhone (DR34), driven as a person drives the app: a
/// BRF sent to TextMouth, as another app sends one, is imported, translated
/// to print in the app itself, and opened in the reader, whose Book content
/// holds the print the Mac reads from the same file. The book is the Grade 2
/// sample of the Mac's tests (TestData/format-samples/brf/grade2-short.brf,
/// three sentences in contracted Unified English Braille, read with the
/// default table, en-ueb-g2.ctb). Nothing is pressed or typed, so the test
/// makes no sound.
final class BrailleUITests: TextMouthUITestCase {
    /// The sample's three sentences, as its print file holds them and the
    /// Mac's import reads them (BrailleImportTests).
    static let sentences = ["The boy and girl can go with you.", "The church shop is open.", "We like singing."]

    /// The BRF's path in this test bundle, where project.yml copies it.
    private func brfPath() throws -> String {
        let bundle = Bundle(for: BrailleUITests.self)
        return try XCTUnwrap(bundle.url(forResource: "grade2-short", withExtension: "brf"), "grade2-short.brf is not in the bundle").path
    }

    /// The BRF opens in the reader on its print: Book content holds each of
    /// its three sentences, and no alert stands in its way.
    func testABRFSentToTheAppOpensInTheReaderOnItsPrint() throws {
        let app = try launchIntoTheReader(sendingBookAt: brfPath())
        XCTAssertFalse(app.alerts.firstMatch.exists, "An alert came up:\n\(app.alerts.firstMatch.debugDescription)")
        let elements = try elementsInOrder(of: app)
        let text = try XCTUnwrap(elements.first { $0.label == "Book content" }?.value, "Book content holds no text")
        for sentence in Self.sentences {
            XCTAssertTrue(text.contains(sentence), "Book content lacks \"\(sentence)\": \(text.prefix(300))")
        }
        keepScreenshot(of: app, named: "Braille book")
    }
}
