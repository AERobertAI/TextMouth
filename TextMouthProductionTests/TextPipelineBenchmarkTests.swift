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

/// Samples the bytes malloc holds live every half millisecond, on a thread
/// of its own, while a measured run goes on, keeping the highest.
///
/// `@unchecked Sendable`: `running` and `peak` are read and changed only
/// under `lock`; everything else is a constant.
private final class HeapSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak: Int
    private let finished = DispatchSemaphore(value: 0)

    /// The bytes every malloc zone holds live now.
    static func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// Start sampling at once.
    init() {
        peak = Self.heapInUse()
        let thread = Thread { [self] in
            while true {
                let sample = Self.heapInUse()
                lock.lock()
                peak = max(peak, sample)
                let keepGoing = running
                lock.unlock()
                if !keepGoing { break }
                usleep(500)
            }
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stop sampling and return the highest sample.
    func stop() -> Int {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}
