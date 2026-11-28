import XCTest
@testable import TextMouth

/// The compound file reader (`CompoundFile`, FMT47): the real Word samples,
/// files built in code at the edges of the format (the 4096-byte cutoff
/// between the mini stream and the FAT, version 4, more FAT sectors than the
/// header holds), and hostile files, each of which must end the read with
/// `OLEDamage`, never a crash, and in well under a second.
final class CompoundFileTests: XCTestCase {

    // MARK: - Helpers

    /// A stream of `count` bytes that differ from place to place, so a read
    /// of the wrong sector shows.
    private func pattern(_ count: Int, seed: Int = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ ($0 >> 8) &+ seed) }
    }

    /// Opens `data` and reads every stream in its root, returning them by name.
    private func readAll(_ data: Data) throws -> [String: Data] {
        let file = try CompoundFile(data)
        var streams: [String: Data] = [:]
        for entry in file.rootEntries where entry.isStream {
            streams[entry.name] = try file.stream(named: entry.name)
        }
        return streams
    }

    /// Asserts that reading `data` ends with `OLEDamage` in under a second.
    private func assertDamaged(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertThrowsError(try readAll(data), message, file: file, line: line) { error in
            XCTAssertTrue(error is OLEDamage, "\(message): \(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, message, file: file, line: line)
    }

    /// Asserts that reading `data` either succeeds or ends with `OLEDamage`,
    /// in under a second: the contract for any damaged file.
    private func assertSurvives(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        do { _ = try readAll(data) } catch {
            XCTAssertTrue(error is OLEDamage, "\(message): \(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, message, file: file, line: line)
    }

    /// A built file with a small, a medium, and a large stream.
    private func threeStreams(sectorShift: Int = 9) -> (data: Data, layout: CompoundFileBuilder.Layout, streams: [(name: String, data: [UInt8])]) {
        var builder = CompoundFileBuilder()
        builder.sectorShift = sectorShift
        builder.streams = [("Small", pattern(100)), ("Medium", pattern(5000, seed: 2)), ("Large", pattern(70_000, seed: 3))]
        let built = builder.build()
        return (built.data, built.layout, builder.streams)
    }

    // MARK: - The Samples

    func testTheWordSamplesHoldTheStreamsAWordDocumentNeeds() throws {
        let samples = [
            "doc/headings.doc", "doc/libreoffice-tdf104239_chapterNumbering.doc",
            "doc/libreoffice-tdf81705_outlineLevel.doc", "doc/page-breaks.doc",
            "dot/headings-synthetic.dot", "dot/libreoffice-tdf120761_zOrder.dot",
        ]
        for sample in samples {
            let bytes = try Data(contentsOf: formatSampleURL(sample))
            let file = try CompoundFile(bytes)
            let word = try XCTUnwrap(file.stream(named: "WordDocument"), sample)
            // The File Information Block begins with wIdent 0xA5EC.
            XCTAssertEqual(Array(word.prefix(2)), [0xEC, 0xA5], sample)
            XCTAssertNotNil(try file.stream(named: "1Table") ?? file.stream(named: "0Table"), sample)
            XCTAssertNotNil(file.entry(named: "\u{05}SummaryInformation"), sample)
        }
    }

    // MARK: - Built Files

    func testEveryStreamComesBackWhole() throws {
        let built = threeStreams()
        let streams = try readAll(built.data)
        for stream in built.streams {
            XCTAssertEqual(Array(try XCTUnwrap(streams[stream.name])), stream.data, stream.name)
        }
    }

    func testStreamsAtTheMiniStreamCutoffAreRead() throws {
        for size in [0, 1, 63, 64, 65, 4095, 4096, 4097, 8191, 8192] {
            var builder = CompoundFileBuilder()
            builder.streams = [("Before", pattern(10)), ("Edge", pattern(size, seed: 9)), ("After", pattern(10, seed: 5))]
            let streams = try readAll(builder.build().data)
            XCTAssertEqual(Array(try XCTUnwrap(streams["Edge"])), pattern(size, seed: 9), "size \(size)")
            XCTAssertEqual(Array(try XCTUnwrap(streams["After"])), pattern(10, seed: 5), "size \(size)")
        }
    }

    func testAVersion4FileWithItsLargerSectorsIsRead() throws {
        let built = threeStreams(sectorShift: 12)
        XCTAssertEqual(built.layout.sectorSize, 4096)
        let streams = try readAll(built.data)
        for stream in built.streams {
            XCTAssertEqual(Array(try XCTUnwrap(streams[stream.name])), stream.data, stream.name)
        }
    }

    func testNamesAreComparedWithoutRegardToCase() throws {
        let file = try CompoundFile(threeStreams().data)
        XCTAssertNotNil(try file.stream(named: "sMALL"))
        XCTAssertNotNil(try file.stream(named: "small"))
        XCTAssertNotNil(try file.stream(named: "LARGE"))
    }

    func testAMissingStreamIsNilNotAnError() throws {
        let file = try CompoundFile(threeStreams().data)
        XCTAssertNil(try file.stream(named: "0Table"))
    }

    func testMoreFATSectorsThanTheHeaderHoldAreReadThroughTheDIFATChain() throws {
        // 109 FAT sectors cover 109 * 128 sectors of 512 bytes; a stream of
        // 7.5 MB needs more, so the FAT's last sectors are named by DIFAT sectors.
        var builder = CompoundFileBuilder()
        let large = pattern(7_500_000, seed: 7)
        builder.streams = [("Huge", large)]
        let built = builder.build()
        XCTAssertGreaterThan(built.layout.fatSectors.count, 109)
        XCTAssertFalse(built.layout.difatSectors.isEmpty)
        XCTAssertEqual(Array(try XCTUnwrap(readAll(built.data)["Huge"])), large)
    }

    // MARK: - Hostile Files

    func testAFileWithoutTheSignatureIsRefused() {
        assertDamaged(Data(repeating: 0, count: 4096), "zeros")
        assertDamaged(Data(), "empty")
        var data = threeStreams().data
        data[0] = 0
        assertDamaged(data, "signature changed")
    }

    func testHeaderFieldsThatDoNotFitAreRefused() {
        let data = threeStreams().data
        assertDamaged(data.patched(at: 26, to: 5, width: 2), "major version 5")
        assertDamaged(data.patched(at: 28, to: 0xFEFF, width: 2), "big-endian marker")
        assertDamaged(data.patched(at: 30, to: 10, width: 2), "sector shift 10")
        assertDamaged(data.patched(at: 30, to: 12, width: 2), "version 3 with 4096-byte sectors")
        assertDamaged(data.patched(at: 32, to: 7, width: 2), "mini sector shift 7")
        assertDamaged(data.patched(at: 56, to: 1000), "mini stream cutoff 1000")
        assertDamaged(data.prefix(300), "ends inside the header")
    }

    func testTruncationAtManyLengthsEndsTheReadCleanly() {
        let built = threeStreams()
        // Every length from the header's end to the file's end, in steps
        // that cross every kind of sector; the FAT is the last sector, so
        // any truncation loses it and every one is refused.
        for length in stride(from: 0, to: built.data.count, by: 997) {
            assertDamaged(built.data.prefix(length), "truncated to \(length)")
        }
        assertDamaged(built.data.prefix(built.data.count - 1), "one byte short")
    }

    func testTruncatedRealSamplesNeverCrash() throws {
        for sample in ["doc/headings.doc", "doc/libreoffice-tdf81705_outlineLevel.doc", "dot/libreoffice-tdf120761_zOrder.dot"] {
            let bytes = try Data(contentsOf: formatSampleURL(sample))
            for length in stride(from: 0, to: bytes.count, by: 331) {
                assertSurvives(bytes.prefix(length), "\(sample) truncated to \(length)")
            }
        }
    }

    func testAFATChainThatLoopsEndsTheRead() {
        let built = threeStreams()
        let large = built.layout.startSectors["Large"] ?? 0
        // The large stream's first sector points at itself.
        let looped = built.data.patched(at: built.layout.offset(ofFATEntryFor: large), to: large)
        assertDamaged(looped, "a sector that follows itself")
        // And a loop of two.
        let second = large + 1
        let two = built.data
            .patched(at: built.layout.offset(ofFATEntryFor: large), to: second)
            .patched(at: built.layout.offset(ofFATEntryFor: second), to: large)
        assertDamaged(two, "two sectors that follow each other")
    }

    func testASectorIndexPastTheEndEndsTheRead() {
        let built = threeStreams()
        let large = built.layout.startSectors["Large"] ?? 0
        let entry = built.layout.offset(ofDirectoryEntry: 3)
        // The directory entry's first sector, and the FAT's next sector.
        assertDamaged(built.data.patched(at: entry + 116, to: 0x7FFF_FFFF), "start sector far past the end")
        assertDamaged(built.data.patched(at: entry + 116, to: 0xFFFF_FFFA), "start sector 0xFFFFFFFA")
        assertDamaged(built.data.patched(at: built.layout.offset(ofFATEntryFor: large), to: 0x00FF_FFFF), "FAT entry past the end")
        assertDamaged(built.data.patched(at: built.layout.offset(ofFATEntryFor: large), to: 0xFFFF_FFFF), "a free sector inside a chain")
        assertDamaged(built.data.patched(at: 48, to: 0x00FF_FFFF), "the directory starts past the end")
        assertDamaged(built.data.patched(at: 76, to: 0x00FF_FFFF), "a FAT sector past the end")
    }

    func testAnEntrySizeOfFFFFFFFFEndsTheRead() {
        let built = threeStreams()
        for index in 1...3 {
            let entry = built.layout.offset(ofDirectoryEntry: index)
            assertDamaged(built.data.patched(at: entry + 120, to: 0xFFFF_FFFF), "entry \(index) of 0xFFFFFFFF bytes")
            assertDamaged(built.data.patched(at: entry + 120, to: 0x7FFF_FFFF), "entry \(index) of 2 GB")
        }
    }

    func testAVersion4EntrySizeWithHighBitsEndsTheRead() {
        let built = threeStreams(sectorShift: 12)
        let entry = built.layout.offset(ofDirectoryEntry: 3)
        assertDamaged(built.data.patched(at: entry + 124, to: 1), "a 4 GB size")
        assertDamaged(built.data.patched(at: entry + 124, to: 0xFFFF_FFFF), "a 64-bit size beyond Int")
    }

    func testAVersion3EntrySizeIgnoresItsHighBits() throws {
        let built = threeStreams()
        // The high bits are garbage in some version 3 files, and are ignored.
        let entry = built.layout.offset(ofDirectoryEntry: 1)
        let streams = try readAll(built.data.patched(at: entry + 124, to: 0xFFFF_FFFF))
        XCTAssertEqual(Array(try XCTUnwrap(streams["Small"])), built.streams[0].data)
    }

    func testADirectoryTreeThatLoopsEndsTheRead() {
        let built = threeStreams()
        // Entry 1's right link names entry 1 itself.
        let entry = built.layout.offset(ofDirectoryEntry: 1)
        assertDamaged(built.data.patched(at: entry + 72, to: 1), "an entry that is its own sibling")
        // A link past the directory.
        assertDamaged(built.data.patched(at: entry + 72, to: 100), "a link past the directory")
    }

    func testADirectoryNameLongerThanTheFieldEndsTheRead() {
        let built = threeStreams()
        let entry = built.layout.offset(ofDirectoryEntry: 1)
        assertDamaged(built.data.patched(at: entry + 64, to: 200, width: 2), "a name of 200 bytes")
        assertDamaged(built.data.patched(at: entry + 64, to: 7, width: 2), "a name of an odd number of bytes")
    }

    func testAMiniStreamProblemEndsTheRead() {
        let built = threeStreams()
        let small = built.layout.offset(ofDirectoryEntry: 1)
        // A small stream whose size claims more than the mini stream holds.
        assertDamaged(built.data.patched(at: small + 120, to: 4000), "a small stream larger than the mini stream")
        // A small stream starting past the mini stream.
        assertDamaged(built.data.patched(at: small + 116, to: 500), "a start in the mini stream's far reaches")
        // The mini FAT chain looped: mini sector 0 follows itself. The mini
        // FAT is the sector after the last stream's.
        let miniFATOffset = built.layout.offset(ofSector: Int(built.data.u32(at: 60)))
        assertDamaged(built.data.patched(at: miniFATOffset, to: 0), "a mini FAT entry that follows itself")
    }

    func testADIFATChainThatLoopsOrOverstatesItselfEndsTheRead() throws {
        var builder = CompoundFileBuilder()
        builder.streams = [("Huge", pattern(7_500_000, seed: 7))]
        let built = builder.build()
        let first = try XCTUnwrap(built.layout.difatSectors.first)
        // The DIFAT sector's last number names the sector itself.
        let loopOffset = built.layout.offset(ofSector: first) + 127 * 4
        assertDamaged(built.data.patched(at: loopOffset, to: first).patched(at: 72, to: 5), "a DIFAT sector that follows itself")
        assertDamaged(built.data.patched(at: 72, to: 0xFFFF_FFFF), "a DIFAT count of 4 billion")
        assertDamaged(built.data.patched(at: 68, to: 0x00FF_FFFF), "a DIFAT sector past the end")
    }

    func testRandomByteFlipsNeverCrashOrHang() throws {
        var generator = SplitMix64(seed: 20_261_104)
        let built = threeStreams()
        let sample = try Data(contentsOf: formatSampleURL("doc/libreoffice-tdf104239_chapterNumbering.doc"))
        for (name, original) in [("built", built.data), ("sample", sample)] {
            for round in 0..<300 {
                var data = original
                for _ in 0..<(1 + round % 8) {
                    data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                assertSurvives(data, "\(name) round \(round)")
            }
        }
    }

    // MARK: - Bytes

    func testReadsOutsideTheBytesThrowInsteadOfTrapping() {
        let bytes = OLEBytes([1, 2, 3, 4])
        XCTAssertEqual(try bytes.u32(0), 0x0403_0201)
        XCTAssertThrowsError(try bytes.u32(1))
        XCTAssertThrowsError(try bytes.u16(3))
        XCTAssertThrowsError(try bytes.u8(-1))
        XCTAssertThrowsError(try bytes.u8(4))
        XCTAssertThrowsError(try bytes.slice(offset: Int.max, length: 2))
        XCTAssertThrowsError(try bytes.slice(offset: 2, length: Int.max))
        XCTAssertThrowsError(try bytes.slice(offset: 1, length: -1))
        XCTAssertEqual(try bytes.i16(0), 0x0201)
        XCTAssertEqual(try OLEBytes([0xFE, 0xFF]).i16(0), -2)
    }
}

private extension Data {
    /// The little-endian 32-bit number at `offset`.
    func u32(at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(self[offset + $1]) << (8 * $1) }
    }
}
