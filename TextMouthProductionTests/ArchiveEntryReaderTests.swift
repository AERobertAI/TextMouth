import XCTest
import ZIPFoundation
@testable import TextMouth

/// Every reader takes an entry out of a book's archive through one helper,
/// `ArchiveEntryReader`, which refuses an entry larger than the most
/// TextMouth reads from one file and stops at the first excess chunk of an
/// entry whose recorded size lies (TODO I05). Each reader names such an
/// entry in its own damage sentence. Tests bind small limits, so their
/// fixtures stay a few kilobytes.
final class ArchiveEntryReaderTests: XCTestCase {

    // MARK: - Limits

    /// The documented limits: 256 MB for an audio file and 64 MB for any
    /// other entry, chosen by the entry's extension without regard to case.
    func testStandardLimitsFollowTheEntryKind() {
        let limits = ArchiveEntryLimits.standard

        XCTAssertEqual(limits.audio, 256_000_000)
        XCTAssertEqual(limits.text, 64_000_000)
        XCTAssertEqual(limits.limit(forEntryAt: "Harbor/part1.MP3"), limits.audio)
        XCTAssertEqual(limits.limit(forEntryAt: "audio/track.ogg"), limits.audio)
        XCTAssertEqual(limits.limit(forEntryAt: "OEBPS/ch01.xhtml"), limits.text)
        XCTAssertEqual(limits.limit(forEntryAt: "ncc.html"), limits.text)
        XCTAssertEqual(ArchiveEntryLimits.current, .standard)
    }

    /// Limits a test binds apply only inside the operation that binds them.
    func testBoundLimitsApplyOnlyInsideTheirOperation() {
        let small = ArchiveEntryLimits(audio: 10, text: 5)

        ArchiveEntryLimits.$current.withValue(small) {
            XCTAssertEqual(ArchiveEntryLimits.current, small)
        }
        XCTAssertEqual(ArchiveEntryLimits.current, .standard)
    }

    // MARK: - Reading Into Memory

    /// An entry within its limit reads whole, stored or compressed, with the
    /// checksum of its bytes.
    func testEntryWithinItsLimitReadsWholeWithItsChecksum() throws {
        let text = Data(String(repeating: "Keep the chain clean and lightly oiled. ", count: 200).utf8)
        for method in [CompressionMethod.none, .deflate] {
            let archive = try openArchive(["notes.txt": text], compression: method)
            let entry = try XCTUnwrap(archive["notes.txt"])

            let read = try ArchiveEntryReader.read(entry, in: archive, limit: Int64(text.count))

            XCTAssertEqual(read.data, text, "\(method)")
            XCTAssertEqual(read.checksum, entry.checksum, "\(method)")
        }
    }

    /// An entry that declares more than the limit is refused before any of
    /// it is read, and named with the limit in the sentence every format's
    /// damage report uses.
    func testEntryDeclaringMoreThanTheLimitIsRefused() throws {
        let archive = try openArchive(["Spokes/lacing.xhtml": Data(repeating: 0x41, count: 2_000)])
        let entry = try XCTUnwrap(archive["Spokes/lacing.xhtml"])

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, limit: 1_000)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "Spokes/lacing.xhtml", limit: 1_000))
            XCTAssertEqual(
                error.localizedDescription,
                "The file “Spokes/lacing.xhtml” in this archive is damaged or incomplete: it holds more than "
                    + "\(ArchiveFigures.size(1_000)), the most TextMouth reads from one file. "
                    + "Get a fresh copy of the archive, then import it again."
            )
        }
    }

    /// Without a limit given, the reader takes the current limit for the
    /// entry's kind: the audio limit for audio, the text limit otherwise.
    func testDefaultLimitIsTheCurrentOneForTheEntryKind() throws {
        let archive = try openArchive(["track.mp3": Data(count: 300), "page.xhtml": Data(count: 300)])

        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: 400, text: 200)) {
            let track = try XCTUnwrap(archive["track.mp3"])
            XCTAssertEqual(try ArchiveEntryReader.read(track, in: archive).data.count, 300)
            let page = try XCTUnwrap(archive["page.xhtml"])
            XCTAssertThrowsError(try ArchiveEntryReader.read(page, in: archive)) { error in
                XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "page.xhtml", limit: 200))
            }
        }
    }

    /// An entry whose recorded size lies, tiny on record but large once
    /// inflated, stops at the reader's limit instead of being read whole.
    func testLyingEntryStopsAtTheLimit() throws {
        let archive = try openLyingArchive(member: "flood.xhtml", actualSize: 200_000, recordedSize: 10)
        let entry = try XCTUnwrap(archive["flood.xhtml"])
        XCTAssertEqual(entry.uncompressedSize, 10, "the fixture must lie about its size")

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, limit: 50_000)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "flood.xhtml", limit: 50_000))
        }
    }

    /// An import holds an entry to the size the archive records for it: the
    /// lying entry is refused, naming that size, however generous the limit.
    func testImportHoldsAnEntryToItsRecordedSize() throws {
        let archive = try openLyingArchive(member: "flood.xhtml", actualSize: 200_000, recordedSize: 10)
        let entry = try XCTUnwrap(archive["flood.xhtml"])

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, holdingToDeclaredSize: true)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastDeclaredSize(path: "flood.xhtml", declared: 10))
            XCTAssertEqual(
                error.localizedDescription,
                "The file “flood.xhtml” in this archive is damaged or incomplete: it holds more than the "
                    + "\(ArchiveFigures.size(10)) the archive records for it. "
                    + "Get a fresh copy of the archive, then import it again."
            )
        }
    }

    // MARK: - Streaming

    /// Streaming hands on no byte past the recorded size: the consumer gets
    /// what fits, then the stream stops with the entry named.
    func testStreamHandsOnNothingPastTheRecordedSize() throws {
        let archive = try openLyingArchive(member: "flood.txt", actualSize: 200_000, recordedSize: 20_000)
        let entry = try XCTUnwrap(archive["flood.txt"])
        var received = 0

        XCTAssertThrowsError(try ArchiveEntryReader.stream(entry, in: archive) { received += $0.count }) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastDeclaredSize(path: "flood.txt", declared: 20_000))
        }
        XCTAssertGreaterThan(received, 0)
        XCTAssertLessThanOrEqual(received, 20_000)
    }

    /// An honest entry streams whole, with the checksum the archive stores.
    func testStreamOfAnHonestEntryDeliversEveryByte() throws {
        let text = Data(String(repeating: "True the wheel a quarter turn at a time. ", count: 2_000).utf8)
        let archive = try openArchive(["truing.txt": text], compression: .deflate)
        let entry = try XCTUnwrap(archive["truing.txt"])
        var received = Data()

        let checksum = try ArchiveEntryReader.stream(entry, in: archive) { received.append($0) }

        XCTAssertEqual(received, text)
        XCTAssertEqual(checksum, entry.checksum)
    }

    // MARK: - Fixtures

    /// An archive holding `entries`, opened for reading. Its file is removed
    /// when the test ends.
    private func openArchive(_ entries: [String: Data], compression: CompressionMethod = .none) throws -> Archive {
        let url = try makeTemporaryZip(prefix: "ArchiveEntryReaderTests", entries: entries, compressionMethod: compression)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Archive(url: url, accessMode: .read)
    }

    /// An archive holding `member`: `actualSize` bytes that compress to
    /// almost nothing, whose headers record only `recordedSize`, opened for
    /// reading. Its file is removed when the test ends.
    private func openLyingArchive(member: String, actualSize: Int, recordedSize: UInt32) throws -> Archive {
        let url = try makeTemporaryZip(
            prefix: "ArchiveEntryReaderLie",
            entries: [member: Data(repeating: 0x61, count: actualSize)],
            compressionMethod: .deflate
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try setRecordedSize(of: member, in: url, to: recordedSize)
        return try Archive(url: url, accessMode: .read)
    }
}
