import XCTest
@testable import TextMouth

/// The import fuzz sweep: a damaged copy of every TestData document, in a
/// dozen seeded ways (`ImportFuzzMutator`), imported as the library imports.
/// A book that crashes or hangs the import is the worst failure for a blind
/// user, who cannot see what went wrong, so the sweep asks, for every
/// copy, whether the import
///
/// - finished within the watchdog's time (a hang is a violation),
/// - either refused the file cleanly or imported a book that loads,
/// - published nothing and left no staged or extracted leftover when it
///   refused, and
/// - left the damaged file as it found it.
///
/// A crash of the test host is the sweep's finding too: the log's last
/// `FUZZ CASE` line names the case. Run it with `Scripts/test/import-fuzz.sh`,
/// which sets the variables below; without `TEXTMOUTH_IMPORT_FUZZ=1` the test
/// skips, so the ordinary suite never runs it.
///
/// Variables: `TEXTMOUTH_IMPORT_FUZZ_SEED` (default 20261016),
/// `TEXTMOUTH_IMPORT_FUZZ_DOCS` (comma-separated TestData names; default
/// every book of `TextPipelineFixtures.testDataBookNames` under 300 KB),
/// `TEXTMOUTH_IMPORT_FUZZ_PDF=1` (also the two small PDFs, whose import can
/// use Vision OCR), `TEXTMOUTH_IMPORT_FUZZ_SECONDS` (the watchdog for one
/// import, default 60), `TEXTMOUTH_IMPORT_FUZZ_REPORT` (the report's path).
/// Ogg and other audio are never imported by this sweep: Apple's decoder
/// can hang the host.
final class ImportFuzzTests: XCTestCase {
    // MARK: - What Is Known

    /// Cases that violate an invariant today, by case id, with a one-line
    /// note on the finding. A listed case does not fail the sweep, and one
    /// that stops violating fails it, so the entry must go.
    static let knownIssues: [String: String] = [
        // Found by the first sweep (seed 20261016): a Markdown file of no
        // bytes is imported, where an empty EPUB or DOCX is refused.
        "sample.md#empty#seed=20261016":
            "an empty Markdown file imports as an empty book whose report says nothing is missing",
    ]

    /// Cases that must never be run (they crash or hang the host), by case
    /// id, with a note on the finding.
    static let skippedCases: [String: String] = [:]

    // MARK: - Settings

    /// The default seed.
    private static let defaultSeed: UInt64 = 20_261_016
    /// The documents the default sweep leaves out above this size, in bytes.
    private static let defaultSizeLimit = 300_000
    /// The PDFs `TEXTMOUTH_IMPORT_FUZZ_PDF=1` adds.
    private static let pdfNames = ["test_formatted.pdf", "test_with_outline.pdf"]

    /// What one run of the sweep was asked to do.
    private struct Settings {
        let seed: UInt64
        let documents: [String]
        let seconds: Double
        let reportURL: URL
    }

    /// The settings from the environment, or nil when the sweep is not
    /// switched on.
    private static func settingsFromEnvironment() throws -> Settings? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TEXTMOUTH_IMPORT_FUZZ"] == "1" else { return nil }
        let seed = UInt64(environment["TEXTMOUTH_IMPORT_FUZZ_SEED"] ?? "") ?? defaultSeed
        let seconds = Double(environment["TEXTMOUTH_IMPORT_FUZZ_SECONDS"] ?? "") ?? 60

        var documents: [String]
        if let named = environment["TEXTMOUTH_IMPORT_FUZZ_DOCS"], !named.isEmpty {
            documents = named.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            // Every recorded book small enough to sweep quickly.
            documents = try TextPipelineFixtures.testDataBookNames.filter { name in
                let url = try requireFile(name)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                return size < defaultSizeLimit
            }
        }
        if environment["TEXTMOUTH_IMPORT_FUZZ_PDF"] == "1" {
            documents += pdfNames.filter { !documents.contains($0) }
        }

        let reportPath = environment["TEXTMOUTH_IMPORT_FUZZ_REPORT"].flatMap { $0.isEmpty ? nil : $0 }
        let reportURL = reportPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth-import-fuzz-report-\(seed).md")
        return Settings(seed: seed, documents: documents, seconds: seconds, reportURL: reportURL)
    }

    // MARK: - One Case

    /// What one watched import and load found.
    private struct CaseRun: Sendable {
        enum Outcome: Sendable {
            case imported
            case refused(String)
            case timedOut
        }

        var outcome: Outcome
        /// Invariants the import or the load broke, in words.
        var violations: [String] = []
    }

    /// Where a background job leaves its result for the waiting test.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CaseRun?

        func set(_ run: CaseRun) {
            lock.lock()
            defer { lock.unlock() }
            stored = run
        }

        func get() -> CaseRun? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Imports `file` into the library folder `folderPath` as the library
    /// does, and, when that publishes a book, loads it as the reader does and
    /// removes it. Runs on a background thread under the watchdog.
    private static func importAndLoad(_ file: URL, folderPath: String) -> CaseRun {
        let imported: ImportedBook
        do {
            imported = try FileImportService.importFileWithReport(from: file, toFolder: folderPath)
        } catch {
            var run = CaseRun(outcome: .refused(oneLine(ImportFailure.reason(for: error))))
            // Every refusal should name the file and the step that failed.
            if !(error is ImportFailure) {
                run.violations.append("refused with a bare error, not an ImportFailure: \(oneLine("\(error)"))")
            }
            return run
        }
        defer { forceRemove(imported.book.tmbDirectory) }

        var run = CaseRun(outcome: .imported)
        do {
            let loaded = try BookContentAnalysisService.load(book: imported.book)
            let hasText = loaded.content.chapters.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !hasText && imported.report.isComplete {
                run.violations.append("imported an empty book whose report says nothing is missing")
            }
        } catch {
            run.violations.append("the imported book does not load: \(oneLine(error.localizedDescription))")
        }
        return run
    }

    /// Imports `file` on a background thread, as the app's import queue does,
    /// and gives up waiting after `seconds`. The abandoned thread may finish
    /// later; the sweep goes on.
    private static func watchedImport(_ file: URL, folderPath: String, seconds: Double) -> CaseRun {
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(importAndLoad(file, folderPath: folderPath))
            finished.signal()
        }
        if finished.wait(timeout: .now() + seconds) == .timedOut {
            return CaseRun(outcome: .timedOut, violations: ["the import did not finish in \(Int(seconds)) seconds"])
        }
        return box.get() ?? CaseRun(outcome: .timedOut, violations: ["the import left no result"])
    }

    // MARK: - The Sweep

    /// Imports a damaged copy of every document, in every way that applies to
    /// it, and fails on any broken invariant that is not a known issue.
    func testImportDamagedCopiesOfEveryDocument() throws {
        guard let settings = try Self.settingsFromEnvironment() else {
            throw XCTSkip("Set TEXTMOUTH_IMPORT_FUZZ=1 to run the import fuzz sweep.")
        }

        let libraryFolder = makeIntegrationLibraryFolder("Import Fuzz")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let sources = try makeSandboxDirectory("ImportFuzzSources")
        let report = FuzzReport(url: settings.reportURL)
        report.start(seed: settings.seed, documents: settings.documents)
        print("IMPORT FUZZ REPORT: \(settings.reportURL.path)")
        fflush(stdout)

        var violations: [(id: String, text: String)] = []
        var counts = (cases: 0, imported: 0, refused: 0, timedOut: 0, skipped: 0)
        var casesWithViolations = Set<String>()
        var abandonedAnImport = false
        var caseNumber = 0

        for fileName in settings.documents {
            let original = try requireFile(fileName)
            let originalData = try Data(contentsOf: original)

            for mutation in ImportFuzzMutator.applicable(to: fileName) {
                let id = ImportFuzzMutator.caseID(fileName: fileName, mutation: mutation, seed: settings.seed)
                if let note = Self.skippedCases[id] {
                    counts.skipped += 1
                    report.record(id: id, line: "skipped: \(note)")
                    continue
                }
                caseNumber += 1
                counts.cases += 1

                // The damaged copy keeps the document's name, so its
                // extension still says what the importer should read.
                let caseFolder = sources.appendingPathComponent("case-\(caseNumber)", isDirectory: true)
                try FileManager.default.createDirectory(at: caseFolder, withIntermediateDirectories: true)
                let damagedFile = caseFolder.appendingPathComponent(fileName)
                let damagedData = ImportFuzzMutator.apply(
                    mutation, to: originalData, fileName: fileName, seed: settings.seed
                )
                try damagedData.write(to: damagedFile)

                // Named and flushed before the import: when the host crashes,
                // the log's last case is the culprit.
                print("FUZZ CASE \(id)")
                fflush(stdout)

                let before = Leftovers.snapshot(libraryFolder: libraryFolder)
                var run = Self.watchedImport(damagedFile, folderPath: libraryFolder.path, seconds: settings.seconds)
                if case .timedOut = run.outcome { abandonedAnImport = true }

                // The files are compared only while no abandoned import can
                // still be writing in the library.
                if !abandonedAnImport {
                    run.violations += Leftovers.snapshot(libraryFolder: libraryFolder).newItems(since: before)
                }
                if (try? Data(contentsOf: damagedFile)) != damagedData {
                    run.violations.append("the damaged file was changed or removed")
                }

                switch run.outcome {
                case .imported:
                    counts.imported += 1
                    report.record(id: id, line: "imported")
                case .refused(let message):
                    counts.refused += 1
                    report.record(id: id, line: "refused: \(message)")
                case .timedOut:
                    counts.timedOut += 1
                    report.record(id: id, line: "timed out")
                }
                for text in run.violations {
                    violations.append((id, text))
                    casesWithViolations.insert(id)
                    report.record(id: id, line: "VIOLATION: \(text)")
                }
                try? FileManager.default.removeItem(at: caseFolder)
            }
        }

        let knownAndViolating = casesWithViolations.intersection(Self.knownIssues.keys)
        report.finish(
            "done: \(counts.cases) cases, \(counts.imported) imported, \(counts.refused) refused, "
                + "\(counts.timedOut) timed out, \(counts.skipped) skipped, "
                + "\(violations.count) violations in \(casesWithViolations.count) cases "
                + "(\(knownAndViolating.count) cases known)"
        )

        // Known issues that no longer happen must be removed from the list.
        let ranIDs = Set(report.ids)
        for (id, note) in Self.knownIssues.sorted(by: { $0.key < $1.key })
        where ranIDs.contains(id) && !casesWithViolations.contains(id) {
            XCTFail("\(id) is listed as a known issue (\(note)) but no longer violates anything: remove it from the list")
        }

        let unexpected = violations.filter { Self.knownIssues[$0.id] == nil }
        if !unexpected.isEmpty {
            let lines = unexpected.map { "  \($0.id): \($0.text)" }.joined(separator: "\n")
            let documents = Set(unexpected.map { $0.id.components(separatedBy: "#").first ?? $0.id }).sorted()
            XCTFail(
                "The import broke \(unexpected.count) invariants:\n\(lines)\n"
                    + "Reproduce with: Scripts/test/import-fuzz.sh --docs \(documents.joined(separator: ",")) "
                    + "--seed \(settings.seed)"
            )
        }
    }

    // MARK: - Leftovers

    /// What a library folder and the scratch folders hold, to see what one
    /// import left behind.
    private struct Leftovers {
        /// Every name in the library folder, hidden ones included.
        let library: Set<String>
        /// Every staged package in this Mac's Import Staging folder.
        let staged: Set<String>
        /// Everything in the Archive Extraction folder.
        let extracted: Set<String>

        /// The three listings now.
        static func snapshot(libraryFolder: IntegrationLibraryFolder) -> Leftovers {
            Leftovers(
                library: (try? libraryFolder.entries()) ?? [],
                staged: Set(names(in: MachineLocalPaths.importStaging).filter(ImportStaging.isStagedPackageName)),
                extracted: Set(names(in: ImportScratchSpace.archiveExtractionFolder()))
            )
        }

        /// A sentence for everything here that `earlier` did not hold. A
        /// finished import (published and removed by the sweep, or refused)
        /// leaves nothing new in any of them.
        func newItems(since earlier: Leftovers) -> [String] {
            var found: [String] = []
            let places: [(String, Set<String>, Set<String>)] = [
                ("the library folder", library, earlier.library),
                ("Import Staging", staged, earlier.staged),
                ("Archive Extraction", extracted, earlier.extracted),
            ]
            for (place, now, then) in places where !now.subtracting(then).isEmpty {
                found.append("left \(now.subtracting(then).sorted().joined(separator: ", ")) in \(place)")
            }
            return found
        }

        /// The names in `folder`, or none when it is not there.
        private static func names(in folder: URL) -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
    }

    // MARK: - The Report

    /// The report file: a line per case, appended and flushed at once, so a
    /// crash leaves everything up to the case it happened in; the closing
    /// `done` line is written only when the sweep finishes.
    private final class FuzzReport {
        private let url: URL
        /// The ids recorded so far, in order.
        private(set) var ids: [String] = []

        init(url: URL) {
            self.url = url
        }

        /// Starts the file afresh with its heading.
        func start(seed: UInt64, documents: [String]) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let heading = "# Import fuzz report\n\nseed \(seed); documents: \(documents.joined(separator: ", "))\n\n"
            try? heading.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Appends one case's line and flushes.
        func record(id: String, line: String) {
            if ids.last != id { ids.append(id) }
            append("- `\(id)` \(line)\n")
        }

        /// Appends the closing line.
        func finish(_ line: String) {
            append("\n\(line)\n")
        }

        /// Appends `text` to the file and forces it to disk.
        private func append(_ text: String) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.synchronize()
        }
    }

    // MARK: - Small Helpers

    /// `text` with every line break turned into a space, for one-line reports.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Removes `url` and everything in it, after giving back the permission
    /// a failing import may have taken away.
    private static func forceRemove(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        if let items = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in items {
                chmod(item.path, 0o755)
            }
        }
        try? fileManager.removeItem(at: url)
    }
}
