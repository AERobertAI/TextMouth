import XCTest
@testable import TextMouth

/// The tags of the files TextMouth's own audio readers read
/// (`OwnAudioTagReader`): APEv2, ID3v2, and ID3v1, read by hand, and the
/// arithmetic between a reader and the encoder (`OwnAudioSamples`).
final class OwnAudioTagTests: XCTestCase {
    // MARK: - Builders

    /// A little-endian 32-bit number as four bytes.
    private func little(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) }
    }

    /// An APEv2 tag's footer: the tag's `size` (items and footer) and its
    /// item count.
    private func apeFooter(size: UInt32, items: UInt32) -> [UInt8] {
        var footer: [UInt8] = Array("APETAGEX".utf8)
        for field in [2_000, size, items, 0x8000_0000] { footer += little(field) }
        return footer + [UInt8](repeating: 0, count: 8)
    }

    /// One APEv2 item: its value's length, its flags, its key, and its value.
    private func apeItem(_ key: String, _ value: [UInt8], flags: UInt32 = 0) -> [UInt8] {
        var item: [UInt8] = little(UInt32(value.count)) + little(flags)
        item += Array(key.utf8)
        item.append(0)
        return item + value
    }

    /// Audio-like filler, then an APEv2 tag of `items`.
    private func fileWithAPETag(_ items: [[UInt8]]) -> OwnAudioBytes {
        let body: [UInt8] = items.flatMap { $0 }
        let footer = apeFooter(size: UInt32(body.count + 32), items: UInt32(items.count))
        return OwnAudioBytes([UInt8](repeating: 0x55, count: 64) + body + footer)
    }

    /// `size` as the four 7-bit bytes ID3v2 writes a size in.
    private func sevenBitBytes(of size: Int) -> [UInt8] {
        [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
    }

    /// An ID3v2 tag of version `version` holding `frames`, already encoded.
    private func id3v2(version: UInt8, frames: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        var tag: [UInt8] = Array("ID3".utf8) + [version, 0, flags]
        tag += sevenBitBytes(of: frames.count)
        return tag + frames
    }

    /// An ID3v2.3 or 2.4 text frame named `name` whose content is `content`.
    private func frame(_ name: String, _ content: [UInt8], synchsafe: Bool = false) -> [UInt8] {
        let size = content.count
        let plain: [UInt8] = [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
        var frame: [UInt8] = Array(name.utf8)
        frame += synchsafe ? sevenBitBytes(of: size) : plain
        frame += [0, 0]
        return frame + content
    }

    // MARK: - A Real File

    /// The tagged sample carries all three tags, each with its own title:
    /// the APEv2 tag's fields win, and its cue sheet is kept whole.
    func testTheAPETagWinsAndCarriesItsCueSheet() throws {
        let bytes = OwnAudioBytes(try ownAudioSampleBytes("tta/tagged16.tta"))
        let tags = OwnAudioTagReader.read(bytes)
        XCTAssertEqual(tags.title, "Ferry Timetables")
        XCTAssertEqual(tags.artist, "Odalys Brennecke")
        XCTAssertEqual(tags.album, "Harbour Notices")
        XCTAssertEqual(tags.genre, "Speech")
        XCTAssertEqual(tags.date, "2026")
        XCTAssertTrue(tags.cueSheet.contains("TITLE \"Morning Crossings\""))
        XCTAssertTrue(tags.cueSheet.contains("INDEX 01 00:00:15"))
        XCTAssertFalse(tags.isEmpty)
    }

    /// Each tag of the tagged sample read alone: the ID3v2 tag's UTF-16 and
    /// Latin-1 frames with the genre's number dropped, and the ID3v1 tag's
    /// fixed fields.
    func testEachTagReadsAlone() throws {
        let bytes = OwnAudioBytes(try ownAudioSampleBytes("tta/tagged16.tta"))
        let leading = OwnAudioTagReader.id3v2Tags(of: bytes)
        XCTAssertEqual(leading.title, "Title from ID3v2")
        XCTAssertEqual(leading.artist, "Artist from ID3v2")
        XCTAssertEqual(leading.genre, "Speech from ID3v2")
        XCTAssertEqual(leading.album, "")
        let trailing = OwnAudioTagReader.id3v1Tags(of: bytes)
        XCTAssertEqual(trailing.title, "Title from ID3v1")
        XCTAssertEqual(trailing.artist, "Artist from ID3v1")
        XCTAssertEqual(trailing.album, "Album from ID3v1")
        XCTAssertEqual(trailing.date, "1999")
    }

    /// A file without tags gives empty tags.
    func testAFileWithoutTagsHasNone() throws {
        XCTAssertTrue(OwnAudioTagReader.read(OwnAudioBytes(try ownAudioSampleBytes("tta/mono16.tta"))).isEmpty)
        XCTAssertTrue(OwnAudioTagReader.read(OwnAudioBytes([])).isEmpty)
    }

    /// Fields fill only what is empty, so an earlier tag keeps its word.
    func testFillingKeepsWhatIsSet() {
        let first = OwnAudioTags(title: "First", artist: "")
        let second = OwnAudioTags(title: "Second", artist: "Narrator", album: "Shelf")
        XCTAssertEqual(first.filling(from: second), OwnAudioTags(title: "First", artist: "Narrator", album: "Shelf"))
    }

    // MARK: - APEv2

    /// Keys match in any case, binary items are passed by, a value of
    /// several strings keeps its first, and unknown keys are ignored.
    func testAPEItemsAreReadByKeyInAnyCase() {
        let tags = OwnAudioTagReader.apeTags(of: fileWithAPETag([
            apeItem("TITLE", Array("Tide Tables".utf8)),
            apeItem("artist", Array("Ingrid Ljungqvist".utf8) + [0] + Array("A second reader".utf8)),
            apeItem("Cover Art (Front)", [0xFF, 0xD8, 0xFF, 0x00], flags: 2),
            apeItem("Album", [0xFF, 0xFE], flags: 2),
            apeItem("Comment", Array("ignored".utf8)),
            apeItem("Year", Array(" 1987 ".utf8)),
        ]))
        XCTAssertEqual(tags.title, "Tide Tables")
        XCTAssertEqual(tags.artist, "Ingrid Ljungqvist")
        XCTAssertEqual(tags.album, "")
        XCTAssertEqual(tags.date, "1987")
    }

    /// An APEv2 tag ahead of an ID3v1 tag is found, and the ID3v1 tag
    /// fills what it left.
    func testAnAPETagBeforeAnID3v1TagIsFound() {
        let item = apeItem("Title", Array("From APE".utf8))
        var id3v1: [UInt8] = Array("TAG".utf8) + [UInt8](repeating: 0, count: 125)
        id3v1.replaceSubrange(33..<41, with: Array("Narrator".utf8))
        var file = [UInt8](repeating: 1, count: 40) + item
        file += apeFooter(size: UInt32(item.count + 32), items: 1)
        let bytes = OwnAudioBytes(file + id3v1)
        let tags = OwnAudioTagReader.read(bytes)
        XCTAssertEqual(tags.title, "From APE")
        XCTAssertEqual(tags.artist, "Narrator")
    }

    /// A footer that names a tag larger than the file, larger than the
    /// limit, or smaller than a footer, and items whose lengths run past
    /// the tag or that never end their key, all read as far as they are
    /// sound and never trap.
    func testADamagedAPETagNeverTraps() {
        let item = apeItem("Title", Array("Sound".utf8))
        for size in [UInt32(0), 31, 0xFFFF_FFFF, UInt32(OwnAudioTagReader.maximumTagBytes + 1), 4_000] {
            let filler = [UInt8](repeating: 0, count: 100)
            let bytes = OwnAudioBytes(filler + item + apeFooter(size: size, items: 1))
            XCTAssertTrue(OwnAudioTagReader.apeTags(of: bytes).isEmpty, "size \(size)")
        }
        // The second item's value claims more bytes than the tag has left.
        let overlong: [UInt8] = little(9_999) + little(0) + Array("Artist\u{0}x".utf8)
        XCTAssertEqual(OwnAudioTagReader.apeTags(of: fileWithAPETag([item, overlong])), OwnAudioTags(title: "Sound"))
        // A key with no zero byte after it.
        let endless: [UInt8] = little(1) + little(0) + Array("Artist".utf8)
        XCTAssertEqual(OwnAudioTagReader.apeTags(of: fileWithAPETag([item, endless])), OwnAudioTags(title: "Sound"))
        // More items promised than the tag holds.
        let body = item
        let promised = OwnAudioBytes(body + apeFooter(size: UInt32(body.count + 32), items: 4_000_000_000))
        XCTAssertEqual(OwnAudioTagReader.apeTags(of: promised), OwnAudioTags(title: "Sound"))
    }

    /// A cue sheet may be long; any other field is cut at its limit.
    func testFieldsAreCutAtTheirLimits() {
        let long = [UInt8](repeating: UInt8(ascii: "a"), count: OwnAudioTagReader.maximumFieldBytes + 500)
        let tags = OwnAudioTagReader.apeTags(of: fileWithAPETag([apeItem("Title", long), apeItem("Cuesheet", long)]))
        XCTAssertEqual(tags.title.utf8.count, OwnAudioTagReader.maximumFieldBytes)
        XCTAssertEqual(tags.cueSheet.utf8.count, long.count)
    }

    // MARK: - ID3v2

    /// Version 2.4 frames have 7-bit sizes and may be UTF-8 or big-endian
    /// UTF-16; the year comes from TDRC.
    func testVersionFourFramesAreRead() {
        let bigEndian: [UInt8] = "Tŷ Coch".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let littleEndian: [UInt8] = "Shelf".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let title: [UInt8] = [3] + Array("Señales".utf8)
        let date: [UInt8] = [0] + Array("2019-04".utf8)
        let album: [UInt8] = [1, 0xFF, 0xFE] + littleEndian + [0, 0]
        var frames: [UInt8] = frame("TIT2", title, synchsafe: true)
        frames += frame("TPE1", [2] + bigEndian, synchsafe: true)
        frames += frame("TDRC", date, synchsafe: true)
        frames += frame("APIC", [0, 1, 2, 3], synchsafe: true)
        frames += frame("TALB", album, synchsafe: true)
        let tags = OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 4, frames: frames) + [0, 0, 0]))
        XCTAssertEqual(tags.title, "Señales")
        XCTAssertEqual(tags.artist, "Tŷ Coch")
        XCTAssertEqual(tags.date, "2019-04")
        XCTAssertEqual(tags.album, "Shelf")
    }

    /// Version 2.2 frames have three-letter names and three-byte sizes.
    func testVersionTwoFramesAreRead() {
        let title: [UInt8] = [0] + Array("Old Tag".utf8)
        let titleFrame: [UInt8] = Array("TT2".utf8) + [0, 0, UInt8(title.count)] + title
        let genreFrame: [UInt8] = Array("TCO".utf8) + [0, 0, 5, 0] + Array("(12)".utf8)
        let frames = titleFrame + genreFrame
        let tags = OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 2, frames: frames)))
        XCTAssertEqual(tags.title, "Old Tag")
        XCTAssertEqual(tags.genre, "", "A genre that is only ID3v1's number is not kept")
    }

    /// A tag written with unsynchronisation or compression, an unknown
    /// version, a frame longer than the tag, and a tag cut short all read
    /// as far as they are sound and never trap.
    func testADamagedID3v2TagNeverTraps() {
        let kept: [UInt8] = [0] + Array("Kept".utf8)
        let good = frame("TIT2", kept)
        XCTAssertTrue(OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 3, frames: good, flags: 0x80))).isEmpty)
        XCTAssertTrue(OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 5, frames: good))).isEmpty)
        let overlong: [UInt8] = Array("TPE1".utf8) + [0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0]
        XCTAssertEqual(OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 3, frames: good + overlong))), OwnAudioTags(title: "Kept"))
        let whole = id3v2(version: 3, frames: good + good)
        for length in 0..<whole.count {
            _ = OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(Array(whole.prefix(length))))
        }
        // An empty frame, an odd count of UTF-16 bytes, and a frame of the encoding byte alone.
        let odd: [UInt8] = frame("TIT2", [1, 0xFF, 0xFE, 0x41]) + frame("TPE1", [1])
        XCTAssertEqual(OwnAudioTagReader.id3v2Tags(of: OwnAudioBytes(id3v2(version: 3, frames: odd))), OwnAudioTags())
    }

    /// The length of a leading ID3v2 tag counts its header and its footer.
    func testTheLeadingTagsLength() {
        let withFooter: [UInt8] = Array("ID3".utf8) + [4, 0, 0x10, 0, 0, 1, 2]
        let plain: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 5]
        let other: [UInt8] = Array("TTA1".utf8) + [0, 0, 0, 0, 0, 0]
        XCTAssertEqual(OwnAudioLeadingTag.id3v2Length(in: withFooter), 10 + 130 + 10)
        XCTAssertEqual(OwnAudioLeadingTag.id3v2Length(in: plain), 15)
        XCTAssertEqual(OwnAudioLeadingTag.id3v2Length(in: other), 0)
        XCTAssertEqual(OwnAudioLeadingTag.id3v2Length(in: Array("ID3".utf8)), 0)
    }

    // MARK: - The Bytes

    /// A file on disk and the same bytes in memory read alike, and every
    /// read outside the bytes is refused.
    func testBytesOnDiskAndInMemoryReadAlikeAndCheckTheirBounds() throws {
        let content = (0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let folder = try makeSandboxDirectory("OwnAudioBytes")
        let url = folder.appendingPathComponent("bytes.bin")
        try Data(content).write(to: url)
        let onDisk = try XCTUnwrap(OwnAudioBytes(path: url.path))
        for source in [onDisk, OwnAudioBytes(content)] {
            XCTAssertEqual(source.count, 1_000)
            XCTAssertEqual(try source.read(at: 0, count: 1_000), content)
            XCTAssertEqual(try source.read(at: 990, count: 10), Array(content[990...]))
            XCTAssertEqual(try source.read(at: 1_000, count: 0), [])
            XCTAssertEqual(source.readUpTo(at: 990, count: 500), Array(content[990...]))
            XCTAssertEqual(source.readUpTo(at: 1_000, count: 4), [])
            XCTAssertEqual(source.readUpTo(at: -4, count: 4), [])
            for (offset, count) in [(991, 10), (-1, 1), (0, -1), (1_001, 0), (0, Int.max), (Int.max, 1)] {
                XCTAssertThrowsError(try source.read(at: offset, count: count), "\(offset), \(count)") {
                    XCTAssertEqual($0 as? OwnAudioError, .truncated)
                }
            }
        }
        XCTAssertNil(OwnAudioBytes(path: folder.path), "A folder is not a file of bytes")
        XCTAssertNil(OwnAudioBytes(path: folder.appendingPathComponent("missing").path))
    }

    /// Little-endian fields outside the bytes read as nil.
    func testLittleEndianFieldsCheckTheirBounds() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        XCTAssertEqual(OwnAudioLittleEndian.uint16(bytes, 3), 0x0504)
        XCTAssertEqual(OwnAudioLittleEndian.uint32(bytes, 1), 0x0504_0302)
        XCTAssertNil(OwnAudioLittleEndian.uint16(bytes, 4))
        XCTAssertNil(OwnAudioLittleEndian.uint32(bytes, 2))
        XCTAssertNil(OwnAudioLittleEndian.uint32(bytes, -1))
        XCTAssertNil(OwnAudioLittleEndian.uint32([], 0))
        XCTAssertTrue(OwnAudioLittleEndian.holds(Array("xTTA1".utf8), "TTA1", at: 1))
        XCTAssertFalse(OwnAudioLittleEndian.holds(Array("TTA".utf8), "TTA1", at: 0))
        XCTAssertEqual(OwnAudioCRC32.checksum(Array("123456789".utf8), in: 0..<9), 0xCBF4_3926)
    }

    // MARK: - Samples for the Encoder

    /// Floats become 24-bit whole numbers, rounded and held in range; what
    /// is not a number becomes silence.
    func testFloatsBecomeWholeNumbers() {
        let floats: [Float] = [0, 0.5, -0.5, 1, -1, 2, -2, .nan, .infinity, -.infinity, 1.0 / 8_388_608]
        let whole = OwnAudioSamples.wholeNumbers(fromFloats: floats.map { Int32(bitPattern: $0.bitPattern) })
        XCTAssertEqual(whole, [0, 4_194_304, -4_194_304, 8_388_607, -8_388_608, 8_388_607, -8_388_608, 0, 8_388_607, -8_388_608, 1])
    }

    /// A 5.1 mix keeps the fronts, shares the centre, leaves out the
    /// low-frequency channel, and cannot clip.
    func testAMixToStereoFollowsTheMask() {
        // Front left, front right, front centre, low frequency, back left, back right.
        let gains = OwnAudioSamples.stereoGains(channels: 6, mask: 0x3F)
        guard gains.count == 6 else { return XCTFail("Six channels have \(gains.count) gains") }
        XCTAssertEqual(gains[3].left, 0)
        XCTAssertEqual(gains[3].right, 0)
        XCTAssertEqual(gains[0].right, 0)
        XCTAssertEqual(gains[1].left, 0)
        XCTAssertEqual(gains[2].left, gains[2].right)
        XCTAssertEqual(gains.reduce(0) { $0 + $1.left }, 1, accuracy: 1e-12)
        XCTAssertEqual(gains.reduce(0) { $0 + $1.right }, 1, accuracy: 1e-12)
        // Only the centre speaks: both ears hear it alike.
        let centre = OwnAudioSamples.stereo([0, 0, 10_000, 0, 0, 0], gains: gains)
        XCTAssertEqual(centre.count, 2)
        XCTAssertEqual(centre.first, centre.last)
        XCTAssertGreaterThan(centre.first ?? 0, 2_000)
        // Every channel at full scale stays inside 16 bits, and part frames are dropped.
        let loud = OwnAudioSamples.stereo([Int32](repeating: 32_767, count: 6) + [1, 2], gains: gains)
        XCTAssertEqual(loud.count, 2)
        XCTAssertLessThanOrEqual(loud.first ?? Int32.max, 32_767)
        XCTAssertEqual(OwnAudioSamples.stereo([1, 2, 3], gains: []), [])
        // A channel the mask does not name goes to both ears.
        let unnamed = OwnAudioSamples.stereoGains(channels: 3, mask: 0x3)
        XCTAssertEqual(unnamed.count, 3)
        XCTAssertEqual(unnamed.last?.left, unnamed.last?.right)
        XCTAssertGreaterThan(unnamed.last?.left ?? 0, 0)
    }

    /// Samples are packed little-endian at the top of their container.
    func testSamplesArePackedAtTheTopOfTheirContainer() {
        XCTAssertEqual(OwnAudioSamples.packed([1, -1], bits: 16, container: 16), [0x01, 0x00, 0xFF, 0xFF])
        XCTAssertEqual(OwnAudioSamples.packed([-128, 127], bits: 8, container: 16), [0x00, 0x80, 0x00, 0x7F])
        XCTAssertEqual(OwnAudioSamples.packed([0x12_3456], bits: 24, container: 32), [0x00, 0x56, 0x34, 0x12])
        XCTAssertEqual(OwnAudioSamples.packed([-1], bits: 20, container: 32), [0x00, 0xF0, 0xFF, 0xFF])
        XCTAssertEqual(OwnAudioSamples.packed([Int32.min, Int32.max], bits: 32, container: 32), [0, 0, 0, 0x80, 0xFF, 0xFF, 0xFF, 0x7F])
        // A sample wider than its bits loses its top rather than trapping.
        XCTAssertEqual(OwnAudioSamples.packed([Int32.max], bits: 8, container: 16), [0x00, 0xFF])
    }
}
