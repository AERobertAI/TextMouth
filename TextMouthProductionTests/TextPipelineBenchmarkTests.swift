import Darwin
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Benchmarks of the text pipeline's performance work (PERF18 to PERF25 in
/// TODO-2026-09-04.md), each timing the reading path one item changes on
/// the inputs the performance review measured.
///
/// They are opt-in, because they measure for minutes in a Debug build and
/// a time means little there: run them in a Release build with
/// `TEST_RUNNER_TEXTMOUTH_BENCHMARKS=1` (xcodebuild passes the variable on
/// without its prefix), as in
/// `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES
/// -only-testing:TextMouthProductionTests/TextPipelineBenchmarkTests …`.
/// Each measurement prints one line beginning `BENCHMARK|`: the item, what
/// was measured, the fastest and median of its timed runs, and the most
/// heap an extra, sampled run held above what was held before it.
final class TextPipelineBenchmarkTests: XCTestCase {

    /// Skip every benchmark unless the run asked for them.
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TEXTMOUTH_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set TEXTMOUTH_BENCHMARKS=1 to run the text pipeline benchmarks")
        }
    }

    // MARK: - PERF18: HTML to Markdown

    /// Converting HTML whose paragraphs each hold one emphasis and one link,
    /// at the sizes the review measured, and HTML without inline markup.
    func testPERF18HTMLConversion() throws {
        for megabytes in [0.125, 0.25, 0.5, 1.0] {
            let html = TextPipelineFixtures.html(bytes: Int(megabytes * 1_048_576))
            try benchmark("PERF18", "HTML with emphasis and links, \(megabytes) MB", repetitions: megabytes >= 0.5 ? 1 : 3) {
                try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
            }
        }
        for megabytes in [1.0, 5.0] {
            let html = TextPipelineFixtures.html(bytes: Int(megabytes * 1_048_576), inlineMarkup: false)
            try benchmark("PERF18", "HTML without inline markup, \(megabytes) MB", repetitions: 2) {
                try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
            }
        }
    }

    // MARK: - PERF19: EPUB Preparation

    /// Preparing every chapter of a converted EPUB of 60 documents (about
    /// 1.8 MB of XHTML whose every element carries attributes), of the
    /// generated navigation EPUB, and of TestData's Alice.
    func testPERF19EPUBPreparation() throws {
        let converted = try TextPipelineFixtures.writeEPUB(
            TextPipelineFixtures.convertedBookEPUB(documents: 60, paragraphs: 40), named: "converted-60.epub", for: self
        )
        try benchmark("PERF19", "EPUBParser.prepareBook, converted EPUB of 60 documents") {
            try EPUBParser.prepareBook(url: converted)
        }
        let navigation = try TextPipelineFixtures.writeEPUB(TextPipelineFixtures.navigationEPUB(), named: "navigation.epub", for: self)
        try benchmark("PERF19", "EPUBParser.prepareBook, navigation EPUB", repetitions: 10) {
            try EPUBParser.prepareBook(url: navigation)
        }
        let alice = try requireFile("alice.epub")
        try benchmark("PERF19", "EPUBParser.prepareBook, alice.epub", repetitions: 5) {
            try EPUBParser.prepareBook(url: alice)
        }
    }

    // MARK: - PERF20: Archive Lookups

    /// Preparing an EPUB of 1,000 short documents behind 1,000 images, whose
    /// every chapter lookup passes the images; reading TestData's Alice
    /// document; and looking up every member of that EPUB one by one.
    func testPERF20ArchiveLookups() throws {
        let entries = TextPipelineFixtures.convertedBookEPUB(documents: 1_000, paragraphs: 1, images: 1_000)
        let epub = try TextPipelineFixtures.writeEPUB(entries, named: "many-members.epub", for: self)
        try benchmark("PERF20", "EPUBParser.prepareBook, 1,000 documents behind 1,000 images", repetitions: 1) {
            try EPUBParser.prepareBook(url: epub)
        }
        let archive = try Archive(url: epub, accessMode: .read)
        let paths = entries.map(\.path)
        try benchmark("PERF20", "Archive subscript for each of \(paths.count) members", repetitions: 1) {
            paths.reduce(0) { found, path in found + (archive[path] == nil ? 0 : 1) }
        }
        try benchmark("PERF20", "IndexedArchive built, then each of \(paths.count) members looked up", repetitions: 3) {
            let index = IndexedArchive(archive)
            return paths.reduce(0) { found, path in found + (index[path] == nil ? 0 : 1) }
        }
        let docx = try requireFile("alice.docx")
        try benchmark("PERF20", "DOCXParser.extractMarkdown, alice.docx", repetitions: 5) {
            try DOCXParser.extractMarkdown(from: docx)
        }
    }

    // MARK: - PERF21: Word Counts

    /// Counting the words of 5 MB of synthetic prose in one chapter, and of
    /// the reading text of a 60-document converted EPUB.
    func testPERF21WordCount() throws {
        let prose = Chapter(text: TextPipelineFixtures.plainText(bytes: 5 * 1_048_576))
        try benchmark("PERF21", "Chapter.wordCount, 5 MB of prose in one chapter") {
            prose.wordCount
        }
        let converted = try TextPipelineFixtures.writeEPUB(
            TextPipelineFixtures.convertedBookEPUB(documents: 60, paragraphs: 40), named: "converted-60.epub", for: self
        )
        let chapters = try EPUBParser.prepareBook(url: converted).chapters.map(\.chapter)
        let megabytes = Double(chapters.reduce(0) { $0 + $1.text.utf8.count }) / 1_048_576
        try benchmark("PERF21", String(format: "Chapter.wordCount, 60 EPUB chapters (%.2f MB)", megabytes)) {
            chapters.reduce(0) { $0 + $1.wordCount }
        }
    }

    // MARK: - PERF22: Opening content.md

    /// Reading a cached book's content.md into chapters: a 60-document
    /// EPUB's, and a 20 MB single-chapter plain text's.
    func testPERF22CacheParsing() throws {
        let converted = try TextPipelineFixtures.writeEPUB(
            TextPipelineFixtures.convertedBookEPUB(documents: 60, paragraphs: 40), named: "converted-60.epub", for: self
        )
        let book = try TextPipelineFixtures.imported(converted, for: self)
        let epubMarkdown = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
        try benchmark("PERF22", "parseMultiChapterMarkdown, 60-chapter EPUB cache") {
            MarkdownCacheService.parseMultiChapterMarkdown(epubMarkdown, bookTitle: "T", bookAuthor: "A")
        }
        try benchmark("PERF22", "BookContentAnalysisService.load, 60-chapter EPUB") {
            try BookContentAnalysisService.load(book: book)
        }
        let text = PlainTextParser.markdown(text: TextPipelineFixtures.plainText(bytes: 20 * 1_048_576))
        try benchmark("PERF22", "parseMultiChapterMarkdown, 20 MB plain-text cache", repetitions: 1) {
            MarkdownCacheService.parseMultiChapterMarkdown(text, bookTitle: "T", bookAuthor: "A")
        }
    }

    // MARK: - PERF23: Escaping and Plain-Text Headings

    /// Escaping 20 MB of prose as Markdown literals, and dividing it, and
    /// TestData's Pride and Prejudice, into headings and paragraphs.
    func testPERF23EscapingAndHeadings() throws {
        let text = TextPipelineFixtures.plainText(bytes: 20 * 1_048_576)
        try benchmark("PERF23", "MarkdownLiteral.escaped, 20 MB", repetitions: 2) {
            MarkdownLiteral.escaped(text)
        }
        try benchmark("PERF23", "PlainTextParser.blocks, 20 MB", repetitions: 2) {
            PlainTextParser.blocks(in: text)
        }
        try benchmark("PERF23", "PlainTextParser.markdown, 20 MB", repetitions: 1) {
            PlainTextParser.markdown(text: text)
        }
        let pride = try TextFileDecoder.readText(at: try requireFile("pride.txt"), format: .txt)
        try benchmark("PERF23", "PlainTextParser.blocks, pride.txt", repetitions: 5) {
            PlainTextParser.blocks(in: pride)
        }
    }

    // MARK: - PERF24: DAISY Audio

    /// Converting a DAISY 2.02 book with one 64 MB audio file to an audio
    /// book, from a ZIP archive and from a folder: its peak heap is the
    /// figure that matters.
    func testPERF24DAISYAudioCopy() throws {
        let files = TextPipelineFixtures.daisyAudioBook(audioBytes: 64 * 1_048_576)
        let zip = try makeTemporaryZip(
            prefix: "TextPipelineDAISY",
            orderedEntries: files.keys.sorted().map { TestZIPEntry($0, files[$0] ?? Data()) },
            compressionMethod: .deflate
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
        let archive = try Archive(url: zip, accessMode: .read)
        let folder = try TextPipelineFixtures.temporaryFolder(for: self)
        for (path, data) in files {
            try data.write(to: folder.appendingPathComponent(path))
        }
        let providers: [(String, DAISYFileProvider)] = [
            ("ZIP archive", ArchiveFileProvider(archive: archive)),
            ("folder", DirectoryFileProvider(baseURL: folder)),
        ]
        for (name, provider) in providers {
            try benchmark("PERF24", "DAISYAudioConverter.convertToAudioBook, 64 MB of audio from a \(name)", repetitions: 2) {
                let audio = try TextPipelineFixtures.temporaryFolder(for: self)
                return try DAISYAudioConverter.convertToAudioBook(from: provider, version: .daisy202, toDirectory: audio)
            }
        }
    }

    // MARK: - PERF25: Markdown Whitespace

    /// Normalizing the whitespace of 1 MB and 5 MB of Markdown, as DOCX and
    /// DAISY conversion finish theirs.
    func testPERF25WhitespaceNormalization() throws {
        for megabytes in [1, 5] {
            let markdown = TextPipelineFixtures.markdownWithTables(bytes: megabytes * 1_048_576)
            try benchmark("PERF25", "ParserUtilities.normalizeMarkdownWhitespace, \(megabytes) MB", repetitions: 3) {
                ParserUtilities.normalizeMarkdownWhitespace(markdown)
            }
        }
    }

    // MARK: - Measuring

    /// Run `body` `repetitions` times, then once more under a heap sampler,
    /// and print one `BENCHMARK|` line: `item`, `label`, the fastest and
    /// median times of the timed runs, and the most heap the sampled run
    /// held above what was held when it began.
    @discardableResult
    private func benchmark<T>(_ item: String, _ label: String, repetitions: Int = 3, _ body: () throws -> T) throws -> T {
        var times: [Double] = []
        for _ in 0..<max(1, repetitions) {
            try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = try body()
                let end = DispatchTime.now().uptimeNanoseconds
                withExtendedLifetime(value) {}
                times.append(Double(end - start) / 1_000_000)
            }
        }
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = HeapSampler.heapInUse()
        let sampler = HeapSampler()
        let value = try autoreleasepool { try body() }
        let peak = sampler.stop()
        times.sort()
        print(String(
            format: "BENCHMARK| %@ | %@ | fastest %.1f ms | median %.1f ms | runs %d | peak heap +%.1f MB",
            item, label, times[0], times[times.count / 2], times.count, Double(max(0, peak - baseline)) / 1_048_576
        ))
        return value
    }
}
