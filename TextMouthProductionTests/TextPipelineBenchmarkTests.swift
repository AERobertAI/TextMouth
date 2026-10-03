import Darwin
import XCTest
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
