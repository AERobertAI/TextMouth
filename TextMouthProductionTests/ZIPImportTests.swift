import XCTest
@testable import TextMouth

/// Regression coverage for partial ZIP import reporting.
final class ZIPImportTests: XCTestCase {
    func testSupportedFileLoopReturnsBooksAndPerFileFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.txt")
        let bad = directory.appendingPathComponent("bad.txt")
        try Data("good".utf8).write(to: good)
        try Data("bad".utf8).write(to: bad)

        let result = FileImportService.importSupportedFiles(
            [good, bad],
            toFolder: "",
            importer: { url, _ in
                if url.lastPathComponent == "bad.txt" {
                    throw FileImportError.importFailed("simulated parse failure")
                }
                return Book(
                    title: "Imported",
                    format: .txt,
                    filePath: url.path,
                    md5Hash: try FileImportService.md5Hash(of: url)
                )
            }
        )

        XCTAssertEqual(result.books.map(\.title), ["Imported"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].fileName, "bad.txt")
        XCTAssertTrue(result.failures[0].message.contains("simulated parse failure"))
    }

    func testFailureSummaryNamesEveryFailedFile() throws {
        let result = ZipImportResult(
            books: [],
            failures: [
                ZipImportFailure(fileName: "first.epub", message: "invalid archive"),
                ZipImportFailure(fileName: "second.pdf", message: "unreadable")
            ]
        )

        let summary = try XCTUnwrap(result.failureSummary)
        XCTAssertTrue(summary.contains("2 files failed"))
        XCTAssertTrue(summary.contains("first.epub: invalid archive"))
        XCTAssertTrue(summary.contains("second.pdf: unreadable"))
    }

    func testDuplicateFilesAreSkippedWithoutBeingReportedAsFailures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("duplicate".utf8).write(to: file)
        let hash = try FileImportService.md5Hash(of: file)

        let result = FileImportService.importSupportedFiles(
            [file],
            toFolder: "",
            existingHashes: [hash],
            importer: { _, _ in
                XCTFail("Duplicate should not reach importer")
                throw FileImportError.importFailed("unexpected")
            }
        )

        XCTAssertTrue(result.books.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }
}
