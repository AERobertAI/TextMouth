import CryptoKit
import XCTest
@testable import TextMouth

/// One test file of TextMouth's own audio readers, as its folder's
/// `pcm.tsv` lists it (`Scripts/make-own-audio-samples.py` writes both).
struct OwnAudioSampleFile {
    /// The folder under `TestData/format-samples`, such as "tta".
    let folder: String
    /// The file's name inside the folder.
    let fileName: String
    let sampleRate: Int
    let channels: Int
    let bits: Int
    let isFloat: Bool
    let isLossless: Bool
    let frames: Int
    /// The SHA-256 of the sample bytes the source WAV held; nil for a lossy
    /// file, which has no samples to compare with.
    let digest: String?

    /// The sample's path under `TestData/format-samples`.
    var path: String { "\(folder)/\(fileName)" }
}

/// The damage the own readers' tests do to a copy of a sample, in memory.
enum OwnAudioDamage {
    /// A copy of `bytes` damaged in one of five ways chosen by `round`,
    /// with every random choice drawn from `generator`: a few bytes changed
    /// anywhere, a few changed in the header, the end cut off, a run of
    /// bytes set to one value, or one piece copied over another. A file of
    /// no bytes is returned as it is.
    static func damaged(_ bytes: [UInt8], round: Int, using generator: inout SplitMix64) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        var copy = bytes
        switch round % 5 {
        case 0:
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                copy[Int.random(in: 0..<copy.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
        case 1:
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                copy[Int.random(in: 0..<min(128, copy.count), using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
        case 2:
            copy.removeLast(Int.random(in: 1...copy.count, using: &generator))
        case 3:
            let start = Int.random(in: 0..<copy.count, using: &generator)
            let value: UInt8 = [0, 0xFF, 0x80, 0x7F].randomElement(using: &generator) ?? 0
            for index in start..<min(copy.count, start + Int.random(in: 1...64, using: &generator)) { copy[index] = value }
        default:
            let length = Int.random(in: 1...min(256, copy.count), using: &generator)
            let from = Int.random(in: 0...(copy.count - length), using: &generator)
            let target = Int.random(in: 0...(copy.count - length), using: &generator)
            copy.replaceSubrange(target..<target + length, with: Array(copy[from..<from + length]))
        }
        return copy
    }
}

extension XCTestCase {
    /// The test files in the folder `folder` of `TestData/format-samples`
    /// that its `pcm.tsv` lists, in the file's order.
    func ownAudioSamples(in folder: String) throws -> [OwnAudioSampleFile] {
        let table = try String(contentsOf: requireFile("format-samples/\(folder)/pcm.tsv"), encoding: .utf8)
        return table.split(separator: "\n").dropFirst().compactMap { line -> OwnAudioSampleFile? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, let rate = Int(fields[1]), let channels = Int(fields[2]),
                  let bits = Int(fields[3]), let frames = Int(fields[6]) else { return nil }
            return OwnAudioSampleFile(
                folder: folder, fileName: fields[0], sampleRate: rate, channels: channels, bits: bits,
                isFloat: fields[4] == "1", isLossless: fields[5] == "1", frames: frames,
                digest: fields[7] == "-" ? nil : fields[7]
            )
        }
    }

    /// The fewest bytes any sample holds: a test may change a byte of a
    /// sample's first 64, or its middle one, without checking the count.
    static var ownAudioSampleMinimumBytes: Int { 64 }

    /// The bytes of the sample at `path` under `TestData/format-samples`,
    /// at least `ownAudioSampleMinimumBytes` of them.
    /// - Throws: when the file is missing or shorter, so no test that
    ///   changes a byte of it can trap.
    func ownAudioSampleBytes(_ path: String) throws -> [UInt8] {
        let bytes = [UInt8](try Data(contentsOf: requireFile("format-samples/\(path)")))
        guard bytes.count >= Self.ownAudioSampleMinimumBytes else {
            throw TestError.assertionFailed("The sample \(path) holds only \(bytes.count) bytes")
        }
        return bytes
    }

    /// The path, under `TestData/format-samples`, of the companion of the
    /// sample at `path` (a WavPack correction file of the same name), or
    /// nil when the sample's format has none or the samples hold none.
    func ownAudioCompanionPath(of path: String) -> String? {
        let ending = (path as NSString).pathExtension.lowercased()
        guard let format = OwnAudioFormat.allCases.first(where: { $0.fileExtensions.contains(ending) }),
              let companionEnding = format.companionExtension else { return nil }
        let companion = ((path as NSString).deletingPathExtension as NSString).appendingPathExtension(companionEnding) ?? ""
        return (try? requireFile("format-samples/\(companion)")) != nil ? companion : nil
    }

    /// The bytes of the companion of the sample at `path`, when it has one.
    func ownAudioCompanionBytes(of path: String) throws -> OwnAudioBytes? {
        try ownAudioCompanionPath(of: path).map { OwnAudioBytes(try ownAudioSampleBytes($0)) }
    }

    /// Every sample `decoder` gives, block after block.
    func allSamples(of decoder: inout any OwnAudioDecoder) throws -> [Int32] {
        var samples: [Int32] = []
        while let block = try decoder.nextBlock() {
            XCTAssertFalse(block.isEmpty, "A block is never empty")
            samples += block
        }
        return samples
    }

    /// `samples` as the bytes a WAV file stores them in: 8-bit samples
    /// unsigned, wider ones (and floats' bit patterns) little-endian, each
    /// in the bytes its `bits` need, at the top of them when it does not
    /// fill them (12 bits in two bytes, 20 in three), as a WAV file holds
    /// such samples. This is what `pcm.tsv`'s digests are of.
    func waveBytes(of samples: [Int32], bits: Int) -> [UInt8] {
        let width = (bits + 7) / 8
        let lift = Int32(width * 8 - bits)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * width)
        for sample in samples {
            if width == 1 {
                bytes.append(UInt8(truncatingIfNeeded: sample &+ 128))
            } else {
                for byte in 0..<width { bytes.append(UInt8(truncatingIfNeeded: (sample << lift) >> Int32(8 * byte))) }
            }
        }
        return bytes
    }

    /// The SHA-256 of `bytes`, in lowercase hexadecimal.
    func sha256(of bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes every sample `pcm.tsv` lists in `folder` with the reader its
    /// bytes name (a sample with a companion together with it), and checks
    /// what the header says and, for a lossless file, that the samples are
    /// the source's, bit for bit.
    func assertEverySampleDecodesExactly(in folder: String, as format: OwnAudioFormat) throws {
        let samples = try ownAudioSamples(in: folder)
        XCTAssertFalse(samples.isEmpty, "\(folder)/pcm.tsv lists no file")
        for sample in samples {
            let bytes = OwnAudioBytes(try ownAudioSampleBytes(sample.path))
            XCTAssertEqual(OwnAudioFormat.of(bytes), format, sample.path)
            var decoder = try format.decoder(of: bytes, companion: try ownAudioCompanionBytes(of: sample.path))
            let stream = decoder.stream
            XCTAssertEqual(stream.sampleRate, sample.sampleRate, sample.path)
            XCTAssertEqual(stream.channels, sample.channels, sample.path)
            XCTAssertEqual(stream.bitsPerSample, sample.bits, sample.path)
            XCTAssertEqual(stream.isFloat, sample.isFloat, sample.path)
            XCTAssertEqual(stream.isLossless, sample.isLossless, sample.path)
            XCTAssertEqual(stream.frames, sample.frames, sample.path)
            let decoded = try allSamples(of: &decoder)
            XCTAssertEqual(decoded.count, sample.frames * sample.channels, sample.path)
            if let digest = sample.digest {
                XCTAssertEqual(sha256(of: waveBytes(of: decoded, bits: sample.bits)), digest, sample.path)
            }
        }
    }

    /// Damages copies of every sample in `folder` (`OwnAudioDamage`, from a
    /// fixed seed) and decodes each to its end with the reader its bytes
    /// name, with the checksums verified and without, and reads its tags.
    /// A sample with a companion is decoded with it, and on every other
    /// round the companion is the one damaged. Every decode must end in
    /// samples or in an `OwnAudioError`; a trap would end the test host. It
    /// stops after `seconds`, having tried at least one damaged copy of
    /// every sample of the folder, the longest and the multichannel ones
    /// included (review10, finding 4), so the samples are kept short.
    /// - Returns: how many damaged copies were decoded.
    @discardableResult
    func fuzzEverySample(
        in folder: String,
        seed: UInt64,
        seconds: TimeInterval = 4
    ) throws -> Int {
        let taken = try ownAudioSamples(in: folder)
        let originals = try taken.map { sample -> (file: [UInt8], companion: [UInt8]?) in
            (try ownAudioSampleBytes(sample.path), try ownAudioCompanionPath(of: sample.path).map { try ownAudioSampleBytes($0) })
        }
        var generator = SplitMix64(seed: seed)
        let deadline = Date().addingTimeInterval(seconds)
        var tried = 0
        var round = 0
        // Round by round over every sample, so each is damaged in every way the time allows.
        while round < 1 || Date() < deadline {
            for original in originals {
                var file = original.file
                var companion = original.companion
                if let whole = companion, round % 2 == 1 {
                    companion = OwnAudioDamage.damaged(whole, round: round / 2, using: &generator)
                } else {
                    file = OwnAudioDamage.damaged(file, round: round, using: &generator)
                }
                let source = OwnAudioBytes(file)
                _ = OwnAudioTagReader.read(source)
                for verifiesChecksums in [true, false] {
                    guard let format = OwnAudioFormat.of(source) else { continue }
                    do {
                        var decoder = try format.decoder(
                            of: source, companion: companion.map { OwnAudioBytes($0) }, verifiesChecksums: verifiesChecksums)
                        while let block = try decoder.nextBlock() { XCTAssertFalse(block.isEmpty) }
                    } catch {
                        XCTAssertTrue(error is OwnAudioError, "\(error)")
                    }
                }
                tried += 1
                if round >= 1, Date() >= deadline { return tried }
            }
            round += 1
        }
        return tried
    }
}
