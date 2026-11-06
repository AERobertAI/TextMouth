import XCTest
@testable import TextMouth

/// The Word reader's reading of Word 6 and Word 95 documents (`WordDocumentLegacyTests` asks what it reads)
/// held against hostile files: LibreOffice's crash, hang, and fuzzer files from its `ww6` tests, real samples
/// cut short, every offset and count of the FIB pointed past the end or set to the largest, bytes flipped
/// with a fixed seed, a style sheet that loops or chains thousands deep, and documents of many paragraphs and
/// notes whose reading must grow in step with their size. Every read must throw or read at once; none may
/// trap, hang, or take time that grows faster than the document.
final class WordDocumentLegacyHostileTests: XCTestCase {

    typealias Builder = WordLegacyDocumentBuilder
    typealias Paragraph = Builder.Paragraph
    typealias Run = Builder.Run

    /// The longest any one read of a small hostile document may take.
    private let limit: TimeInterval = 1.0

    // MARK: - Helpers

    /// A generator that gives the same numbers every run.
    private struct SeededGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    /// The `WordDocument` stream of the compound file `data`.
    private func stream(of data: Data) throws -> [UInt8] {
        try [UInt8](XCTUnwrap(CompoundFile(data).stream(named: "WordDocument")))
    }

    /// A compound file holding only `stream` as its `WordDocument`.
    private func file(holding stream: [UInt8]) -> Data {
        var builder = CompoundFileBuilder()
        builder.streams = [("WordDocument", stream)]
        return builder.build().data
    }

    /// Reads `data` and returns how long it took; a thrown error is an acceptable outcome, a trap or a hang is not.
    @discardableResult
    private func read(_ data: Data, includesPages: Bool = true) -> TimeInterval {
        let start = Date()
        _ = try? WordDocumentReader.html(from: data, includesPages: includesPages)
        return Date().timeIntervalSince(start)
    }

    /// The real documents of the old layout, as streams, by name.
    private func realStreams() throws -> [(name: String, stream: [UInt8])] {
        try [
            "doc6/poi-Word6.doc", "doc6/poi-Word95.doc", "doc6/poi-Word6_sections2.doc", "doc6/libreoffice-ooo17498-1.doc",
            "doc6/poi-word95err.doc", "doc/poi-Bug51944.doc", "doc/libreoffice-tdf150197_anlv2ListFormat.doc",
        ].map { (name: $0, stream: try stream(of: Data(contentsOf: formatSampleURL($0)))) }
    }

    /// Documents built in code that use what the samples lack: notes, sections, numbering, Fast Save, two-byte units.
    private func builtStreams() -> [(name: String, stream: [UInt8])] {
        var rich = Builder()
        rich.paragraphs = [
            Paragraph("Title", style: 1), Paragraph(runs: [Run("Body"), Run("\u{02}", sprms: Builder.sprm(117, [1]))]),
            Paragraph("Numbered", sprms: Builder.numbering()), Paragraph("Cell", sprms: Builder.inTable, mark: 0x07),
            Paragraph("", sprms: Builder.inTable + Builder.rowEnd, mark: 0x07), Paragraph("end", mark: 0x0C),
        ]
        rich.footnotes = ["\u{02}A note."]
        rich.sections = [Builder.Section(end: 4, breakKind: nil), Builder.Section(end: 30, breakKind: 2)]
        rich.fontCharacterSets = [0, 204]
        var fast = rich
        fast.isFastSaved = true
        var wide = rich
        wide.twoByteCharacters = true
        return [("rich", rich), ("fast", fast), ("wide", wide)].map { (name: $0.0, stream: $0.1.buildStream().bytes) }
    }

    // MARK: - The Hostile Files

    func testEveryHostileAndRealSampleReadsOrThrowsAtOnce() throws {
        let folder = try formatSampleURL("doc6")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 20)
        var slow: [String] = []
        for name in names {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            for pages in [true, false] where read(data, includesPages: pages) > limit { slow.append(name) }
        }
        XCTAssertEqual(slow, [], "samples that took over \(limit) seconds")
    }

    func testTheHostileSamplesThatReadAreWordsOrTheyAreRefusedInTheListenersWords() throws {
        let folder = try formatSampleURL("doc6")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).filter({ $0.contains("crash") || $0.contains("hang") || $0.contains("ofz") }) {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            do {
                let html = try WordDocumentReader.html(from: data, includesPages: true)
                // Whatever it read is a document, never text outside the markup.
                if let html { XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), name) }
            } catch is TextutilConverter.Failure {
                // "This document could not be read": the sentence a listener can act on.
            } catch is PasswordProtectedDocument {
            } catch is DocumentTooLargeError {
            } catch is FileImportError {
            } catch {
                XCTFail("\(name): unexpected error \(type(of: error))")
            }
        }
    }

    // MARK: - Damage

    func testRealAndBuiltDocumentsCutShortAtManyLengthsReadOrThrowAtOnce() throws {
        for (name, stream) in try realStreams() + builtStreams() {
            var lengths = Set(stride(from: 0, to: min(stream.count, 0x200), by: 7))
            lengths.formUnion(stride(from: 0, to: stream.count, by: max(1, stream.count / 60)))
            for length in lengths.sorted() {
                XCTAssertLessThan(read(file(holding: Array(stream.prefix(length)))), limit, "\(name) cut at \(length)")
            }
        }
    }

    func testEveryFieldOfTheFibPointedPastTheEndOrSetToTheLargestReadsOrThrowsAtOnce() throws {
        for (name, stream) in try realStreams() + builtStreams() {
            for offset in stride(from: 0x18, to: min(0x170, stream.count - 4), by: 4) {
                for value in [0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, stream.count, stream.count - 1, 0] as [Int] {
                    var damaged = stream
                    damaged.replaceSubrange(offset..<offset + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
                    XCTAssertLessThan(read(file(holding: damaged)), limit, "\(name): field at \(String(offset, radix: 16)) = \(value)")
                }
            }
        }
    }

    func testRandomByteFlipsOfRealAndBuiltDocumentsReadOrThrowAtOnce() throws {
        var generator = SeededGenerator(state: 0x6F66_6669_6365)
        for (name, stream) in try realStreams() + builtStreams() {
            for round in 0..<120 {
                var damaged = stream
                for _ in 0..<(1 + round % 4) {
                    damaged[Int(generator.next() % UInt64(damaged.count))] = UInt8(truncatingIfNeeded: generator.next())
                }
                XCTAssertLessThan(read(file(holding: damaged)), limit, "\(name), round \(round)")
            }
        }
    }

    func testEveryPageOfPropertiesFilledWithTheLargestNumbersReadsOrThrowsAtOnce() throws {
        // The runs of every formatted page set to 0xFF: counts, offsets, and sizes at their largest.
        for (name, stream) in try builtStreams() {
            for page in 2..<min(stream.count / 512, 12) {
                var damaged = stream
                damaged.replaceSubrange(page * 512..<(page + 1) * 512, with: [UInt8](repeating: 0xFF, count: 512))
                XCTAssertLessThan(read(file(holding: damaged)), limit, "\(name), page \(page)")
            }
        }
    }

    // MARK: - Styles

    func testAStyleSheetThatLoopsOrChainsThousandsDeepReadsAtOnce() throws {
        var builder = Builder()
        // 3000 styles, each based on the next, the last on the first of them: a loop as long as the sheet.
        let first = builder.styles.count
        for index in 0..<3000 {
            builder.styles.append(Builder.Style(sti: 100, basedOn: first + (index + 1) % 3000, name: "s\(index)"))
        }
        builder.paragraphs = (0..<50).map { Paragraph("paragraph \($0)", style: first + $0 * 50) }
        let data = builder.build()
        XCTAssertLessThan(read(data), limit)
        XCTAssertNotNil(try WordDocumentReader.html(from: data, includesPages: true))
    }

    // MARK: - Growth

    /// The fastest of three reads of `data`.
    private func fastest(_ data: Data) -> TimeInterval {
        (0..<3).map { _ in read(data, includesPages: false) }.min() ?? 0
    }

    /// Asserts that reading the document `make(4n)` takes less than ten times as long as `make(n)`: a linear
    /// reader takes four times as long, a quadratic one sixteen.
    private func assertLinear(_ small: Int, _ what: String, _ make: (Int) -> Data, file: StaticString = #filePath, line: UInt = #line) {
        let little = make(small)
        let large = make(small * 4)
        let shortTime = max(fastest(little), 0.005)
        let longTime = fastest(large)
        XCTAssertLessThan(longTime, 10 * shortTime + 0.05, "\(what): \(small) took \(shortTime) s, \(small * 4) took \(longTime) s", file: file, line: line)
        XCTAssertLessThan(longTime, 5.0, what, file: file, line: line)
    }

    func testManyParagraphsAndRunsGrowInStep() {
        assertLinear(1000, "paragraphs") { count in
            var builder = Builder()
            builder.paragraphs = (0..<count).map { index in
                Paragraph(runs: [Run("word "), Run("bold ", sprms: Builder.bold()), Run("\(index)")], style: index % 4)
            }
            return builder.build()
        }
    }

    func testAStyleChainWalkedByEveryParagraphGrowsInStep() {
        assertLinear(400, "a chain of styles") { length in
            var builder = Builder()
            let first = builder.styles.count
            for index in 0..<length {
                builder.styles.append(Builder.Style(sti: 100, basedOn: index == 0 ? 0 : first + index - 1, name: "s\(index)",
                                                   characterSprms: index % 2 == 0 ? Builder.bold() : []))
            }
            builder.paragraphs = (0..<length).map { Paragraph("paragraph \($0)", style: first + $0) }
            return builder.build()
        }
    }

    func testManyNotesGrowInStep() {
        assertLinear(150, "footnotes") { count in
            var builder = Builder()
            builder.paragraphs = (0..<count).map { _ in Paragraph(runs: [Run("text"), Run("\u{02}", sprms: Builder.sprm(117, [1]))]) }
            builder.footnotes = (0..<count).map { "\u{02}Note \($0)." }
            return builder.build()
        }
    }

    func testManyPiecesOfAFastSavedDocumentGrowInStep() {
        // Every character a run of its own: as many runs as characters, each placed through the piece table.
        assertLinear(300, "runs in a fast-saved document") { count in
            var builder = Builder()
            builder.isFastSaved = true
            builder.paragraphs = [Paragraph(runs: (0..<count).map { Run("x", sprms: $0 % 2 == 0 ? Builder.bold() : []) })]
            return builder.build()
        }
    }

    // MARK: - Cancellation

    func testACancelledReadStopsInBothLayouts() throws {
        var old = Builder()
        old.paragraphs = [Paragraph("old")]
        var modern = WordDocumentBuilder()
        modern.paragraphs = [WordDocumentBuilder.Paragraph("modern")]
        for data in [old.build(), modern.build()] {
            let cancellation = ImportCancellation()
            cancellation.cancel()
            XCTAssertThrowsError(try ImportCancellation.$current.withValue(cancellation) {
                try WordDocumentReader.html(from: data, includesPages: false)
            }) { XCTAssertEqual($0 as? ImportCancelled, ImportCancelled()) }
            // Not cancelled, the same document reads.
            XCTAssertNotNil(try ImportCancellation.$current.withValue(ImportCancellation()) {
                try WordDocumentReader.html(from: data, includesPages: false)
            })
        }
    }
}
