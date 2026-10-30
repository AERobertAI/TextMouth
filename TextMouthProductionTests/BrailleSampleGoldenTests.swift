import XCTest
@testable import TextMouth

/// Every BRF and BRL format sample reads, byte for byte, as it read before
/// braille files had a choice of character code (braillecodes,
/// BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8).
///
/// A BRF or BRL file writes each braille cell as a character, and TextMouth
/// learned to read other codes than North American Braille ASCII. A book that
/// records no code is read in North American Braille ASCII, as every braille
/// book was before, so the text a listener hears must not change by a byte.
/// These digests were recorded on `team/braillecodes` before any change for
/// braille file codes (at 77a68196), from each sample imported with the
/// table it is written in: content.md as the import writes it, the reading
/// the reader opens to, and the Markdown read without pages, which the
/// launch's re-read for pages compares content.md with (PG16).
///
/// A later change that alters a digest changes what a listener hears or
/// what a re-read compares, and must be justified on its own. It is never
/// to be recorded again only to make this test pass.
final class BrailleSampleGoldenTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
    }

    // MARK: - The Samples

    /// Each BRF and BRL sample, by its path inside `TestData/format-samples`,
    /// with the table it is written in: the Grade 2 sample with contracted
    /// UEB, the others with uncontracted UEB.
    private static let samples: [(path: String, table: String)] = [
        ("brf/grade2-short.brf", "en-ueb-g2.ctb"),
        ("brf/pride-and-prejudice-ch1-grade1.brf", "en-ueb-g1.ctb"),
        ("brf/wrapped-titles.brf", "en-ueb-g1.ctb"),
        ("brl/pride-and-prejudice-ch1-grade1.brl", "en-ueb-g1.ctb"),
    ]

    /// content.md as the import writes it, for each sample.
    private static let recordedCaches: [String: String] = [
        "brf/grade2-short.brf": "1716df4d420141ca",
        "brf/pride-and-prejudice-ch1-grade1.brf": "1b07bd1301c7eba4",
        "brf/wrapped-titles.brf": "c58916a514e733b8",
        "brl/pride-and-prejudice-ch1-grade1.brl": "608cc4f1036ad689",
    ]

    /// What each sample opens to in the reader (`TextPipelineFixtures
    /// .digest(of:index:)` of what `BookContentAnalysisService.load` returns).
    private static let recordedReadings: [String: String] = [
        "brf/grade2-short.brf": "a120693e9577d8b1",
        "brf/pride-and-prejudice-ch1-grade1.brf": "cd4b3712621c509b",
        "brf/wrapped-titles.brf": "322d66cef3946214",
        "brl/pride-and-prejudice-ch1-grade1.brl": "63d99aecfc2d9aee",
    ]

    /// The Markdown each sample reads as without page markers
    /// (`MarkdownCacheService.extractedMarkdown(for:includesPages: false)`).
    private static let recordedWithoutPages: [String: String] = [
        "brf/grade2-short.brf": "6867e339f4ff60e6",
        "brf/pride-and-prejudice-ch1-grade1.brf": "1d4e86ef35045e75",
        "brf/wrapped-titles.brf": "4bb1f87ee40c3b08",
        // A BRL has no pages: its content.md is this Markdown already.
        "brl/pride-and-prejudice-ch1-grade1.brl": "608cc4f1036ad689",
    ]

    // MARK: - Tests

    /// The list names every BRF and BRL file of the samples' braille folders,
    /// so a sample added later is compared too.
    func testTheListNamesEveryBRFAndBRLSample() throws {
        var onDisk: [String] = []
        for folder in ["brf", "brl"] {
            let url = try formatSampleURL(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where ["brf", "brl"].contains((name as NSString).pathExtension.lowercased()) {
                onDisk.append("\(folder)/\(name)")
            }
        }
        XCTAssertEqual(onDisk.sorted(), Self.samples.map(\.path).sorted())
    }

    /// Every sample imports to the content.md, the reading, and the Markdown
    /// without pages recorded for it.
    func testEveryBRFAndBRLSampleReadsAsRecorded() throws {
        for sample in Self.samples {
            compare(sample.path, table: sample.table)
        }
    }

    // MARK: - Comparing

    /// Imports a copy of the sample at `path` with `table` as the Braille
    /// setting's table and compares its three digests with those recorded.
    /// A sample that cannot be imported, or has no record, fails by name with
    /// what it found, and the others are still compared.
    private func compare(_ path: String, table: String) {
        do {
            let copy = try copyOfFormatSample(path)
            let book = try BraillePreferences.$tableForImports.withValue(table) {
                try importedForTest(copy).book
            }
            let cache = TextPipelineFixtures.digest(try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)))
            let opened = try BookContentAnalysisService.load(book: book)
            let reading = TextPipelineFixtures.digest(of: opened.content.chapters, index: opened.index)
            let markdown = try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: book, includesPages: false), path)
            let withoutPages = TextPipelineFixtures.digest(markdown)
            guard let recordedCache = Self.recordedCaches[path],
                  let recordedReading = Self.recordedReadings[path],
                  let recordedWithoutPages = Self.recordedWithoutPages[path] else {
                XCTFail("\(path) has no recorded output (content.md \(cache), reading \(reading), "
                    + "without pages \(withoutPages))")
                return
            }
            XCTAssertEqual(cache, recordedCache, "content.md of \(path)")
            XCTAssertEqual(reading, recordedReading, "reading of \(path)")
            XCTAssertEqual(withoutPages, recordedWithoutPages, "Markdown without pages of \(path)")
        } catch {
            XCTFail("\(path) could not be imported and read, so it was not compared: \(error.localizedDescription)")
        }
    }
}
