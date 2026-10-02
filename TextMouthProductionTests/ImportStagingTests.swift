import XCTest
@testable import TextMouth

/// The pieces every import is built from (TODO S02): the failure that names
/// the file and the step, and the run that attributes an error to the step
/// under way. Tests work in a temporary folder of their own, never the
/// library.
final class ImportStagingTests: XCTestCase {
    /// A folder of this test's own, removed with everything in it afterwards.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Some tests take write permission away; give it back so the folder
        // can be removed whatever a test left behind.
        if let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let item as URL in items {
                chmod(item.path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The Failure

    /// The alert names the file, then the step, then what stopped it; the
    /// reason, which a ZIP batch lists after the file's name, leaves the
    /// name out.
    func testFailureNamesTheFileThenTheStepThenTheCause() {
        let failure = ImportFailure(
            fileName: "Bicycle Repair.docx",
            step: .readingText,
            underlying: DOCXParserError.invalidArchive
        )

        XCTAssertEqual(
            failure.reason,
            "Reading its text failed: The DOCX file could not be opened as a ZIP archive."
        )
        XCTAssertEqual(
            failure.localizedDescription,
            "Could not import “Bicycle Repair.docx”. "
                + "Reading its text failed: The DOCX file could not be opened as a ZIP archive."
        )
        XCTAssertEqual(ImportFailure.reason(for: failure), failure.reason)
        XCTAssertEqual(
            ImportFailure.reason(for: AudioParseError.noAudioFiles),
            AudioParseError.noAudioFiles.localizedDescription
        )
    }

    /// Every step has its own wording, so no two failures read alike.
    func testEveryStepIsNamedDistinctly() {
        let steps: [ImportStep] = [
            .checkingFormat, .readingSource, .preparingPackage, .copying, .extractingArchive,
            .convertingAudio, .checkingPackage, .readingText, .readingAudio, .savingRecord,
            .publishing, .reinstating
        ]
        XCTAssertEqual(Set(steps.map(\.activity)).count, steps.count)
        XCTAssertEqual(ImportStep.savingRecord.activity, "Saving its bookInfo.json file")
    }

    /// The log entry stays on one line even when the name or the cause
    /// breaks across lines.
    func testLogLineStaysOnOneLine() {
        let failure = ImportFailure(
            fileName: "Two\nLines.txt",
            step: .copying,
            underlying: FileImportError.importFailed("first\nsecond")
        )

        XCTAssertEqual(
            failure.logLine,
            "IMPORT_FAILED: Two Lines.txt: Copying it into the library failed: Import failed: first second"
        )
    }

    // MARK: - The Run

    /// A failure is attributed to the step under way when it happened, and
    /// recorded in the debug log exactly once.
    func testRunAttributesAFailureToTheStepUnderWayAndLogsItOnce() throws {
        let fileName = "Step Attribution \(UUID().uuidString).txt"

        XCTAssertThrowsError(try ImportRun.perform(importing: fileName) { run in
            try run.begin(.copying)
            try run.begin(.savingRecord)
            throw CocoaError(.fileWriteOutOfSpace)
        }) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.fileName, fileName)
            XCTAssertEqual(failure?.step, .savingRecord)
            XCTAssertEqual((failure?.underlying as? CocoaError)?.code, .fileWriteOutOfSpace)
        }

        let lines = debugLogLines(containing: "IMPORT_FAILED: \(fileName): ")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("Saving its bookInfo.json file failed: ") == true, "\(lines)")
    }

    /// A failure of an import nested inside another (one file of a ZIP)
    /// keeps its own file and step, and is logged once, under its own name.
    func testNestedFailurePassesThroughUnchanged() throws {
        let outer = "Outer \(UUID().uuidString).zip"
        let inner = "Inner \(UUID().uuidString).epub"

        XCTAssertThrowsError(try ImportRun.perform(importing: outer) { run in
            try run.begin(.extractingArchive)
            return try ImportRun.perform(importing: inner) { innerRun in
                try innerRun.begin(.readingText)
                throw FileImportError.importFailed("unreadable")
            }
        }) { error in
            XCTAssertEqual((error as? ImportFailure)?.fileName, inner)
            XCTAssertEqual((error as? ImportFailure)?.step, .readingText)
        }

        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(inner): ").count, 1)
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(outer): ").count, 0)
    }

    /// The observer hears only the steps that work on the package, with the
    /// package, before each starts; what it throws fails that step.
    func testObserverHearsStepsOnThePackageAndCanFailThem() throws {
        let package = folder.appendingPathComponent("Observed.tmb", isDirectory: true)
        var heard: [ImportStep] = []

        XCTAssertThrowsError(try ImportRun.perform(
            importing: "Observed \(UUID().uuidString).txt",
            observer: { step, observedPackage in
                XCTAssertEqual(observedPackage, package)
                heard.append(step)
                if step == .readingText { throw CocoaError(.fileWriteNoPermission) }
            },
            { run in
                try run.begin(.checkingFormat)
                try run.begin(.copying, in: package)
                try run.begin(.readingText, in: package)
                XCTFail("The observer's error must stop the import")
            }
        )) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .readingText)
        }
        XCTAssertEqual(heard, [.copying, .readingText])
    }
}
