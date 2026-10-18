import XCTest
@testable import TextMouth

/// A folder book's Ogg conversion judges the book's saved index before it
/// converts anything, and a commit that throws leaves no hidden converted
/// file behind (REV17a, finding 6). The tracks here are named .ogg but are
/// not Ogg: no real Ogg file is ever opened, played, or decoded.
@MainActor
final class OggBookCommitTests: XCTestCase {
    // MARK: - The Check Before Converting

    /// A book without a trusted saved index waits at once: the index, not a
    /// track, is the reason, and nothing is converted or hidden.
    func testABookWithoutASavedIndexWaitsBeforeAnyTrackIsConverted() async throws {
        let world = try makeIntegrationWorld("Ogg Commit No Index")
        let (book, folder) = try makeJunkBook(in: world, index: false)

        let result = await world.library.convertOggBookAudio(ofBook: book.id)

        guard case let .waiting(.failed(reason)) = result else {
            return XCTFail("The book must wait as failed, not \(result)")
        }
        XCTAssertFalse(reason.contains("could not be read for converting to AAC"), "A track was looked at before the index: \(reason)")
        XCTAssertEqual(OggTestFixtures.names(in: folder), Self.trackNames, "No hidden file may be made")
        XCTAssertTrue(world.library.oggConversion.hasFailed(book.id))
        XCTAssertFalse(world.library.oggConversion.isConverting(book.id))
    }

    /// A book with a trusted saved index gets through the check: it is the
    /// first track, unreadable as audio, that stops the conversion now.
    func testABookWithATrustedIndexGetsThroughTheCheck() async throws {
        let world = try makeIntegrationWorld("Ogg Commit Indexed")
        let (book, folder) = try makeJunkBook(in: world, index: true)

        let result = await world.library.convertOggBookAudio(ofBook: book.id)

        guard case let .waiting(.failed(reason)) = result else {
            return XCTFail("The junk tracks must fail the conversion, not \(result)")
        }
        XCTAssertTrue(reason.contains("could not be read for converting to AAC"), "The tracks were not looked at: \(reason)")
        XCTAssertEqual(OggTestFixtures.names(in: folder), Self.trackNames)
    }

    // MARK: - The Commit That Throws

    /// A commit that cannot read the book's index removes every hidden
    /// converted file; the Ogg sources and the manifest stay as they were.
    func testACommitThatThrowsRemovesTheHiddenFiles() throws {
        let world = try makeIntegrationWorld("Ogg Commit Throws")
        let (book, folder) = try makeJunkBook(in: world, index: false)
        let manifest = Data(#"{"order": ["01.ogg", "02.ogg", "03.ogg"]}"#.utf8)
        try manifest.write(to: folder.appendingPathComponent(AudioManifest.fileName))
        let before = OggTestFixtures.names(in: folder)

        // Hand-made conversions: each hidden file is a real file beside its source.
        let conversions = try Self.trackNames.map { name -> ImportAudioConverter.Conversion in
            let stem = (name as NSString).deletingPathExtension
            let hidden = folder.appendingPathComponent(".\(stem).\(UUID().uuidString)\(ImportAudioConverter.temporarySuffix)")
            try Data("converted".utf8).write(to: hidden)
            return ImportAudioConverter.Conversion(
                source: folder.appendingPathComponent(name),
                converted: hidden,
                duration: 2,
                secondsTaken: 1,
                bytesBefore: 9,
                bytesAfter: 9,
                bitRate: nil
            )
        }

        XCTAssertThrowsError(try LibraryViewModel.commitTracks(conversions, of: book, folder: folder))

        XCTAssertEqual(OggTestFixtures.names(in: folder), before, "Only the sources and the manifest may remain")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(AudioManifest.fileName)), manifest)
        for conversion in conversions {
            XCTAssertFalse(FileManager.default.fileExists(atPath: conversion.converted.path))
            XCTAssertEqual(try Data(contentsOf: conversion.source), Data("not audio".utf8))
        }
    }

    // MARK: - Helpers

    /// The three Ogg-named tracks of a junk book, as a folder lists them.
    private static let trackNames = ["01.ogg", "02.ogg", "03.ogg"]

    /// A folder book of three files named .ogg whose contents are not Ogg,
    /// in the world's library. With `index`, it is indexed and its record
    /// saved as an import does, with a stand-in prober; without, it has no
    /// saved index at all.
    private func makeJunkBook(in world: IntegrationWorld, index: Bool) throws -> (Book, URL) {
        let packageName = "\(UUID().uuidString).tmb"
        let folder = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
            .appendingPathComponent("Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in Self.trackNames {
            try Data("not audio".utf8).write(to: folder.appendingPathComponent(name))
        }
        let book = Book(
            title: "Junk Dramas",
            format: .audio,
            filePath: folder.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        )
        if index {
            // The prober is a stand-in: the real one refuses Ogg (B09).
            let analysis = try BookContentAnalysisService.analyzeAudio(
                book: book,
                url: folder,
                prober: AudioMediaProber { _ in .success(2) }
            )
            try book.saveBookInfoThrowing(contentIndex: analysis.index)
        }
        world.library.library.addBook(book)
        return (book, folder)
    }
}
