import XCTest
@testable import TextMouth

/// The pieces every import is built from (TODO S02): the failure that names
/// the file and the step, the run that attributes an error to the step
/// under way, and the hidden staged package that only a rename publishes.
/// Staging tests work in a temporary folder of their own, never the library.
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

    // MARK: - Staging and Publishing

    /// A staged package is hidden, sits beside its destination, and becomes
    /// the destination, with everything in it, only when published.
    func testStagedPackageIsHiddenUntilARenamePublishesIt() throws {
        let destination = folder.appendingPathComponent("Field Guide.tmb", isDirectory: true)

        let staging = try ImportStaging.makeEmpty(publishingTo: destination)
        try Data("pages".utf8).write(to: staging.directory.appendingPathComponent("book.txt"))

        XCTAssertEqual(staging.directory.deletingLastPathComponent().path, folder.path)
        XCTAssertTrue(staging.name.hasPrefix("."))
        XCTAssertTrue(ImportStaging.isStagedPackageName(staging.name))
        XCTAssertFalse(exists(destination))

        try staging.publish()
        staging.discard()

        XCTAssertTrue(staging.isPublished)
        XCTAssertFalse(exists(staging.directory))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("book.txt"), encoding: .utf8), "pages")
        XCTAssertEqual(try entries(), ["Field Guide.tmb"])
    }

    /// Discarding removes the staged package and everything in it, even
    /// after the package and a folder inside it lost write permission.
    func testDiscardRemovesAPackageThatLostWritePermission() throws {
        let staging = try ImportStaging.makeEmpty(publishingTo: folder.appendingPathComponent("Locked.tmb"))
        let audio = staging.directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("track".utf8).write(to: audio.appendingPathComponent("01.wav"))
        try Data("record".utf8).write(to: staging.directory.appendingPathComponent("bookInfo.json"))
        XCTAssertEqual(chmod(audio.path, 0o555), 0)
        XCTAssertEqual(chmod(staging.directory.path, 0o555), 0)

        staging.discard()

        XCTAssertFalse(exists(staging.directory))
        XCTAssertEqual(try entries(), [])
    }

    /// Publishing never replaces what is already at the destination: it
    /// throws, the existing package is untouched, and discarding then
    /// removes only the staged package.
    func testPublishingNeverReplacesAnExistingPackage() throws {
        let destination = folder.appendingPathComponent("Taken.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: destination.appendingPathComponent("book.txt"))
        let staging = try ImportStaging.makeEmpty(publishingTo: destination)
        try Data("second".utf8).write(to: staging.directory.appendingPathComponent("book.txt"))

        XCTAssertThrowsError(try staging.publish())
        staging.discard()

        XCTAssertFalse(staging.isPublished)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("book.txt"), encoding: .utf8), "first")
        XCTAssertEqual(try entries(), ["Taken.tmb"])
    }

    /// A staged copy holds the whole source package and leaves the source
    /// as it was; a copy that fails leaves nothing behind.
    func testCopyStagesTheWholePackageAndAFailedCopyLeavesNothing() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagingSource-\(UUID().uuidString).tmb", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("chapter".utf8).write(to: source.appendingPathComponent("book.txt"))

        let staging = try ImportStaging.copy(of: source, publishingTo: folder.appendingPathComponent("Copy.tmb"))
        defer { staging.discard() }

        XCTAssertEqual(try String(contentsOf: staging.directory.appendingPathComponent("book.txt"), encoding: .utf8), "chapter")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("book.txt"), encoding: .utf8), "chapter")

        let missing = source.deletingLastPathComponent().appendingPathComponent("Missing-\(UUID().uuidString).tmb")
        XCTAssertThrowsError(try ImportStaging.copy(of: missing, publishingTo: folder.appendingPathComponent("Other.tmb")))
        XCTAssertEqual(try entries(), [staging.name])
    }

    /// A staged book's paths move with the package: its package name
    /// becomes the destination's, and a path inside the staged package
    /// points to the same place inside the destination.
    func testPublishedBookPointsIntoTheDestination() throws {
        let destination = folder.appendingPathComponent("Atlas.tmb", isDirectory: true)
        let staging = try ImportStaging.makeEmpty(publishingTo: destination)
        defer { staging.discard() }
        let staged = Book(
            title: "Atlas",
            format: .audio,
            filePath: staging.directory.appendingPathComponent("audio").path,
            md5Hash: "atlas",
            tmbDirectoryName: staging.name
        )

        let published = staging.published(staged)

        XCTAssertEqual(published.tmbDirectoryName, "Atlas.tmb")
        XCTAssertEqual(published.filePath, destination.appendingPathComponent("audio").path)
        XCTAssertEqual(published.id, staged.id)
    }

    // MARK: - Abandoned Packages

    /// Only names an import gives its staged packages are recognized.
    func testStagedPackageNamesAreRecognizedExactly() {
        XCTAssertTrue(ImportStaging.isStagedPackageName(".import-\(UUID().uuidString).tmb"))
        XCTAssertFalse(ImportStaging.isStagedPackageName(".import-staging.tmb"))
        XCTAssertFalse(ImportStaging.isStagedPackageName("import-\(UUID().uuidString).tmb"))
        XCTAssertFalse(ImportStaging.isStagedPackageName(".import-\(UUID().uuidString)"))
        XCTAssertFalse(ImportStaging.isStagedPackageName(".textmouth-split-\(UUID().uuidString)"))
    }

    /// Staging a new package removes the packages interrupted imports left
    /// in its folder, and only those: a package another import is still
    /// building, books, and other hidden directories stay.
    func testStagingRemovesAbandonedPackagesAndNothingElse() throws {
        let abandoned = try makeDirectory(".import-\(UUID().uuidString).tmb", holding: "bookInfo.json")
        let lookalike = try makeDirectory(".import-staging.tmb", holding: "bookInfo.json")
        let book = try makeDirectory("Kept Book.tmb", holding: "book.txt")
        let split = try makeDirectory(".textmouth-split-\(UUID().uuidString)", holding: "book.txt")
        let building = try ImportStaging.makeEmpty(publishingTo: folder.appendingPathComponent("First.tmb"))
        defer { building.discard() }
        XCTAssertFalse(exists(abandoned), "staging removes what an interrupted import left")

        let second = try ImportStaging.makeEmpty(publishingTo: folder.appendingPathComponent("Second.tmb"))
        defer { second.discard() }
        XCTAssertEqual(ImportStaging.removeAbandoned(in: folder), 0)

        XCTAssertTrue(exists(building.directory), "a package still being built is never taken")
        XCTAssertTrue(exists(second.directory))
        for kept in [lookalike, book, split] {
            XCTAssertTrue(exists(kept), kept.lastPathComponent)
        }
        let removals = debugLogLines(containing: "IMPORT_STAGING_REMOVED: ")
            .filter { $0.contains(abandoned.lastPathComponent) }
        XCTAssertEqual(removals.count, 1, "\(removals)")
    }

    // MARK: - Fixtures

    /// Whether anything exists at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The names in this test's folder.
    private func entries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Creates the directory `name` in this test's folder holding one file
    /// named `fileName`.
    private func makeDirectory(_ name: String, holding fileName: String) throws -> URL {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent(fileName))
        return directory
    }
}
