import XCTest
@testable import TextMouth

/// TextMouth's own True Audio reader (`TTADecoder`): every sample decodes
/// to its source's samples bit for bit, and a file that is locked, cut
/// short, damaged, or crafted ends in an `OwnAudioError`, never in a trap.
/// Nothing is played, and no Apple audio API sees a True Audio file.
final class OwnAudioTrueAudioTests: XCTestCase {
    // MARK: - Helpers

    /// The bytes of the 16-bit stereo sample, a whole small file.
    private func stereoSample() throws -> [UInt8] {
        try ownAudioSampleBytes("tta/stereo16.tta")
    }

    /// `bytes`, a True Audio file without a leading tag, with its header's
    /// two-byte field at `offset` set to `value` and the header's CRC made
    /// right again, so only the field's meaning is tested.
    private func settingHeaderField(at offset: Int, to value: UInt16, in bytes: [UInt8]) -> [UInt8] {
        var copy = bytes
        copy[offset] = UInt8(value & 0xFF)
        copy[offset + 1] = UInt8(value >> 8)
        let crc = OwnAudioCRC32.checksum(copy, in: 0..<18)
        for index in 0..<4 { copy[18 + index] = UInt8(truncatingIfNeeded: crc >> UInt32(8 * index)) }
        return copy
    }

    /// The error a decoder of `bytes` ends in, opening it or decoding it to
    /// its end; nil when it decodes whole.
    private func failure(decoding bytes: [UInt8], verifiesChecksums: Bool = true) -> OwnAudioError? {
        do {
            var decoder: any OwnAudioDecoder = try TTADecoder(OwnAudioBytes(bytes), verifiesChecksums: verifiesChecksums)
            _ = try allSamples(of: &decoder)
            return nil
        } catch {
            return error as? OwnAudioError
        }
    }

    // MARK: - Exact Decoding

    /// Every True Audio sample (8, 16, and 24 bits; one, two, and six
    /// channels; a file shorter than a frame; a file behind an ID3v2 tag)
    /// gives its source's samples back exactly.
    func testEverySampleDecodesToItsSourcesSamples() throws {
        try assertEverySampleDecodesExactly(in: "tta", as: .trueAudio)
    }

    /// The checksums are right in every sample, and decoding without
    /// verifying them gives the same samples.
    func testDecodingWithoutTheChecksumsGivesTheSameSamples() throws {
        let bytes = try stereoSample()
        var checked: any OwnAudioDecoder = try TTADecoder(OwnAudioBytes(bytes))
        var unchecked: any OwnAudioDecoder = try TTADecoder(OwnAudioBytes(bytes), verifiesChecksums: false)
        XCTAssertEqual(try allSamples(of: &checked), try allSamples(of: &unchecked))
    }

    /// The stream's length in seconds is its frames over its rate.
    func testTheDurationIsFramesOverRate() throws {
        let decoder = try TTADecoder(OwnAudioBytes(try stereoSample()))
        XCTAssertEqual(decoder.stream.duration, 13_230.0 / 44_100.0, accuracy: 1e-9)
        XCTAssertNil(decoder.stream.channelMask)
        XCTAssertTrue(decoder.stream.isLossless)
    }

    // MARK: - Refusals

    /// A password-protected file (format 2) is refused in words that say
    /// so; any other unknown form in its own.
    func testALockedFileIsRefusedWithItsReason() throws {
        let locked = settingHeaderField(at: 4, to: 2, in: try stereoSample())
        XCTAssertEqual(failure(decoding: locked), .unsupported(reason: OwnAudioWording.ttaPassword))
        let floating = settingHeaderField(at: 4, to: 3, in: try stereoSample())
        XCTAssertEqual(failure(decoding: floating), .unsupported(reason: OwnAudioWording.ttaForm))
        XCTAssertEqual(
            OwnAudioWording.sentence(for: .unsupported(reason: OwnAudioWording.ttaPassword), fileName: "Radio.tta"),
            "TextMouth can't read the audio file Radio.tta because it is locked with a password."
        )
    }

    /// No channels, too many channels, and bit depths outside 8 to 24 are
    /// refused as a shape True Audio does not allow.
    func testAShapeOutsideTheFormatIsRefused() throws {
        let bytes = try stereoSample()
        for (offset, value) in [(6, UInt16(0)), (6, 9), (8, 7), (8, 25), (8, 32)] {
            XCTAssertEqual(
                failure(decoding: settingHeaderField(at: offset, to: value, in: bytes)),
                .unsupported(reason: OwnAudioWording.ttaShape), "field \(offset) = \(value)"
            )
        }
    }

    /// Bytes that do not start with the signature are not True Audio; a
    /// file of no bytes, or of a signature alone, is not either.
    func testOtherBytesAreNotTrueAudio() {
        XCTAssertEqual(failure(decoding: Array("RIFF....WAVEfmt ................".utf8)), .notThisFormat)
        XCTAssertEqual(failure(decoding: []), .notThisFormat)
        XCTAssertEqual(failure(decoding: Array("TTA1".utf8)), .notThisFormat)
    }

    /// A changed byte in the header, in the seek table, or in a frame fails
    /// its checksum.
    func testAChangedByteFailsItsChecksum() throws {
        let bytes = try stereoSample()
        // The header's sample rate, the seek table's first entry, and the first frame's audio.
        for offset in [10, 22, 40] {
            var copy = bytes
            copy[offset] ^= 0x01
            XCTAssertEqual(failure(decoding: copy), .damaged, "byte \(offset)")
        }
    }

    /// A file cut anywhere ends as cut short or damaged, at every length,
    /// with the checksums and without them.
    func testAFileCutAnywhereIsRefused() throws {
        let bytes = try ownAudioSampleBytes("tta/short16.tta")
        // The file is its header (22 bytes), a seek table of one entry and its
        // CRC (8), and the one frame whose length the entry gives.
        let audioEnd = 30 + Int(try XCTUnwrap(OwnAudioLittleEndian.uint32(bytes, 22)))
        XCTAssertLessThanOrEqual(audioEnd, bytes.count)
        for length in 0..<audioEnd {
            let cut = Array(bytes.prefix(length))
            XCTAssertNotNil(failure(decoding: cut), "cut at \(length)")
            XCTAssertNotNil(failure(decoding: cut, verifiesChecksums: false), "cut at \(length), no checksums")
        }
    }

    /// A header that promises four thousand million frames in a small file
    /// is refused before any room is made for its seek table.
    func testAHeaderPromisingAHugeFileCostsNothing() throws {
        var bytes = try stereoSample()
        for index in 14..<18 { bytes[index] = 0xFF }
        XCTAssertEqual(failure(decoding: bytes, verifiesChecksums: false), .truncated)
    }

    /// A seek table entry far larger than a frame's audio could be, or too
    /// small to hold a bit for every sample, is damage.
    func testAFrameLengthNoAudioCouldHaveIsDamage() throws {
        let bytes = try stereoSample()
        for length in [UInt32(0x7FFF_FFFF), 5] {
            var copy = bytes
            for index in 0..<4 { copy[22 + index] = UInt8(truncatingIfNeeded: length >> UInt32(8 * index)) }
            XCTAssertEqual(failure(decoding: copy, verifiesChecksums: false), .damaged, "length \(length)")
        }
    }

    // MARK: - The Bit Reader

    /// Unary codes are the 1 bits before a 0 bit, binary codes the next
    /// bits lowest first, and reading past the end is an error.
    func testTheBitReaderReadsUnaryAndBinaryCodes() throws {
        // 0b0000_0111 then 0b1010_1100: three ones and a zero; then four zero bits as a number.
        var reader = TTABitReader([0x07, 0xAC], in: 0..<2)
        XCTAssertEqual(try reader.unary(), 3)
        XCTAssertEqual(try reader.binary(4), 0)
        XCTAssertEqual(try reader.binary(8), 0xAC)
        XCTAssertThrowsError(try reader.binary(1)) { XCTAssertEqual($0 as? OwnAudioError, .truncated) }
        XCTAssertThrowsError(try reader.unary()) { XCTAssertEqual($0 as? OwnAudioError, .truncated) }
    }

    /// A run of 1 bits longer than any residual's is damage, not a number.
    func testAnEndlessUnaryRunIsDamage() {
        let ones = [UInt8](repeating: 0xFF, count: Int(TTABitReader.maximumUnary / 8) + 16)
        var reader = TTABitReader(ones, in: 0..<ones.count)
        XCTAssertThrowsError(try reader.unary()) { XCTAssertEqual($0 as? OwnAudioError, .damaged) }
    }

    // MARK: - Hostile Files

    /// Damaged copies of every sample, from a fixed seed, each decode to
    /// samples or an error within a few seconds.
    func testDamagedFilesNeverTrap() throws {
        XCTAssertGreaterThan(try fuzzEverySample(in: "tta", seed: 20_261_115), 0)
    }
}
