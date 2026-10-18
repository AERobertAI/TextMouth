import XCTest
@testable import TextMouth

/// An Ogg FLAC file (.oga or .ogg) is accepted at import and written as
/// Apple Lossless (FMT14, step 1): the header reader names it, the converter
/// plans a lossless conversion, and the converted file keeps the source's 16
/// bits. The file is `TestData/audio/ogg-flac-tone.oga`, the tones of
/// `format-samples/flac-chapters/three-tones.flac` (mono, 22,050 Hz, 16 bits,
/// four seconds). It was made on October 18, 2026 with flac 1.5.0 (Homebrew)
/// in two commands, from the repository's root:
///
///     /usr/bin/afconvert -f WAVE -d LEI16 TestData/format-samples/flac-chapters/three-tones.flac /tmp/three-tones.wav
///     flac --ogg -s -f -o TestData/audio/ogg-flac-tone.oga /tmp/three-tones.wav
///
/// (flac warns that it skips the WAVE file's "FLLR" padding chunk; that is
/// harmless.) Apple's own Ogg writer refuses FLAC on this macOS (afconvert
/// -f Oggf -d flac: ExtAudioFileWrite 'pck?'), so a test cannot make the
/// file itself. The source is read only by the header
/// reader's own bytes and by `afconvert` and `afinfo` in child processes
/// (the rule of October 14, 2026), and no test plays sound.
final class OggFlacConversionTests: XCTestCase {
    /// The Ogg FLAC tone, under `TestData`.
    private static let fixture = "audio/ogg-flac-tone.oga"
    /// What the tone's header says.
    private static let seconds = 4.0

    private var folder: URL! // lint-ok: set in setUpWithError before any test body reads it
    private var importedPackages: [URL] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    /// A copy of the Ogg FLAC tone in the test's own folder, named `name`.
    private func copyTone(as name: String = "three-tones.oga") throws -> URL {
        try OggTestFixtures.copy(Self.fixture, to: folder, as: name)
    }

    // MARK: - Reading

    /// The header reader gives the tone's codec, channels, rate, bits, and
    /// length from its bytes alone.
    func testTheHeaderReaderReadsARealOggFlacFile() throws {
        let header = try XCTUnwrap(OggHeaderReader.read(at: try copyTone()))
        XCTAssertEqual(header.codec, .flac)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 22_050)
        XCTAssertEqual(header.bitsPerSample, 16)
        XCTAssertEqual(header.duration, Self.seconds, accuracy: 0.05)
    }

    /// The same file under the .ogg extension reads the same.
    func testTheExtensionDoesNotChangeWhatIsRead() throws {
        let oga = try XCTUnwrap(OggHeaderReader.read(at: try copyTone()))
        let ogg = try XCTUnwrap(OggHeaderReader.read(at: try copyTone(as: "three-tones.ogg")))
        XCTAssertEqual(oga, ogg)
    }

    /// The converter's view of the file: named "flac", lossless, 16 bits;
    /// so it is planned as Apple Lossless at 16 bits, mono, and its own rate.
    func testTheConverterPlansAppleLosslessForIt() async throws {
        let source = try copyTone()
        let read = try await ImportAudioConverter.inspect(source)
        let info = try XCTUnwrap(read)

        XCTAssertEqual(info.formatID, "flac")
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertTrue(info.isLossless)
        XCTAssertEqual(ImportAudioConverter.plan(for: source, info: info), .convertToAppleLossless)
        let target = ImportAudioConverter.target(for: info, bytes: ImportAudioConverter.fileSize(of: source))
        XCTAssertEqual(target, ImportAudioConverter.Target(
            channels: 1, sampleRate: 22_050, bitRate: nil, appleLosslessBitDepth: 16
        ))
    }

    // MARK: - Converting

    /// A real conversion gives an .m4a of Apple Lossless that keeps the
    /// source's 16 bits, rate, and length, passes the playability probe, and
    /// leaves the source and no hidden file. The time is printed.
    func testAnOggFlacFileConvertsToAppleLossless() async throws {
        let source = try copyTone()
        let sourceBytes = try Data(contentsOf: source)

        let conversion = try await ImportAudioConverter.convert(source)

        XCTAssertEqual(conversion.converted.lastPathComponent, "three-tones.m4a")
        let convertedRead = try await AudioFileInfo.read(conversion.converted)
        let converted = try XCTUnwrap(convertedRead)
        XCTAssertEqual(converted.formatID, "alac")
        XCTAssertEqual(converted.bitsPerSample, 16)
        XCTAssertEqual(converted.sampleRate, 22_050)
        XCTAssertEqual(converted.channels, 1)
        XCTAssertEqual(converted.duration, Self.seconds, accuracy: ImportAudioConverter.allowedLengthError(for: Self.seconds))
        XCTAssertNil(conversion.bitRate)
        let probed = await AudioMediaProbe.duration(of: conversion.converted)
        if case .failure = probed { XCTFail("The converted file does not play: \(probed)") }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["three-tones.m4a", "three-tones.oga"])
        print("FMT14 Ogg FLAC conversion time: \(String(format: "%.2f", conversion.secondsTaken)) s")
    }

    /// Ogg Vorbis, the lossy sibling, still becomes AAC.
    func testAnOggVorbisFileStillConvertsToAAC() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "elegy.ogg")

        let conversion = try await ImportAudioConverter.convert(source)

        let convertedRead = try await AudioFileInfo.read(conversion.converted)
        XCTAssertEqual(try XCTUnwrap(convertedRead).formatID, "aac ")
        XCTAssertNotNil(conversion.bitRate)
    }

    // MARK: - Importing

    /// A single Ogg FLAC file opened as a book imports as an .m4a file of
    /// Apple Lossless, which is the book's file; the file imported from is
    /// untouched, and no Ogg file is left in the package.
    func testASingleOggFlacFileImportsAsAnAppleLosslessM4AFile() async throws {
        let source = try copyTone()
        let sourceBytes = try Data(contentsOf: source)

        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(audio.lastPathComponent, "three-tones.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(OggTestFixtures.names(in: audio.deletingLastPathComponent()).filter { $0.hasSuffix(".oga") }, [])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        let importedRead = try await AudioFileInfo.read(audio)
        XCTAssertEqual(try XCTUnwrap(importedRead).formatID, "alac")
    }
}
