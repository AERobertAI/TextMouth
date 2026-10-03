import AVFoundation
import Darwin
import XCTest
import ZIPFoundation
@testable import TextMouth

// The generated inputs PerformanceBaselineTests measure with, shaped like the
// developer's library and books, never the live library (TODO Q05): the
// 643-book library of the October 3 performance review, written to disk as
// a launch finds it; a 1 MB EPUB; a chapter of a million characters and the
// developer's 16 substitution rules; the rendered speech of a 40,000-character
// chapter; and the packages a cloud refresh reads. The 3-file audiobook and
// the 180-heading book come from the integration and views test support.

enum PerformanceFixtures {

    // MARK: - The Developer's Substitution Rules

    /// The developer's 16 substitution rules, copied by hand from
    /// substitutions.json as it held them on October 3, 2026: the 15
    /// standard rules and a rule that reads an OCR'd " | " as " I ".
    /// `TextSubstitutionService.benchmarkRules` builds the same rules from
    /// today's standard ones; this copy stays as it is, so a change to the
    /// standard rules never changes what a baseline measured.
    static let substitutionRulesLocation = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("performance-substitutions.json")

    /// The developer's 16 substitution rules, decoded as TextMouth decodes
    /// substitutions.json.
    static func developerSubstitutionRules() throws -> [SubstitutionRule] {
        try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: substitutionRulesLocation))
    }

    // MARK: - The Library on Disk

    /// The generated 643-book library (`LibraryBenchmarkFixture`), written
    /// into the hosted test root as a launch finds a library that is up to
    /// date: every book in a package of its own, in its folder, holding its
    /// file, a current text cache whose fingerprints the row records, and
    /// its record. Everything lives in a folder of the test's own at the top
    /// of the library, removed when the test ends; the returned library
    /// names it, so the generated root books sit one folder deep.
    ///
    /// The books' files are small stand-ins, since a launch reads none of
    /// them: it checks which files are there and how large they are.
    @MainActor
    static func writeLibraryOnDisk(for testCase: XCTestCase) throws -> Library {
        try TextMouthPaths.ensureDirectoryStructure()
        let top = "Performance Baselines \(UUID().uuidString.prefix(8))"
        let topURL = TextMouthPaths.libraryDir.appendingPathComponent(top, isDirectory: true)
        testCase.addTeardownBlock {
            // Queued record writes land first, so none recreates a package.
            LibraryPersistenceService.flushPendingSave()
            try? FileManager.default.removeItem(at: topURL)
        }
        let generated = try LibraryBenchmarkFixture.library()
        /// `path` moved under the test's own folder.
        func shelved(_ path: String) -> String {
            path.isEmpty ? top : "\(top)/\(path)"
        }
        let standIn = Data("A stand-in for a book's file, which a launch never reads.".utf8)
        let cacheText = Data("# A Book\n\nA few words of its text cache.\n".utf8)
        var books: [Book] = []
        books.reserveCapacity(generated.books.count)
        for var book in generated.books {
            book.folderPath = shelved(book.folderPath)
            let package = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let source = package.appendingPathComponent("book.epub")
            try standIn.write(to: source)
            let cache = TextMouthPaths.contentMarkdownPath(in: package)
            try cacheText.write(to: cache)
            guard let sourcePrint = FileFingerprint(of: source, hasher: .md5),
                  let cachePrint = FileFingerprint(of: cache, hasher: .md5) else {
                throw PerformanceBaselineError.fixture("could not fingerprint the files of \(package.path)")
            }
            book.filePath = source.path
            book.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
            book.contentIndexVersion = BookContentIndex.currentVersion
            book.textCacheFingerprint = TextCacheFingerprint(source: sourcePrint, cache: cachePrint)
            try book.saveBookInfoThrowing()
            books.append(book)
        }
        let folders = [BookFolder(name: top)] + generated.folders.map {
            BookFolder(name: $0.name, parentPath: shelved($0.parentPath))
        }
        return Library(books: books, folders: folders)
    }

    // MARK: - The 1 MB EPUB

    /// Chapter documents in the 1 MB EPUB.
    static let epubDocumentCount = 120
    /// Paragraphs in each of its chapter documents.
    static let epubParagraphsPerDocument = 40
    /// The sizes, in bytes, that count as about 1 MB: the generated EPUB
    /// must be one, so a change to its generator cannot quietly change what
    /// the baselines measure.
    static let epubSizes = 900_000...1_150_000

    /// A converted EPUB of about 1 MB, compressed as published EPUBs are,
    /// shaped like the converted books most of the developer's library
    /// holds (`TextPipelineFixtures.convertedBookEPUB`): its chapters are
    /// documents whose every element carries class and style attributes,
    /// with emphasis, links, and spans, named by a navigation document and
    /// an NCX. Written in a temporary folder `testCase` removes.
    static func oneMegabyteEPUB(for testCase: XCTestCase) throws -> URL {
        let entries = TextPipelineFixtures.convertedBookEPUB(
            documents: epubDocumentCount,
            paragraphs: epubParagraphsPerDocument
        )
        let archive = try makeTemporaryZip(prefix: "PerformanceEPUB", orderedEntries: entries, compressionMethod: .deflate)
        let epub = try TextPipelineFixtures.temporaryFolder(for: testCase)
            .appendingPathComponent("A Converted Anthology.epub")
        try FileManager.default.moveItem(at: archive, to: epub)
        let bytes = (try FileManager.default.attributesOfItem(atPath: epub.path)[.size] as? NSNumber)?.intValue ?? 0
        guard epubSizes.contains(bytes) else {
            throw PerformanceBaselineError.fixture(
                "the generated EPUB holds \(bytes) bytes, not about 1 MB; change epubDocumentCount to suit"
            )
        }
        return epub
    }

    /// A book for `epub` in a package of its own in `folder`, as an import
    /// places one before it extracts the book's text: its file is there,
    /// and nothing else.
    @MainActor
    static func packagedEPUBBook(_ epub: URL, in folder: IntegrationLibraryFolder) throws -> Book {
        let packageName = "Performance EPUB \(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent(epub.lastPathComponent)
        try FileManager.default.copyItem(at: epub, to: source)
        return Book(
            title: "A Converted Anthology",
            author: "Saoirse Adeyemi-Holm",
            format: .epub,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder.path,
            tmbDirectoryName: packageName
        )
    }

    // MARK: - A Book With the Largest Record

    /// Headings in the content index of `bookWithLargestRecord(in:)`.
    static let largestRecordHeadingCount = 2_700

    /// A small Markdown book in a package of its own in `folder`, whose
    /// record holds a content index of 2,700 headings: about 690 KB, as
    /// large as the developer's largest record. A reading checkpoint should
    /// write a kilobyte of it.
    @MainActor
    static func bookWithLargestRecord(in folder: IntegrationLibraryFolder) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "Performance Checkpoint \(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("book.md")
        try "# Opening\n\nThe words of a long collection.".write(to: source, atomically: true, encoding: .utf8)
        let index = PersistenceCostTests.contentIndex(headingCount: largestRecordHeadingCount)
        var book = Book(
            title: "The Collected Works",
            author: "Cost Fixture",
            format: .markdown,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder.path,
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        book.applyContentAnalysis(index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        try book.saveBookInfoThrowing(contentIndex: index)
        return book
    }

    // MARK: - A Chapter of a Million Characters

    /// UTF-16 units in the long chapter: 46 of the developer's books have a
    /// chapter of a million characters or more.
    static let longChapterLength = 1_000_000

    /// A chapter of exactly a million UTF-16 units of the prose the speech
    /// benchmarks generate (`BenchmarkProse`): curly quotes and em dashes,
    /// titles and footnote marks the substitution rules rewrite, and now and
    /// then a separator line for the repeated-symbol rule.
    static func millionCharacterChapter() -> String {
        var prose = BenchmarkProse(seed: 11)
        return BenchmarkProse.prefix(of: prose.text(utf16Length: longChapterLength), utf16Length: longChapterLength)
    }

    // MARK: - Rendered Speech

    /// Seconds of speech the system voice renders for each UTF-16 unit of
    /// plain prose at the render's fixed rate: 1,030 seconds for the
    /// 40,000-unit chapter of the PERF04 benchmark.
    static let renderedSecondsPerUnit = 1_030.0 / 40_000
    /// The sample rate the system voice renders at.
    static let renderSampleRate = 22_050.0
    /// Frames in each piece the synthesizer writes: 256, about 12 ms.
    static let renderPieceFrameCount = 256
    /// Bytes in the megabytes the memory measurements report.
    static let bytesPerMegabyte = 1_048_576.0

    /// What building the rendered speech of a chapter of `units` UTF-16
    /// units costs in memory: the most malloc held above what it held
    /// before, while the speech was built, and what it held once built, in
    /// megabytes. The audio is built as a render builds it, in
    /// `RenderedSpeechAudio.Builder`, from pieces of a quiet tone written as
    /// the synthesizer writes them, so nothing is synthesized or heard, and
    /// the measurement takes a fraction of a second rather than the half
    /// minute the system voice takes.
    static func renderedSpeechMemory(units: Int) throws -> (peakMegabytes: Double, keptMegabytes: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: 1),
              let piece = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(renderPieceFrameCount)
              ),
              let samples = piece.floatChannelData?[0] else {
            throw PerformanceBaselineError.fixture("could not make a piece of rendered speech")
        }
        // A quiet 220 Hz tone: every sample takes the same conversion speech does.
        for frame in 0..<renderPieceFrameCount {
            samples[frame] = 0.25 * sin(2 * Float.pi * 220 * Float(frame) / Float(renderSampleRate))
        }
        let speechFrames = Int((Double(units) * renderedSecondsPerUnit * renderSampleRate).rounded())

        // Let malloc give back what earlier work freed, so the figures start
        // from what is really held.
        _ = malloc_zone_pressure_relief(nil, 0)
        let before = HeapSampler.heapInUse()
        let sampler = HeapSampler()
        let audio = autoreleasepool { () -> RenderedSpeechAudio? in
            let builder = RenderedSpeechAudio.Builder()
            var remaining = speechFrames
            while remaining > 0 {
                piece.frameLength = AVAudioFrameCount(min(remaining, renderPieceFrameCount))
                builder.append(piece)
                remaining -= Int(piece.frameLength)
            }
            return builder.finish(
                paddingFrameCount: AudioEngineService.silencePaddingFrameCount(sampleRate: renderSampleRate)
            )
        }
        let peak = sampler.stop()
        let kept = HeapSampler.heapInUse()
        guard let audio, audio.speechFrameCount == speechFrames else {
            throw PerformanceBaselineError.fixture("the rendered speech did not keep all \(speechFrames) frames")
        }
        // The audio is held until both figures are read.
        withExtendedLifetime(audio) {}
        return (
            Double(max(0, peak - before)) / bytesPerMegabyte,
            Double(max(0, kept - before)) / bytesPerMegabyte
        )
    }

    // MARK: - The Packages a Cloud Refresh Reads

    /// `count` book packages in the hosted test root's library, named and
    /// shelved in 38 folders as the developer's are. None is on disk: a
    /// refresh of a library outside the cloud never reads them.
    static func cloudRefreshPackages(count: Int = LibraryBenchmarkFixture.bookCount) -> [BookPackage] {
        (0..<count).map { number in
            BookPackage(
                bookID: UUID(),
                url: TextMouthPaths.libraryDir
                    .appendingPathComponent("Synthetic Shelf \(number % 38)", isDirectory: true)
                    .appendingPathComponent("Synthetic_Title_\(number)-Synthetic_Author-1774073441.tmb", isDirectory: true),
                isPackage: true,
                isAudio: false
            )
        }
    }
}

// MARK: - A Render Queue That Renders Nothing

/// Stands in for the shared render queue in a reader that is only opened:
/// it loads no voice and renders nothing, so no work of the system
/// synthesizer runs beside the measurements. Such a reader never plays, so
/// it never asks for a render.
@MainActor
final class SilentRenderQueue: SpeechRenderScheduling {
    /// Keeps nothing: the measured readers never render.
    func render(
        _ request: SpeechRenderRequest,
        engine: AudioEngineService,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {}
}

// MARK: - Waiting Precisely

extension XCTestCase {
    /// Runs the main run loop until `condition` holds, checking it after
    /// each piece of work the loop does, so a measurement that waits for
    /// main-queue work ends within a moment of it; false when `timeout`
    /// seconds pass first.
    @MainActor
    func runMainLoopPromptly(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            let now = Date()
            guard now < deadline else { return false }
            // Returns after the first source the loop handles, the main
            // queue's work included, or after a millisecond at most.
            _ = RunLoop.main.run(mode: .default, before: min(deadline, now.addingTimeInterval(0.001)))
        }
        return true
    }
}
