import AVFoundation
import XCTest
@testable import TextMouth

/// A package's track scan takes no converted format (review item 7). What
/// Open Book and an import accept (`BookFormat.audio.fileExtensions`) is
/// not what a book's own folder of tracks is read by: a stray .ac3, .aifc,
/// .au, or CAF left in an older ZIP import's folder must neither fail the
/// book nor shift its chapters under the listener's places. Only
/// TextMouth's own CAF (a recording's original take and a punch-in's take)
/// is taken, by its name and its place, and the import's own scans still
/// find every format it converts.
///
/// No test plays sound, and no stray is decoded: the stray files are bytes
/// that only look like audio, plus one Opus CAF made by `afconvert` in a
/// child process, and a stand-in prober answers for every track.
final class PackageTrackScanTests: XCTestCase {
    /// The names of the files a stand-in prober was asked about, safely
    /// shared with the prober's concurrent tasks.
    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        /// Notes that `url`'s file was probed.
        func record(_ url: URL) {
            lock.lock()
            names.append(url.lastPathComponent)
            lock.unlock()
        }

        /// The probed names, sorted.
        var probed: [String] {
            lock.lock()
            defer { lock.unlock() }
            return names.sorted()
        }
    }

    // MARK: - An Older Book Keeps Its Tracks

    /// A book of three .m4a tracks with a stray .ac3 and a stray Opus CAF
    /// reads as the book it was: the same three tracks, the same chapters
    /// (so the same place for every position and bookmark), and neither
    /// stray is opened.
    func testAnOlderBookKeepsItsTracksBesideStrays() throws {
        let folder = try makeBookFolder(trackNames: ["01.m4a", "02.m4a", "03.m4a"])
        let book = Book(title: "Older", format: .audio, filePath: folder.path, md5Hash: "older")
        let log = ProbeLog()
        let before = try BookContentAnalysisService.analyzeAudio(book: book, url: folder, prober: standIn(log))

        try writeStrayBytes(named: "extra.ac3", in: folder)
        try writeStrayBytes(named: "aside.aifc", in: folder)
        try writeStrayBytes(named: "voice.au", in: folder)
        try writeOpusCAF(named: "stray.caf", in: folder)
        let afterLog = ProbeLog()
        let after = try BookContentAnalysisService.analyzeAudio(book: book, url: folder, prober: standIn(afterLog))

        XCTAssertEqual(after.index.chapters.compactMap(\.audioFilePath), ["01.m4a", "02.m4a", "03.m4a"])
        XCTAssertEqual(after.audioFilePaths, before.audioFilePaths)
        XCTAssertEqual(after.index.chapters, before.index.chapters, "A stray changed the chapters")
        XCTAssertEqual(afterLog.probed, ["01.m4a", "02.m4a", "03.m4a"], "A stray was opened")
        // A place or bookmark is a character offset in the book: the middle
        // of every chapter, and the book's last character, still fall in the
        // same track.
        for chapter in before.index.chapters {
            let offset = chapter.startCharacterOffset + chapter.characterCount / 2
            XCTAssertEqual(trackPlaying(offset, in: after.index), trackPlaying(offset, in: before.index))
        }
        XCTAssertEqual(before.index.totalCharacterCount, after.index.totalCharacterCount)
    }

    /// The manifest edit's own check takes the package's tracks too: a
    /// manifest that names a stray as a track names a file the book does not
    /// have, while the import's check, which runs before the conversion,
    /// still finds it.
    func testAManifestCheckOnAPackageIgnoresAStray() throws {
        let folder = try makeBookFolder(trackNames: ["01.m4a"])
        try writeStrayBytes(named: "extra.ac3", in: folder)
        try Data(#"{"tracks": ["01.m4a", "extra.ac3"]}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder))

        XCTAssertNoThrow(try AudioManifestCheck.checkedManifest(at: location, audioFolder: folder, scan: .importing))
        XCTAssertThrowsError(try AudioManifestCheck.checkedManifest(at: location, audioFolder: folder, scan: .package)) { error in
            guard case .missingFiles = error as? AudioManifestProblem else {
                return XCTFail("Expected missing files, not \(error)")
            }
        }
    }

    // MARK: - The Two Lists

    /// The package's list is the audio list without the core-audio formats
    /// the import converts, and the two together are the audio list: nothing
    /// falls between. Ogg stays in it, as the library's conversion of Ogg
    /// books has to find those tracks.
    func testThePackageListIsTheAudioListWithoutTheCoreAudioFormats() {
        let audio = Set(BookFormat.audio.fileExtensions)
        let package = BookFormat.packageTrackExtensions

        XCTAssertTrue(package.isDisjoint(with: ImportAudioConverter.coreAudioExtensions))
        XCTAssertEqual(package.union(audio.intersection(ImportAudioConverter.coreAudioExtensions)), audio)
        for played in ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac", "mp4", "m4v", "mov", "ogg", "oga", "opus"] {
            XCTAssertTrue(package.contains(played), "\(played) stays a package track")
        }
        for converted in ["caf", "aifc", "au", "w64", "ac3", "ec3", "mp2", "amr", "3gp"] {
            XCTAssertFalse(package.contains(converted), "\(converted) is converted at import")
            XCTAssertTrue(audio.contains(converted), "\(converted) is still accepted by Open Book and an import")
        }
    }

    // MARK: - TextMouth's Own Takes

    /// A recording's original take at the package's root and a punch-in's
    /// take in `audioEdits/takes` are tracks of a package scan; a CAF of
    /// another name or place is not, though the import's scan finds it.
    func testOwnTakesStayTracksWhereTextMouthPutsThemAndAStrayCAFIsNotOne() throws {
        let folder = try scratchFolder()
        let wanted = [
            BookOrigin.originalTakeFileName,
            "\(AudioEditPackage.takesFolder)/ABCD-1234.caf",
            "01.m4a",
        ]
        let strays = [
            "stray.caf",
            "Disc 2/\(BookOrigin.originalTakeFileName)",
            "\(AudioEditPackage.folderName)/other.caf",
            "\(AudioEditPackage.takesFolder)/deeper/ABCD-1234.caf",
            "\(AudioEditPackage.takesFolder)/not-a-take.ac3",
        ]
        for name in wanted + strays { try writeStrayBytes(named: name, in: folder) }

        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: folder, scan: .package).sorted(),
            wanted.sorted(),
            "A package scan took the wrong CAF files"
        )
        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: folder, scan: .importing).sorted(),
            (wanted + strays).sorted(),
            "The import's scan lost a file"
        )
    }

    /// Own-CAF names are matched by whole path, so lookalikes are strays.
    func testOnlyTheExactNamesAndPlacesAreOwnCAFs() {
        XCTAssertTrue(AudioBookParser.isOwnCAF(atPath: "original-take.caf"))
        XCTAssertTrue(AudioBookParser.isOwnCAF(atPath: "audioEdits/takes/0F3A.caf"))
        XCTAssertTrue(AudioBookParser.isOwnCAF(atPath: "audioEdits/takes/0F3A.CAF"))
        for lookalike in ["", "take.caf", "sub/original-take.caf", "audioEdits/original-take.caf", "audioEdits/takes",
                          "audioEdits/takes/0F3A.mp3", "audioEdits/takes/a/b.caf", "takes/0F3A.caf", "original-take.caf/x"] {
            XCTAssertFalse(AudioBookParser.isOwnCAF(atPath: lookalike), "\"\(lookalike)\" is not one")
        }
    }

    // MARK: - The Import Still Converts

    /// A staged folder of .ac3 tracks (and an Ogg one) is still a folder of
    /// tracks and still has its tracks to convert, as before the review.
    func testTheImportStillFindsFoldersOfConvertedFormats() throws {
        let folder = try scratchFolder()
        for name in ["one.ac3", "two.ac3", "three.ogg"] { try writeStrayBytes(named: name, in: folder) }

        XCTAssertTrue(FileImportService.isFolderOfTracks(folder))
        XCTAssertEqual(
            ImportAudioConverter.filesToConvert(in: folder).map(\.lastPathComponent),
            ["one.ac3", "three.ogg", "two.ac3"]
        )
        XCTAssertEqual(ImportAudioConverter.oggFiles(in: folder).map(\.lastPathComponent), ["three.ogg"])
        XCTAssertEqual(try AudioBookParser.trackPaths(in: folder, scan: .importing).count, 3)
        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: folder, scan: .package),
            ["three.ogg"],
            "A package takes the Ogg track, which the library converts, and neither .ac3"
        )
    }

    // MARK: - Helpers

    /// A new folder under the temporary directory, removed when the test ends.
    private func scratchFolder() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A folder holding AAC tracks named `trackNames`, one second longer
    /// each than the one before.
    private func makeBookFolder(trackNames: [String]) throws -> URL {
        let folder = try scratchFolder()
        for (number, name) in trackNames.enumerated() {
            try AudioTestFixtures.writeAACSilence(to: folder.appendingPathComponent(name), duration: TimeInterval(number + 1))
        }
        return folder
    }

    /// A prober that answers for every file without opening it, noting the
    /// names it was asked about: two seconds for a track, so a track's
    /// length is the same in every analysis.
    private func standIn(_ log: ProbeLog) -> AudioMediaProber {
        AudioMediaProber { url in
            log.record(url)
            return .success(2)
        }
    }

    /// Writes bytes that only look like audio, at `name` (its folders made),
    /// never opened by any audio framework.
    private func writeStrayBytes(named name: String, in folder: URL) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not audio, only bytes".utf8).write(to: file)
    }

    /// Writes a half-second Opus CAF at `name` in `folder`, made by
    /// `afconvert` in a child process from a tone written here.
    private func writeOpusCAF(named name: String, in folder: URL) throws {
        let source = try scratchFolder().appendingPathComponent("tone.wav")
        try AudioTestFixtures.writeTones([AudioTestFixtures.Tone(seconds: 0.5, frequency: 440, amplitude: 0.5)], to: source, sampleRate: 48_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "caff", "-d", "opus", source.path, folder.appendingPathComponent(name).path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "afconvert could not make the Opus CAF")
    }

    /// The path of the track playing character `offset` of the book `index`
    /// describes: where a saved place or bookmark at that offset lands.
    private func trackPlaying(_ offset: Int, in index: BookContentIndex) -> String? {
        index.chapters.last { $0.startCharacterOffset <= offset }?.audioFilePath
    }
}
