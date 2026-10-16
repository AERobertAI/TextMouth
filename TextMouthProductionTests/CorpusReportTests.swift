import XCTest
@testable import TextMouth

/// The corpus report, run for real.
///
/// `testReportOnTheCorpusFolder` is opt-in: it reads the folder named by
/// `TEXTMOUTH_CORPUS_DIR`, imports every file in it through the importers,
/// and writes a Markdown report to the path named by
/// `TEXTMOUTH_CORPUS_REPORT` (`Scripts/test/corpus-report.sh` sets both).
/// The other tests build their own small folder in a sandbox and pin that the
/// walk never harms the originals it reads. Nothing here reads the user's
/// library or any folder but the one named.
final class CorpusReportTests: XCTestCase {

    // MARK: - Environment

    /// The variable that names the folder to read.
    static let folderVariable = "TEXTMOUTH_CORPUS_DIR"
    /// The variable that names the report file to write.
    static let reportVariable = "TEXTMOUTH_CORPUS_REPORT"

    // MARK: - The Real Run

    /// Reads the corpus folder and writes the report, as each file is done.
    func testReportOnTheCorpusFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        var isFolder: ObjCBool = false
        guard let path = environment[Self.folderVariable], !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw XCTSkip("Set TEXTMOUTH_CORPUS_DIR to a folder of documents to run this.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let reportURL = URL(fileURLWithPath: environment[Self.reportVariable].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSTemporaryDirectory() + "textmouth-corpus-report.md")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sandbox = try makeSandbox()
        let runner = CorpusRunner(
            folder: folder, sandbox: sandbox, libraryFolderPath: makeIntegrationLibraryFolder("corpus-report").path,
            settings: CorpusSettings.from(environment: environment)
        )

        // Write the whole report after every file: a crash or a hang then
        // leaves a report that is complete up to the last file that finished.
        var writeFailure: String?
        func write(_ entries: [CorpusFileEntry], found: Int, complete: Bool) {
            let context = self.context(folder: folder, sandbox: sandbox, found: found, limit: runner.settings.maxFiles, complete: complete)
            do {
                try CorpusReportBuilder.report(context: context, entries: entries)
                    .write(to: reportURL, atomically: true, encoding: .utf8)
            } catch {
                writeFailure = error.localizedDescription
            }
        }
        let result = runner.run { entries, found in write(entries, found: found, complete: false) }
        write(result.entries, found: result.foundCount, complete: true)

        XCTAssertNil(writeFailure, "The report could not be written to \(reportURL.path): \(writeFailure ?? "")")
        print("CORPUS REPORT: \(reportURL.path)")
        print("CORPUS COUNTS: \(CorpusReportBuilder.countsLine(for: result.entries))")
    }

    // MARK: - The Originals Are Safe

    /// A walk over a folder holding a text file, a Markdown file, a nested
    /// text file, and a damaged EPUB leaves every original as it was, makes
    /// no file in the folder, and leaves nothing staged: not in the library
    /// folder the imports publish into, not in the sandbox the files are
    /// copied into.
    func testTheWalkLeavesTheOriginalsAndTheSandboxAsItFoundThem() throws {
        let root = try makeSandbox()
        let folder = root.appendingPathComponent("My Corpus", isDirectory: true)
        let originals: [String: String] = [
            "story.txt": "A short story.\n\nIt has two paragraphs.\n",
            "notes.md": "# Notes\n\nSome notes under a heading.\n",
            "nested/deeper.txt": "A nested file.\n",
            "damaged.epub": "Not a ZIP archive.",
        ]
        for (name, contents) in originals {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let before = try snapshot(of: folder)
        let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
        let library = makeIntegrationLibraryFolder("corpus-originals")

        let runner = CorpusRunner(folder: folder, sandbox: sandbox, libraryFolderPath: library.path, settings: CorpusSettings())
        let result = runner.run { _, _ in }

        // Every original is there with the same bytes, and nothing is new.
        XCTAssertEqual(try snapshot(of: folder), before, "The walk changed the corpus folder")
        XCTAssertEqual(before.count, originals.count)
        for (name, contents) in originals {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data(contents.utf8), name)
        }
        // Nothing staged or published is left behind.
        XCTAssertEqual(try library.entries(), [], "The library folder holds leftovers")
        let copies = sandbox.appendingPathComponent("copies")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []
        XCTAssertEqual(leftovers, [], "The sandbox holds copies of imported files")

        // And the walk said what happened to each file, in sorted order.
        XCTAssertEqual(result.entries.map(\.relativePath), ["damaged.epub", "nested/deeper.txt", "notes.md", "story.txt"])
        XCTAssertEqual(result.entries.map(\.resultWord), ["refused", "imported", "imported", "imported"])
        XCTAssertEqual(result.foundCount, 4)
        if case .refused(let message)? = result.entries.first?.outcome {
            XCTAssertTrue(message.contains("damaged.epub"), "The refusal should name the file: \(message)")
        } else {
            XCTFail("The damaged EPUB should be refused")
        }
        if case .imported(let facts)? = result.entries.dropFirst(2).first?.outcome {
            XCTAssertEqual(facts.firstLines, ["Notes", "Some notes under a heading."])
            XCTAssertEqual(facts.dump.headings.map(\.text), ["Notes"])
        } else {
            XCTFail("The Markdown file should be imported")
        }
    }

    // MARK: - The Walk

    /// Files are found in sorted order, hidden files and the insides of
    /// packages are left out, and a folder name with spaces and accents is
    /// no trouble.
    func testTheWalkFindsFilesInSortedOrderAndSkipsHiddenOnesAndPackages() throws {
        let root = try makeSandbox().appendingPathComponent("Dossier à lire", isDirectory: true)
        let names = ["b.txt", "a.txt", "Sous dossier/é.md", ".hidden.txt", ".DS_Store", "Pack.app/Contents/inside.txt"]
        for name in names {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        XCTAssertEqual(CorpusRunner.files(in: root).map(\.relativePath), ["Sous dossier/é.md", "a.txt", "b.txt"])
    }

    /// An Ogg file is skipped with the reason and never copied or read, and
    /// so is a ZIP that holds one; a ZIP without one is not skipped.
    func testOggFilesAndZipsHoldingThemAreSkippedUnread() throws {
        let root = try makeSandbox()
        let folder = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not really Ogg".utf8).write(to: folder.appendingPathComponent("track.OGG"))
        try Data("not really Opus".utf8).write(to: folder.appendingPathComponent("voice.opus"))
        let staging = root.appendingPathComponent("zipstaging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("padding".utf8).write(to: staging.appendingPathComponent("part1.ogg"))
        try Data("padding".utf8).write(to: staging.appendingPathComponent("readme.txt"))
        try zip(["part1.ogg"], in: staging, to: folder.appendingPathComponent("drama.zip"))
        try zip(["readme.txt"], in: staging, to: root.appendingPathComponent("plain.zip"))

        XCTAssertTrue(CorpusRunner.zipHoldsOgg(folder.appendingPathComponent("drama.zip")))
        XCTAssertFalse(CorpusRunner.zipHoldsOgg(root.appendingPathComponent("plain.zip")))
        XCTAssertFalse(CorpusRunner.zipHoldsOgg(root.appendingPathComponent("missing.zip")), "A ZIP that cannot be listed is not skipped")

        let runner = CorpusRunner(
            folder: folder, sandbox: root.appendingPathComponent("sandbox"),
            libraryFolderPath: makeIntegrationLibraryFolder("corpus-ogg").path, settings: CorpusSettings()
        )
        let result = runner.run { _, _ in }
        XCTAssertEqual(result.entries.map(\.relativePath), ["drama.zip", "track.OGG", "voice.opus"])
        XCTAssertEqual(result.entries.map(\.resultWord), ["skipped", "skipped", "skipped"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sandbox/copies").path), "A skipped file is not copied")
    }

    /// The run stops at the file limit and says how many files the folder
    /// holds.
    func testTheRunStopsAtTheFileLimit() throws {
        let root = try makeSandbox()
        let folder = root.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 1...3 {
            try Data("File \(number).\n".utf8).write(to: folder.appendingPathComponent("f\(number).txt"))
        }
        var settings = CorpusSettings()
        settings.maxFiles = 2
        let runner = CorpusRunner(
            folder: folder, sandbox: root.appendingPathComponent("sandbox"),
            libraryFolderPath: makeIntegrationLibraryFolder("corpus-limit").path, settings: settings
        )
        var snapshots: [Int] = []
        let result = runner.run { entries, _ in snapshots.append(entries.count) }
        XCTAssertEqual(result.entries.map(\.relativePath), ["f1.txt", "f2.txt"])
        XCTAssertEqual(result.foundCount, 3)
        XCTAssertEqual(snapshots, [0, 1, 2], "The report is offered before the first file and after each one")
    }

    // MARK: - Limits and Settings

    /// A slow operation gives up at the limit with nil; a quick one returns
    /// its value.
    func testAnOperationThatOutlastsItsLimitReturnsNil() {
        XCTAssertEqual(CorpusRunner.runWithLimit(seconds: 5) { 42 }, 42)
        let slow: Int? = CorpusRunner.runWithLimit(seconds: 0.1) {
            Thread.sleep(forTimeInterval: 0.6)
            return 1
        }
        XCTAssertNil(slow)
    }

    /// The environment sets the limits; a value that is not a whole number
    /// of at least 1 leaves the default.
    func testSettingsComeFromTheEnvironment() {
        let defaults = CorpusSettings.from(environment: [:])
        XCTAssertEqual(defaults.maxFiles, 200)
        XCTAssertEqual(defaults.fileSeconds, 180)
        let set = CorpusSettings.from(environment: [
            CorpusSettings.maxFilesVariable: "7", CorpusSettings.fileSecondsVariable: "30",
        ])
        XCTAssertEqual(set.maxFiles, 7)
        XCTAssertEqual(set.fileSeconds, 30)
        let bad = CorpusSettings.from(environment: [
            CorpusSettings.maxFilesVariable: "0", CorpusSettings.fileSecondsVariable: "soon",
        ])
        XCTAssertEqual(bad.maxFiles, 200)
        XCTAssertEqual(bad.fileSeconds, 180)
    }

    // MARK: - Helpers

    /// A new folder in the system's temporary folder, removed when the test
    /// ends.
    private func makeSandbox() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-report-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The report's context for a run on `folder`: today's date, this Mac,
    /// this build, and the paths the report must not show.
    private func context(folder: URL, sandbox: URL, found: Int, limit: Int, complete: Bool) -> CorpusReportContext {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        // Each path in the forms a message may use: as given and with
        // symbolic links (such as /var for /private/var) resolved.
        let hidden = [
            (folder, "the corpus folder"), (sandbox, "the sandbox"), (TextMouthPaths.libraryDir, "the test library"),
        ].flatMap { location, words in
            Set([location.path, location.resolvingSymlinksInPath().path]).map {
                CorpusReportContext.HiddenPath(path: $0, replacement: words)
            }
        }
        return CorpusReportContext(
            folderName: folder.lastPathComponent, date: formatter.string(from: Date()),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString, appBuild: "\(version) (build \(build))",
            hiddenPaths: hidden, foundCount: found, fileLimit: limit, isComplete: complete
        )
    }

    /// Every file under `folder` (relative path to its bytes), to compare
    /// before and after.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for item in CorpusRunner.files(in: folder) {
            result[item.relativePath] = try Data(contentsOf: item.url)
        }
        return result
    }

    /// Makes a ZIP of `names` (files in `directory`) at `archive`, with the
    /// system's `zip`.
    private func zip(_ names: [String], in directory: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", archive.path] + names
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip could not make \(archive.lastPathComponent)")
    }
}
