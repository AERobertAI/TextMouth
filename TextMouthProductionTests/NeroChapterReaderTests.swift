import AVFoundation
import XCTest
@testable import TextMouth

/// `NeroChapterReader` reads a Nero `chpl` chapter list from an MPEG-4 file's
/// own bytes, and `AudioPlaybackService.extractChapters` falls back to it when
/// AVFoundation finds no chapters. The synthetic files here are boxes written
/// by `BoxWriter`; the real sample is copied into the test's own folder first,
/// and the samples' folder is never changed. No test plays sound.
final class NeroChapterReaderTests: XCTestCase {
    /// A folder of the test's own, removed when the test ends.
    private var folder: URL! // lint-ok: set in setUp, guarded in tearDown, as the other audio tests do

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Helpers

    /// Writes MPEG-4 boxes and `chpl` payloads as bytes.
    private enum BoxWriter {
        /// `value` as big-endian bytes.
        static func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            (0..<MemoryLayout<T>.size).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }

        /// A box with a 32-bit size; `declaredSize` overrides the true size.
        static func box(_ type: String, _ payload: [UInt8] = [], declaredSize: UInt32? = nil) -> [UInt8] {
            be(declaredSize ?? UInt32(8 + payload.count)) + Array(type.utf8) + payload
        }

        /// A box with the 64-bit size form (size field 1, then the true size).
        static func largeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            be(UInt32(1)) + Array(type.utf8) + be(UInt64(16 + payload.count)) + payload
        }

        /// A box whose size field is 0: it runs to the end of its parent.
        static func openEndedBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            box(type, payload, declaredSize: 0)
        }

        /// One chapter as a `chpl` payload holds it.
        static func entry(start seconds: Double, title: [UInt8]) -> [UInt8] {
            be(UInt64(seconds * 10_000_000)) + [UInt8(title.count)] + title
        }

        /// A `chpl` payload: version and flags, four reserved bytes when the
        /// version is not 0, the count (`count` overrides the true one), and
        /// the entries.
        static func chplPayload(version: UInt8 = 0, count: UInt8? = nil, entries: [[UInt8]]) -> [UInt8] {
            var bytes: [UInt8] = [version, 0, 0, 0]
            if version != 0 { bytes += [0, 0, 0, 0] }
            bytes.append(count ?? UInt8(entries.count))
            return bytes + entries.flatMap { $0 }
        }

        /// A `moov` holding a `udta` holding a `chpl` box of `payload`.
        static func moov(chpl payload: [UInt8]) -> [UInt8] {
            box("moov", box("udta", box("chpl", payload)))
        }

        /// The `ftyp` box every test file starts with.
        static var ftyp: [UInt8] { box("ftyp", Array("M4B ".utf8)) }

        /// A minimal file: `ftyp`, then `moov` holding `udta` holding the payload.
        static func file(chpl payload: [UInt8]) -> [UInt8] {
            ftyp + moov(chpl: payload)
        }
    }

    /// Writes `bytes` to a new file in the test's folder and returns its URL.
    private func write(_ bytes: [UInt8], name: String = "book.m4b") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The reader's chapters for a file made of `bytes`.
    private func chapters(of bytes: [UInt8]) throws -> [NeroChapterReader.Chapter] {
        NeroChapterReader.read(at: try write(bytes))
    }

    /// Two chapters, "One" at 0 and "Two" at 2.5 seconds.
    private var twoEntries: [[UInt8]] {
        [BoxWriter.entry(start: 0, title: Array("One".utf8)),
         BoxWriter.entry(start: 2.5, title: Array("Two".utf8))]
    }

    private let expectedTwo = [NeroChapterReader.Chapter(title: "One", start: 0),
                               NeroChapterReader.Chapter(title: "Two", start: 2.5)]

    // MARK: - The payload

    /// A version 0 payload gives its chapters.
    func testVersionZeroPayload() throws {
        let payload = BoxWriter.chplPayload(version: 0, entries: twoEntries)
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), expectedTwo)
        XCTAssertEqual(try chapters(of: BoxWriter.file(chpl: payload)), expectedTwo)
    }

    /// A version 1 payload carries four reserved bytes more before the count.
    func testVersionOnePayload() throws {
        let payload = BoxWriter.chplPayload(version: 1, entries: twoEntries)
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), expectedTwo)
        XCTAssertEqual(try chapters(of: BoxWriter.file(chpl: payload)), expectedTwo)
    }

    /// An empty or tiny payload has no chapters and does not trap.
    func testTinyPayloadsGiveNothing() {
        let payloads: [[UInt8]] = [[], [0], [0, 0, 0], [0, 0, 0, 0], [1, 0, 0, 0, 0, 0, 0, 0]]
        for payload in payloads {
            XCTAssertEqual(NeroChapterReader.parse(chpl: payload), [], "payload \(payload)")
        }
    }

    /// A payload cut partway keeps the chapters read whole before the cut.
    func testTruncatedPayloadKeepsWholeChapters() {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        let firstOnly = Array(expectedTwo.prefix(1))
        // Cut inside the second title, then inside the second start.
        XCTAssertEqual(NeroChapterReader.parse(chpl: Array(payload.dropLast(1))), firstOnly)
        XCTAssertEqual(NeroChapterReader.parse(chpl: Array(payload.dropLast(10))), firstOnly)
        // Cut right after the count.
        XCTAssertEqual(NeroChapterReader.parse(chpl: Array(payload.prefix(5))), [])
    }

    /// A count of 255 with only two chapters present gives the two.
    func testCountLargerThanTheChaptersPresent() {
        let payload = BoxWriter.chplPayload(count: 255, entries: twoEntries)
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), expectedTwo)
    }

    /// A title that is not valid UTF-8 is read as Windows-1252, which agrees
    /// with ISO Latin 1 outside 0x80 through 0x9F.
    func testLatinOneTitle() {
        let payload = BoxWriter.chplPayload(entries: [BoxWriter.entry(start: 1, title: [0x43, 0x61, 0x66, 0xE9])])
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), [.init(title: "Café", start: 1)])
    }

    /// The bytes 0x93 and 0x94 are the curly double quotes of Windows-1252
    /// (not the control characters ISO Latin 1 gives them).
    func testWindowsQuotesInAnInvalidUTF8Title() {
        let payload = BoxWriter.chplPayload(entries: [BoxWriter.entry(start: 1, title: [0x93, 0x48, 0x69, 0x94])])
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), [.init(title: "\u{201C}Hi\u{201D}", start: 1)])
    }

    /// A title stops at its first NUL byte; what follows is not part of it.
    func testTitleStopsAtItsFirstNUL() {
        let payload = BoxWriter.chplPayload(entries: [
            BoxWriter.entry(start: 0, title: [0x41, 0x00, 0x42]),
            // A NUL first leaves nothing, and the next chapter is still read.
            BoxWriter.entry(start: 1, title: [0x00, 0x43]),
            // The same holds for a title that is not valid UTF-8.
            BoxWriter.entry(start: 2, title: [0x43, 0x61, 0x66, 0xE9, 0x00, 0x44])])
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload).map(\.title), ["A", "", "Café"])
    }

    /// A UTF-8 title is read as UTF-8.
    func testUTF8Title() {
        let payload = BoxWriter.chplPayload(entries: [BoxWriter.entry(start: 1, title: Array("Café".utf8))])
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload), [.init(title: "Café", start: 1)])
    }

    /// White space and NUL characters are trimmed; an empty title stays empty.
    func testTitlesAreTrimmedAndEmptyStaysEmpty() {
        let payload = BoxWriter.chplPayload(entries: [
            BoxWriter.entry(start: 0, title: Array("  Intro \n".utf8) + [0, 0]),
            BoxWriter.entry(start: 1, title: []),
            BoxWriter.entry(start: 2, title: [0, 0, 0x20])])
        XCTAssertEqual(NeroChapterReader.parse(chpl: payload).map(\.title), ["Intro", "", ""])
    }

    // MARK: - The box walk

    /// A file with no `moov`, no `udta`, or no `chpl` has no chapters.
    func testMissingBoxesGiveNothing() throws {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        XCTAssertEqual(try chapters(of: BoxWriter.ftyp), [])
        XCTAssertEqual(try chapters(of: BoxWriter.box("moov", BoxWriter.box("trak"))), [])
        XCTAssertEqual(try chapters(of: BoxWriter.box("moov", BoxWriter.box("udta", BoxWriter.box("meta")))), [])
        // A chpl directly in moov (not in udta) is not the Nero list.
        XCTAssertEqual(try chapters(of: BoxWriter.box("moov", BoxWriter.box("chpl", payload))), [])
    }

    /// A missing, empty, or non-MPEG-4 file has no chapters.
    func testUnreadableFilesGiveNothing() throws {
        XCTAssertEqual(NeroChapterReader.read(at: folder.appendingPathComponent("absent.m4b")), [])
        XCTAssertEqual(try chapters(of: []), [])
        XCTAssertEqual(try chapters(of: Array("not an mpeg-4 file at all".utf8)), [])
    }

    /// A box with the 64-bit size form is walked.
    func testSixtyFourBitBoxSize() throws {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        let bytes = BoxWriter.ftyp
            + BoxWriter.largeBox("moov", BoxWriter.largeBox("udta", BoxWriter.largeBox("chpl", payload)))
        XCTAssertEqual(try chapters(of: bytes), expectedTwo)
    }

    /// A last box of size 0 runs to the end of the file (and of its parent).
    func testBoxOfSizeZeroRunsToTheEnd() throws {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        let udta = BoxWriter.openEndedBox("udta", BoxWriter.box("chpl", payload))
        let bytes = BoxWriter.ftyp + BoxWriter.openEndedBox("moov", udta)
        XCTAssertEqual(try chapters(of: bytes), expectedTwo)
    }

    /// `moov` after a huge `mdat` is found by seeking: the file is sparse, and
    /// the `mdat` is larger than a 32-bit size can hold.
    func testMoovAfterAHugeMediaBox() throws {
        let mediaLength: UInt64 = 5 * 1_024 * 1_024 * 1_024
        let url = folder.appendingPathComponent("huge.m4b")
        let head = BoxWriter.ftyp + BoxWriter.be(UInt32(1)) + Array("mdat".utf8) + BoxWriter.be(16 + mediaLength)
        try Data(head).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Extend the file to the end of the mdat (a hole, taking no space).
        try handle.truncate(atOffset: UInt64(BoxWriter.ftyp.count) + 16 + mediaLength)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(BoxWriter.moov(chpl: BoxWriter.chplPayload(entries: twoEntries))))
        try handle.synchronize()

        XCTAssertEqual(NeroChapterReader.read(at: url), expectedTwo)
    }

    /// A size smaller than the box's own header stops the walk.
    func testSizeSmallerThanItsHeaderStopsTheWalk() throws {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        for size: UInt32 in [2, 7] {
            let bytes = BoxWriter.ftyp + BoxWriter.box("free", declaredSize: size) + BoxWriter.moov(chpl: payload)
            XCTAssertEqual(try chapters(of: bytes), [], "size \(size)")
        }
        // A 64-bit size smaller than its 16-byte header.
        let small = BoxWriter.be(UInt32(1)) + Array("free".utf8) + BoxWriter.be(UInt64(12))
        XCTAssertEqual(try chapters(of: small + BoxWriter.file(chpl: payload)), [])
    }

    /// A box that runs past its parent stops the walk.
    func testBoxRunningPastItsParentStopsTheWalk() throws {
        let payload = BoxWriter.chplPayload(entries: twoEntries)
        // The udta claims more than the moov holds.
        let longUdta = BoxWriter.box("udta", BoxWriter.box("chpl", payload), declaredSize: 5_000)
        XCTAssertEqual(try chapters(of: BoxWriter.box("moov", longUdta)), [])
        // The chpl claims more than the udta holds.
        let longChpl = BoxWriter.box("chpl", payload, declaredSize: 5_000)
        XCTAssertEqual(try chapters(of: BoxWriter.box("moov", BoxWriter.box("udta", longChpl))), [])
        // The moov claims more than the file holds.
        let longMoov = BoxWriter.box("moov", BoxWriter.box("udta", BoxWriter.box("chpl", payload)),
                                     declaredSize: 5_000)
        XCTAssertEqual(try chapters(of: longMoov), [])
    }

    /// A header cut off at the end of the parent stops the walk quietly.
    func testHeaderCutOffAtTheEnd() throws {
        XCTAssertEqual(try chapters(of: BoxWriter.ftyp + [0, 0, 0]), [])
    }

    /// Only 10,000 boxes are looked at on a level: a `moov` after more is not found.
    func testBoxCountOnALevelIsCapped() throws {
        let moov = BoxWriter.moov(chpl: BoxWriter.chplPayload(entries: twoEntries))
        let filler = BoxWriter.box("free")
        let within = [UInt8](Array(repeating: filler, count: NeroChapterReader.maxBoxesPerLevel - 1).joined()) + moov
        XCTAssertEqual(try chapters(of: within), expectedTwo)
        let beyond = [UInt8](Array(repeating: filler, count: NeroChapterReader.maxBoxesPerLevel).joined()) + moov
        XCTAssertEqual(try chapters(of: beyond), [])
    }

    /// A `chpl` payload over 1 MiB is refused; one at the limit is read.
    func testOversizedPayloadIsRefused() throws {
        let entries = [BoxWriter.entry(start: 0, title: Array("One".utf8))]
        let base = BoxWriter.chplPayload(entries: entries)
        let limit = Int(NeroChapterReader.maxPayloadLength)
        let over = base + [UInt8](repeating: 0, count: limit)
        XCTAssertEqual(try chapters(of: BoxWriter.file(chpl: over)), [])
        let exact = base + [UInt8](repeating: 0, count: limit - base.count)
        XCTAssertEqual(try chapters(of: BoxWriter.file(chpl: exact)), [.init(title: "One", start: 0)])
    }

    // MARK: - The book's chapters

    /// Chapters are sorted by start, a start past the end is dropped, and a
    /// repeated start is dropped; each lasts until the next, the last to the end.
    func testBookChaptersAreSortedAndBounded() {
        let list: [NeroChapterReader.Chapter] = [
            .init(title: "C", start: 6), .init(title: "A", start: 0), .init(title: "Late", start: 12),
            .init(title: "B", start: 3), .init(title: "B again", start: 3), .init(title: "Edge", start: 10)]
        let book = NeroChapterReader.bookChapters(from: list, fileDuration: 10)
        XCTAssertEqual(book.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(book.map(\.startTime), [0, 3, 6])
        XCTAssertEqual(book.map(\.duration), [3, 3, 4])
    }

    /// Equal starts keep the file's order, so the first one is the one taken.
    func testRepeatedStartKeepsTheFirstInFileOrder() {
        let list: [NeroChapterReader.Chapter] = [.init(title: "First", start: 2), .init(title: "Second", start: 2)]
        XCTAssertEqual(NeroChapterReader.bookChapters(from: list, fileDuration: 5).map(\.title), ["First"])
    }

    /// The first chapter begins at 0 even when its start is later, so the
    /// chapters cover the whole file.
    func testFirstChapterBeginsAtZero() {
        let list: [NeroChapterReader.Chapter] = [.init(title: "A", start: 1.5), .init(title: "B", start: 4)]
        let book = NeroChapterReader.bookChapters(from: list, fileDuration: 9)
        XCTAssertEqual(book.map(\.startTime), [0, 4])
        XCTAssertEqual(book.map(\.duration), [4, 5])
        XCTAssertEqual(book.reduce(0) { $0 + $1.duration }, 9, accuracy: 0.0001)
    }

    /// An empty title becomes "Chapter N", N being the place from 1.
    func testEmptyTitleBecomesChapterNumber() {
        let list: [NeroChapterReader.Chapter] = [.init(title: "", start: 0), .init(title: "Named", start: 1),
                                                 .init(title: "", start: 2)]
        XCTAssertEqual(NeroChapterReader.bookChapters(from: list, fileDuration: 3).map(\.title),
                       ["Chapter 1", "Named", "Chapter 3"])
    }

    /// No chapters, or none left after dropping, gives none.
    func testNothingLeftGivesNothing() {
        XCTAssertTrue(NeroChapterReader.bookChapters(from: [], fileDuration: 5).isEmpty)
        XCTAssertTrue(NeroChapterReader.bookChapters(from: [.init(title: "X", start: 9)], fileDuration: 5).isEmpty)
        // Without the file's length, no chapter's end is known: none.
        for unknown in [0, -1, .nan, .infinity] as [TimeInterval] {
            XCTAssertTrue(NeroChapterReader.bookChapters(from: [.init(title: "X", start: 1)], fileDuration: unknown).isEmpty)
        }
    }

    // MARK: - The real sample

    /// The three titles and starts of `three-tones.m4b`'s `chpl` atom, read
    /// once from the file's bytes (0, 1.5, and 3.0 seconds).
    private let sampleChapters = [NeroChapterReader.Chapter(title: "Tone 440 Hz", start: 0),
                                  NeroChapterReader.Chapter(title: "Tone 660 Hz - second", start: 1.5),
                                  NeroChapterReader.Chapter(title: "Tone 880 Hz (café)", start: 3.0)]

    /// A copy of the sample in the test's folder (the samples' folder is
    /// never changed), with `edit` applied to its bytes.
    private func sampleCopy(named name: String, edit: (inout Data) throws -> Void = { _ in }) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples/m4b-chapters/three-tones.m4b")
        var bytes = try Data(contentsOf: source)
        try edit(&bytes)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Renames the audio track's chapter reference: the `chap` inside `tref`
    /// becomes `xxxx`, so AVFoundation finds no chapter track.
    private func hideChapterTrack(_ bytes: inout Data) throws {
        let tref = try XCTUnwrap(bytes.range(of: Data("tref".utf8)), "the sample has no tref")
        let chap = try XCTUnwrap(bytes.range(of: Data("chap".utf8), in: tref.lowerBound..<bytes.endIndex),
                                 "no chap inside tref")
        // The reference must lie inside the tref box (its 20 bytes).
        XCTAssertLessThan(chap.lowerBound - tref.lowerBound, 20)
        bytes.replaceSubrange(chap, with: Data("xxxx".utf8))
    }

    /// The reader finds the sample's three chapters.
    func testSampleChapters() throws {
        let url = try sampleCopy(named: "three-tones.m4b")
        XCTAssertEqual(NeroChapterReader.read(at: url), sampleChapters)
    }

    /// With the chapter track intact, `extractChapters` gives AVFoundation's.
    func testExtractChaptersUsesTheChapterTrackWhenThereIsOne() async throws {
        let url = try sampleCopy(named: "three-tones.m4b")
        let book = await AudioPlaybackService.extractChapters(from: url)
        XCTAssertEqual(book.count, 3)
        for (chapter, expected) in zip(book, sampleChapters) {
            XCTAssertEqual(chapter.startTime, expected.start, accuracy: 0.05)
            XCTAssertEqual(chapter.title, expected.title)
        }
    }

    /// With the chapter track hidden, `extractChapters` falls back to `chpl`:
    /// the same titles and starts, lasting to the file's end.
    func testExtractChaptersFallsBackToTheNeroList() async throws {
        let url = try sampleCopy(named: "no-track.m4b", edit: hideChapterTrack)
        let book = await AudioPlaybackService.extractChapters(from: url)
        XCTAssertEqual(book.map(\.title), sampleChapters.map(\.title))
        XCTAssertEqual(book.count, 3)
        for (chapter, expected) in zip(book, sampleChapters) {
            XCTAssertEqual(chapter.startTime, expected.start, accuracy: 0.01)
        }
        let asset = try XCTUnwrap(AudioPlaybackService.metadataAsset(for: url))
        let length = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertEqual(book.reduce(0) { $0 + $1.duration }, length, accuracy: 0.01)
    }

    /// The fallback applies to the extension in any case, and not to others.
    func testFallbackFollowsTheExtension() async throws {
        let upper = try sampleCopy(named: "NO-TRACK.M4B", edit: hideChapterTrack)
        let upperBook = await AudioPlaybackService.extractChapters(from: upper)
        XCTAssertEqual(upperBook.count, 3)
        // The same bytes under an extension outside the MPEG-4 list get no fallback.
        let other = try sampleCopy(named: "no-track.dat", edit: hideChapterTrack)
        let otherBook = await AudioPlaybackService.extractChapters(from: other)
        XCTAssertTrue(otherBook.isEmpty)
    }
}
