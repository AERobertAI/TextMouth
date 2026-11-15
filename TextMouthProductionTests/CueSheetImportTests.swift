import XCTest
@testable import TextMouth

/// Cue sheets give audiobooks a heading per track (FMT24): a sheet chosen on
/// its own imports the files it names, as a playlist does, and the sheets in
/// a folder or a ZIP of tracks arrange it when no manifest.json does. Each
/// test copies a sample folder, or writes one, into its own sandbox and
/// imports into a library folder of its own; the sources are never changed.
/// Nothing is played.
final class CueSheetImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox! // lint-ok: made in setUpWithError before every test
    /// The library folder this test imports into.
    private var folderPath: String! // lint-ok: made in setUpWithError before every test
    /// Where this test's sheets and tracks are written, outside the library.
    private var sources: URL! // lint-ok: made in setUpWithError before every test

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "Cue Import \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("cue-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - A Sheet Chosen on Its Own

    /// The album sample, chosen on its own, imports its one file as a book
    /// named and authored by the sheet, with a heading per track, the
    /// sections the sheet's times give, and nothing else of the folder; the
    /// folder is as it was, and the book is never offered for deletion.
    func testTheAlbumSheetImportsItsFileWithAHeadingPerTrack() throws {
        let folder = try copySampleFolder("cue")
        let before = try snapshot(of: folder)

        let imported = try FileImportService.importFileWithReport(
            from: folder.appendingPathComponent("album.cue"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "Three Tracks — café")
        XCTAssertEqual(imported.book.author, "Sample Maker")
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertNil(imported.notice)
        XCTAssertFalse(imported.mayDeleteOriginal)
        XCTAssertEqual(try chapterTitles(of: imported.book), ["One: 440 Hz", "Two: 660 Hz, by Track Performer", "Three: 880 Hz"])
        XCTAssertEqual(try manifestSegments(of: imported.book).map(\.clips), [
            [AudioClip(file: "album.wav", startTime: 0, endTime: 1)],
            [AudioClip(file: "album.wav", startTime: 1, endTime: 187.0 / 75)],
            [AudioClip(file: "album.wav", startTime: 187.0 / 75, endTime: 0)],
        ])
        // The album lasts 5 seconds, so its last section is the rest of it.
        let times = try sectionTimes(of: imported.book)
        XCTAssertEqual(times.map(\.start), [0, 1, 187.0 / 75])
        XCTAssertEqual(times.map(\.duration).reduce(0, +), 5, accuracy: 0.01)
        XCTAssertEqual(try audioFolderNames(of: imported.book), ["album.wav", "manifest.json"])
        XCTAssertEqual(try snapshot(of: folder), before)
    }

    /// The Latin-1 sample of two files imports both, the second file's track
    /// beginning at that file's start, under the sheet's accented title.
    func testTheTwoFilesSheetImportsBothFiles() throws {
        let folder = try copySampleFolder("cue")

        let imported = try FileImportService.importCueSheetWithReport(
            from: folder.appendingPathComponent("two-files.cue"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "Two files, café")
        XCTAssertEqual(imported.book.author, Book.unknownAuthor)
        XCTAssertEqual(try chapterTitles(of: imported.book), ["Part one, first half", "Part one, second half", "Part two"])
        XCTAssertEqual(try sectionTimes(of: imported.book).map(\.start), [0, 1, 0])
        XCTAssertEqual(try audioFolderNames(of: imported.book), ["manifest.json", "part1.wav", "part2.wav"])
    }

    /// A sheet that names one file it has and one it hasn't imports the one,
    /// and its notice names the other with why, as a playlist's does.
    func testANameNotFoundIsToldInTheNotice() throws {
        try AudioTestFixtures.writeSilence(to: sources.appendingPathComponent("book.wav"), duration: 2)
        let sheet = try write("""
        FILE "book.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Opening"
            INDEX 01 00:00:00
        FILE "missing.wav" WAVE
          TRACK 02 AUDIO
            TITLE "Lost"
            INDEX 01 00:00:00
        """, to: "mixed.cue")

        let imported = try FileImportService.importCueSheetWithReport(from: sheet, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), ["Opening"])
        XCTAssertEqual(imported.notice, "TextMouth skipped 1 entry of “mixed.cue”: “missing.wav” (not found).")
        XCTAssertEqual(imported.announcement, imported.notice)
    }

    /// A sheet that names no file it can use, one with no audio track that
    /// begins anywhere, and one whose tracks run past the end of its audio
    /// are each refused while the source is read, in words, and leave
    /// nothing in the library.
    func testSheetsThatPlaceNothingAreRefusedInWords() throws {
        try AudioTestFixtures.writeSilence(to: sources.appendingPathComponent("short.wav"), duration: 2)
        let noFile = try write("FILE \"gone.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n", to: "no-file.cue")
        let noTrack = try write("FILE \"short.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 00 00:00:00\n", to: "no-track.cue")
        let tooLate = try write("""
        FILE "short.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 01:00:00
        """, to: "too-late.cue")

        XCTAssertEqual(
            try refusal(of: noFile).errorDescription,
            "Could not import “no-file.cue”. Reading the file failed: It names no audio file in its own folder that "
                + "TextMouth can import. It skipped 1 entry: “gone.wav” (not found)."
        )
        XCTAssertEqual(try refusal(of: noTrack).underlying as? CueSheetError, .noTracks)
        XCTAssertEqual(
            try refusal(of: noTrack).errorDescription,
            "Could not import “no-track.cue”. Reading the file failed: It lists no audio track with a start that TextMouth can read."
        )
        XCTAssertEqual(try refusal(of: tooLate).underlying as? CueSheetError, .timesPastAudio)
        XCTAssertEqual(
            CueSheetError.timesPastAudio.errorDescription,
            "Its tracks run past the end of the audio it names, so it was made for another copy of that audio."
        )
        XCTAssertEqual(try libraryFolderEntries(), [])
    }

    /// A folder named like a sheet is no sheet to the import, which takes
    /// it for the folder it is; a file of the extension in any case is one.
    func testOnlyAFileNamedLikeASheetIsOne() throws {
        let folder = sources.appendingPathComponent("Disc.cue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sheet = try write("", to: "ALBUM.CUE")

        XCTAssertFalse(FileImportService.isCueSheetFile(folder))
        XCTAssertTrue(FileImportService.isCueSheetFile(sheet))
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.cue-sheet" })
    }

    /// The same sheet imported twice is known by the same checksum, a
    /// duplicate; a sheet changed in one word is another.
    func testTheSameSheetImportedTwiceIsADuplicate() throws {
        let folder = try copySampleFolder("cue")
        let sheet = folder.appendingPathComponent("album.cue")

        let first = try FileImportService.importCueSheetWithReport(from: sheet, toFolder: folderPath)
        let second = try FileImportService.importCueSheetWithReport(from: sheet, toFolder: folderPath)
        let text = try String(contentsOf: sheet, encoding: .utf8).replacingOccurrences(of: "One: 440", with: "Uno: 440")
        try Data(text.utf8).write(to: sheet)
        let changed = try FileImportService.importCueSheetWithReport(from: sheet, toFolder: folderPath)

        XCTAssertEqual(first.book.md5Hash, second.book.md5Hash)
        XCTAssertNotEqual(first.book.md5Hash, changed.book.md5Hash)
    }

    // MARK: - Sheets in a Folder or a ZIP

    /// The sample folder, imported as a folder, is arranged by both its
    /// sheets in Finder's order, the album's tracks first, under the
    /// folder's name since the two sheets' titles differ; the sheets travel
    /// with the tracks.
    func testAFolderIsArrangedByItsSheets() throws {
        let folder = try copySampleFolder("cue")

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(imported.book.title, "cue")
        XCTAssertEqual(try chapterTitles(of: imported.book), [
            "One: 440 Hz", "Two: 660 Hz, by Track Performer", "Three: 880 Hz",
            "Part one, first half", "Part one, second half", "Part two",
        ])
        XCTAssertNil(imported.notice)
        XCTAssertEqual(try audioFolderNames(of: imported.book), [
            "album.cue", "album.wav", "manifest.json", "part1.wav", "part2.wav", "two-files.cue",
        ])
    }

    /// A ZIP of the album and its sheet imports with the sheet's headings,
    /// title, and author, as the folder does.
    func testAZipIsArrangedByItsSheet() throws {
        let zip = try makeTemporaryZip(prefix: "cue-album", entries: [
            "Album/album.wav": try Data(contentsOf: CueSheetTests.sample("cue/album.wav")),
            "Album/album.cue": try Data(contentsOf: CueSheetTests.sample("cue/album.cue")),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }

        let imported = try FileImportService.importAudioZipWithReport(from: zip, toFolder: folderPath)

        XCTAssertEqual(imported.book.title, "Three Tracks — café")
        XCTAssertEqual(imported.book.author, "Sample Maker")
        XCTAssertEqual(try chapterTitles(of: imported.book), ["One: 440 Hz", "Two: 660 Hz, by Track Performer", "Three: 880 Hz"])
    }

    /// The tracks no sheet plays follow the sheet's sections, each a section
    /// titled by its file's name.
    func testTracksNoSheetPlaysFollowTheSheetsSections() throws {
        let folder = try copySampleFolder("cue")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("two-files.cue"))

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), [
            "One: 440 Hz", "Two: 660 Hz, by Track Performer", "Three: 880 Hz", "part1", "part2",
        ])
    }

    /// A folder whose manifest.json arranges it imports by the manifest, as
    /// it always has, whatever its sheet says.
    func testAManifestArrangesTheFolderWhateverItsSheetSays() throws {
        let folder = sources.appendingPathComponent("Arranged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["album.wav", "album.cue"] {
            try FileManager.default.copyItem(at: CueSheetTests.sample("cue/\(name)"), to: folder.appendingPathComponent(name))
        }
        try Data(#"{"tracks": [{"file": "album.wav", "title": "The Whole Album"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), ["The Whole Album"])
        XCTAssertNil(AudioManifest.read(inAudioFolder: URL(fileURLWithPath: imported.book.filePath))?.manifest.segments)
        XCTAssertFalse(try audioFolderNames(of: imported.book).contains("album.cue"))
    }

    /// A folder whose sheet names none of its audio, and one whose sheet's
    /// tracks run past the end of its audio, import their tracks as they
    /// would without the sheet, each saying why the sheet was not used.
    func testASheetThatCannotArrangeTheFolderLeavesItAsItWasAndSaysWhy() throws {
        let unrelated = sources.appendingPathComponent("Unrelated", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: unrelated.appendingPathComponent("tone.wav"), duration: 2)
        try Data("FILE \"elsewhere.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n".utf8)
            .write(to: unrelated.appendingPathComponent("other.cue"))
        let late = sources.appendingPathComponent("Late", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: late.appendingPathComponent("tone.wav"), duration: 2)
        try Data("FILE \"tone.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n".utf8)
            .write(to: late.appendingPathComponent("late.cue"))

        let unrelatedBook = try FileImportService.importAudioFolderWithReport(from: unrelated, toFolder: folderPath)
        let lateBook = try FileImportService.importAudioFolderWithReport(from: late, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: unrelatedBook.book), ["tone"])
        XCTAssertEqual(
            unrelatedBook.notice,
            "The cue sheet “other.cue” names none of the audio beside it, so its headings were not used."
        )
        XCTAssertEqual(try chapterTitles(of: lateBook.book), ["tone"])
        XCTAssertEqual(
            lateBook.notice,
            "The tracks of the cue sheet “late.cue” run past the end of its audio, so its headings were not used."
        )
        XCTAssertEqual(
            CueSheetWording.sheetUnused("a.cue", because: .unreadable),
            "TextMouth could not read the cue sheet “a.cue”, so its headings were not used."
        )
    }

    /// A folder of tracks without a sheet imports exactly as before: one
    /// heading per track, no manifest written, and the same checksum.
    func testAFolderWithoutASheetImportsAsBefore() throws {
        let folder = sources.appendingPathComponent("Plain", isDirectory: true)
        for name in ["01 First.wav", "02 Second.wav"] {
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(name), duration: 1)
        }
        let expectedHash = try FileImportService.folderHash(of: ["01 First.wav", "02 Second.wav"], in: folder)

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), ["01 First", "02 Second"])
        XCTAssertEqual(try audioFolderNames(of: imported.book), ["01 First.wav", "02 Second.wav"])
        XCTAssertEqual(imported.book.md5Hash, expectedHash)
        XCTAssertNil(imported.notice)
    }

    // MARK: - Audacity Labels Beside Tracks (FMT06)

    /// A label file beside a folder's one audio file gives it a heading per
    /// label, a label without text named by its place, each beginning at
    /// its label's start to the nearest 1/75 second; the label file travels
    /// with the track.
    func testALabelFileBesideTheOneTrackGivesItsHeadings() throws {
        let folder = try folderWithLabels(["labels.txt"])

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), [
            "Point at the start", "Region: second tone, café", "Point inside the third tone", "Label 4",
        ])
        // 2.5 seconds is 187.5 frames, rounded to 188: within a frame.
        let starts = try sectionTimes(of: imported.book).map(\.start)
        XCTAssertEqual(starts.count, 4)
        for (found, expected) in zip(starts, [0, 1, 2.5, 3]) {
            XCTAssertEqual(found, expected, accuracy: 1.0 / 75)
        }
        XCTAssertNil(imported.notice)
        XCTAssertEqual(try audioFolderNames(of: imported.book), ["labels.txt", "manifest.json", "tone4.wav"])
        XCTAssertEqual(CueSheetWording.untitledLabel(number: 4), "Label 4")
    }

    /// Of two tracks, a label file goes with the one of its own stem; and
    /// the sample folder's two label files for its one track give the
    /// headings of the first in Finder's order, the other passed over.
    func testALabelFileGoesWithTheTrackOfItsStem() throws {
        let folder = try folderWithLabels([])
        try FileManager.default.copyItem(
            at: CueSheetTests.sample("audacity-labels/tone4.wav"), to: folder.appendingPathComponent("other.wav")
        )
        try FileManager.default.copyItem(
            at: CueSheetTests.sample("audacity-labels/labels-spectral.txt"), to: folder.appendingPathComponent("other.txt")
        )

        let paired = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)
        let sample = try FileImportService.importAudioFolderWithReport(from: try copySampleFolder("audacity-labels"), toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: paired.book), ["Point with frequency", "Region, high only", "tone4"])
        XCTAssertEqual(try chapterTitles(of: sample.book), ["Point with frequency", "Region, high only"])
    }

    /// A label file beside two tracks of neither's stem pairs with none and
    /// says so, and the tracks import as they are; a text file that is no
    /// label file is passed over in silence and not copied.
    func testALabelFileOfNoTracksStemIsUnusedAndOtherTextIsIgnored() throws {
        let folder = try folderWithLabels(["labels.txt"])
        try FileManager.default.copyItem(
            at: CueSheetTests.sample("audacity-labels/tone4.wav"), to: folder.appendingPathComponent("second.wav")
        )
        try Data("Verse one\nVerse two\n".utf8).write(to: folder.appendingPathComponent("lyrics.txt"))

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), ["second", "tone4"])
        XCTAssertEqual(
            imported.notice,
            "The label file “labels.txt” matches no audio file beside it by name, so its headings were not used."
        )
        XCTAssertFalse(try audioFolderNames(of: imported.book).contains("lyrics.txt"))
    }

    /// Labels past the end of their track leave it as it was, saying why.
    func testLabelsPastTheTracksEndAreNotUsed() throws {
        let folder = try folderWithLabels([])
        try Data("0\t0\tStart\n90\t90\tLong after\n".utf8).write(to: folder.appendingPathComponent("tone4.txt"))

        let imported = try FileImportService.importAudioFolderWithReport(from: folder, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book), ["tone4"])
        XCTAssertEqual(
            imported.notice,
            "The labels of the label file “tone4.txt” run past the end of its audio, so its headings were not used."
        )
    }

    // MARK: - Helpers

    /// A folder in the sandbox holding the label sample's tone, and the
    /// label files of that sample named `labelFiles`.
    private func folderWithLabels(_ labelFiles: [String]) throws -> URL {
        let folder = sources.appendingPathComponent("Labels \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["tone4.wav"] + labelFiles {
            try FileManager.default.copyItem(at: CueSheetTests.sample("audacity-labels/\(name)"), to: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// A copy of the sample folder `name` in this test's sandbox.
    private func copySampleFolder(_ name: String) throws -> URL {
        let copy = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: CueSheetTests.sample(name), to: copy)
        return copy
    }

    /// Writes `text` to `path` in the sandbox, making its folders, and
    /// returns the file.
    private func write(_ text: String, to path: String) throws -> URL {
        let url = sources.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The failure of importing `sheet`, which must be refused while the
    /// source is read.
    private func refusal(of sheet: URL, file: StaticString = #filePath, line: UInt = #line) throws -> ImportFailure {
        do {
            _ = try FileImportService.importCueSheetWithReport(from: sheet, toFolder: folderPath)
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step, .readingSource, file: file, line: line)
            return failure
        }
        XCTFail("\(sheet.lastPathComponent) was imported, not refused", file: file, line: line)
        throw NotRefused()
    }

    /// Thrown after a failed assertion that a sheet was refused, to end the
    /// test that asked.
    private struct NotRefused: Error {}

    /// The headings of the book's chapters, in order, as the reader reads it.
    private func chapterTitles(of book: Book) throws -> [String] {
        try BookContentAnalysisService.load(book: book).content.chapters.map(\.title)
    }

    /// Where each of the book's sections starts in its first file, and how
    /// long it plays, as the book's index records them.
    private func sectionTimes(of book: Book) throws -> [(start: TimeInterval, duration: TimeInterval)] {
        try BookContentAnalysisService.load(book: book).index.chapters.map { chapter in
            let audio = try XCTUnwrap(chapter.audio)
            return (audio.startTime, audio.duration)
        }
    }

    /// The sections the book's manifest.json gives, exactly as written.
    private func manifestSegments(of book: Book) throws -> [AudioSegment] {
        let found = try XCTUnwrap(AudioManifest.read(inAudioFolder: URL(fileURLWithPath: book.filePath)))
        return try XCTUnwrap(found.manifest.segments)
    }

    /// The names at the top of the book's folder of tracks, sorted.
    private func audioFolderNames(of book: Book) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: book.filePath).sorted()
    }

    /// Every file under `folder` with its bytes, by its path from `folder`,
    /// to show that an import changed nothing.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
        }
        return files
    }

    /// The names in this test's library folder; none when it does not exist.
    private func libraryFolderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }
}
