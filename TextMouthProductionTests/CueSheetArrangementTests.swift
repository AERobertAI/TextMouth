import XCTest
@testable import TextMouth

/// The sections cue sheets make of a book's audio (FMT24,
/// `CueSheetArrangement`): where each track's section begins and ends, across
/// files, its heading, and how a sheet's files are found beside it, with the
/// fallbacks to a file of the same stem. Nothing is played or imported.
final class CueSheetArrangementTests: XCTestCase {
    // MARK: - Sections

    /// The album sample makes three sections of its one file, each running to
    /// the next track's start and the last to the file's end; the second's
    /// heading names its own performer, who is not the sheet's.
    func testTheAlbumSampleMakesThreeSectionsOfItsFile() throws {
        let sheet = try CueSheet.read(at: CueSheetTests.sample("cue/album.cue"))
        let sections = CueSheetArrangement.sections(of: sheet, files: ["album.wav"], author: "Sample Maker")

        XCTAssertEqual(sections.map(\.title), ["One: 440 Hz", "Two: 660 Hz, by Track Performer", "Three: 880 Hz"])
        XCTAssertEqual(sections.map(\.clips), [
            [AudioClip(file: "album.wav", startTime: 0, endTime: 1)],
            [AudioClip(file: "album.wav", startTime: 1, endTime: 187.0 / 75)],
            [AudioClip(file: "album.wav", startTime: 187.0 / 75, endTime: 0)],
        ])
    }

    /// The two-files sample's second file starts a track at its own start,
    /// so the track before plays to the end of the first file and no more.
    func testTheTwoFilesSampleMakesSectionsOfBothFiles() throws {
        let sheet = try CueSheet.read(at: CueSheetTests.sample("cue/two-files.cue"))
        let sections = CueSheetArrangement.sections(of: sheet, files: ["part1.wav", "part2.wav"], author: nil)

        XCTAssertEqual(sections.map(\.clips), [
            [AudioClip(file: "part1.wav", startTime: 0, endTime: 1)],
            [AudioClip(file: "part1.wav", startTime: 1, endTime: 0)],
            [AudioClip(file: "part2.wav", startTime: 0, endTime: 0)],
        ])
    }

    /// A pregap at the start of the next file (the layout that puts each gap
    /// before its track) is played at the end of the track before, as a CD
    /// player plays it; a file with no track of its own plays whole within
    /// the track before; and the first track takes in everything before its
    /// start, the files before its own included.
    func testEveryMomentOfTheAudioIsUnderAHeading() {
        let sheet = CueSheet.parse("""
        FILE "intro.wav" WAVE
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
        FILE "between.wav" WAVE
        FILE "02.wav" WAVE
          TRACK 02 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:01:30
        FILE "after.wav" WAVE
        """)
        let sections = CueSheetArrangement.sections(
            of: sheet, files: ["intro.wav", "01.wav", "between.wav", "02.wav", "after.wav"], author: nil
        )
        XCTAssertEqual(sections.map(\.clips), [
            [
                AudioClip(file: "intro.wav", startTime: 0, endTime: 0),
                AudioClip(file: "01.wav", startTime: 0, endTime: 0),
                AudioClip(file: "between.wav", startTime: 0, endTime: 0),
                AudioClip(file: "02.wav", startTime: 0, endTime: 1.4),
            ],
            [
                AudioClip(file: "02.wav", startTime: 1.4, endTime: 0),
                AudioClip(file: "after.wav", startTime: 0, endTime: 0),
            ],
        ])
        XCTAssertEqual(sections.map(\.title), ["Track 1", "Track 2"])
    }

    /// A track that does not begin after the track before it (out of order,
    /// or at the same place) is passed over, as is a track whose file was
    /// not found, and that file is left out of every section.
    func testTracksOutOfOrderAndTracksOfMissingFilesArePassedOver() {
        let sheet = CueSheet.parse("""
        FILE "a.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:10:00
          TRACK 02 AUDIO
            INDEX 01 00:05:00
          TRACK 03 AUDIO
            INDEX 01 00:10:00
          TRACK 04 AUDIO
            INDEX 01 00:20:00
        FILE "missing.wav" WAVE
          TRACK 05 AUDIO
            INDEX 01 00:00:00
        FILE "c.wav" WAVE
          TRACK 06 AUDIO
            INDEX 01 00:00:00
        """)
        let sections = CueSheetArrangement.sections(of: sheet, files: ["a.wav", nil, "c.wav"], author: nil)
        XCTAssertEqual(sections.map(\.title), ["Track 1", "Track 4", "Track 6"])
        XCTAssertEqual(sections.map(\.clips), [
            [AudioClip(file: "a.wav", startTime: 0, endTime: 20)],
            [AudioClip(file: "a.wav", startTime: 20, endTime: 0)],
            [AudioClip(file: "c.wav", startTime: 0, endTime: 0)],
        ])
    }

    /// A track without a title is "Track N"; a performer who is the book's
    /// author (in any letter case, with spaces around) is left out of the
    /// heading, and any other follows the title after ", by".
    func testHeadingsNameUntitledTracksAndOtherPerformers() {
        let untitled = CueSheet.Track(number: 7, title: nil, performer: nil, fileIndex: 0, startFrame: 0)
        let byAuthor = CueSheet.Track(number: 1, title: "Dawn", performer: "  ada okafor ", fileIndex: 0, startFrame: 0)
        let byGuest = CueSheet.Track(number: 2, title: "Dusk", performer: "Bea Ilunga", fileIndex: 0, startFrame: 0)

        XCTAssertEqual(CueSheetArrangement.heading(of: untitled, author: "Ada Okafor"), "Track 7")
        XCTAssertEqual(CueSheetArrangement.heading(of: byAuthor, author: "Ada Okafor"), "Dawn")
        XCTAssertEqual(CueSheetArrangement.heading(of: byGuest, author: "Ada Okafor"), "Dusk, by Bea Ilunga")
        XCTAssertEqual(CueSheetArrangement.heading(of: byGuest, author: nil), "Dusk, by Bea Ilunga")
        XCTAssertEqual(CueSheetWording.untitledTrack(number: 12), "Track 12")
        XCTAssertEqual(CueSheetWording.trackHeading(title: "Moonlight", performer: "Ada Okafor"), "Moonlight, by Ada Okafor")
    }

    /// A section fits its file when it begins before the file's end and any
    /// end it gives lies within the file and the parse's tolerance; a file
    /// not measured is taken to fit.
    func testFitsChecksStartsAndEndsAgainstMeasuredLengths() {
        let lengths = ["a.wav": 10.0]
        func fits(_ clip: AudioClip) -> Bool {
            CueSheetArrangement.fits([AudioSegment(title: "t", file: clip.file, startTime: clip.startTime, endTime: clip.endTime)], durations: lengths)
        }
        XCTAssertTrue(fits(AudioClip(file: "a.wav", startTime: 9.9, endTime: 0)))
        XCTAssertFalse(fits(AudioClip(file: "a.wav", startTime: 10, endTime: 0)))
        // The tolerance past a 10-second file is 1.1 seconds.
        XCTAssertTrue(fits(AudioClip(file: "a.wav", startTime: 0, endTime: 11.05)))
        XCTAssertFalse(fits(AudioClip(file: "a.wav", startTime: 0, endTime: 11.2)))
        XCTAssertTrue(fits(AudioClip(file: "unmeasured.wav", startTime: 5_000, endTime: 0)))
    }

    // MARK: - Finding the Files

    /// A name not found beside the sheet falls back to an audio file of the
    /// same stem there (a ripper's .wav compressed to .flac), in any letter
    /// case, and a Windows path to the file of its last part's stem; a name
    /// outside the sheet's folder with no such file beside it is skipped, as
    /// is a second name for a file already found.
    func testNamesFallBackToAFileOfTheSameStemBesideTheSheet() throws {
        // Files are found by their names alone, so they hold no audio.
        let folder = try makeSandboxDirectory("cue-fallback")
        for name in ["Album.FLAC", "notes.txt", "other.mp3"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let sheet = CueSheet.parse("""
        FILE "album.wav" WAVE
        FILE "C:\\Rips\\Other.wav" WAVE
        FILE "../outside.wav" WAVE
        FILE "notes.wav" WAVE
        FILE "album.flac" WAVE
        """)
        let found = CueSheetArrangement.resolvedFiles(of: sheet, at: folder.appendingPathComponent("disc.cue"))

        XCTAssertEqual(found.tracks.map { $0?.path }, ["Album.FLAC", "other.mp3", nil, nil, nil])
        XCTAssertEqual(found.skipped, [
            M3UPlaylist.Skipped(location: "../outside.wav", reason: .outsideFolder),
            M3UPlaylist.Skipped(location: "notes.wav", reason: .missing),
            M3UPlaylist.Skipped(location: "album.flac", reason: .listedBefore),
        ])
    }

    /// The names a sheet skipped are told as a playlist's are, except that
    /// one outside the folder is outside the cue sheet's folder, not a
    /// playlist's; a playlist's own words are as they were.
    func testTheNoticeNamesTheCueSheetsFolder() {
        let skipped = [
            M3UPlaylist.Skipped(location: "../outside.wav", reason: .outsideFolder),
            M3UPlaylist.Skipped(location: "notes.wav", reason: .missing),
            M3UPlaylist.Skipped(location: "album.flac", reason: .listedBefore),
        ]
        let arrangement = CueSheetArrangement(
            title: nil, author: nil, segments: [], files: [],
            skipped: [CueSheetArrangement.SkippedNames(sheet: "disc.cue", entries: skipped)],
            unusedSheets: [CueSheetArrangement.UnusedSheet(name: "Extra/other.cue", reason: .unreadable)]
        )

        XCTAssertEqual(
            arrangement.notice,
            "TextMouth skipped 3 entries of “disc.cue”: “../outside.wav” (outside the cue sheet's folder), "
                + "“notes.wav” (not found), and “album.flac” (listed before). "
                + "TextMouth could not read the cue sheet “Extra/other.cue”, so its headings were not used."
        )
        XCTAssertEqual(M3UPlaylist.SkipReason.outsideFolder.words(listedIn: "cue sheet"), "outside the cue sheet's folder")
        XCTAssertEqual(M3UPlaylist.SkipReason.outsideFolder.words, "outside the playlist's folder")
        XCTAssertEqual(M3UPlaylist.SkipReason.missing.words(listedIn: "cue sheet"), M3UPlaylist.SkipReason.missing.words)
        XCTAssertEqual(
            PlaylistImportWording.notice(playlistName: "mix.m3u", skipped: Array(skipped.prefix(1))),
            "TextMouth skipped 1 entry of “mix.m3u”: “../outside.wav” (outside the playlist's folder)."
        )
    }

    /// A sheet of one file whose name and stem are both gone falls back to
    /// an audio file of the sheet's own stem ("Album.cue" naming
    /// "CDImage.wav" beside "Album.flac"); a sheet of two files does not.
    func testASheetOfOneFileFallsBackToTheSheetsOwnStem() throws {
        let folder = try makeSandboxDirectory("cue-sheet-stem")
        try Data("x".utf8).write(to: folder.appendingPathComponent("Album.flac"))
        let sheetURL = folder.appendingPathComponent("Album.cue")

        let one = CueSheet.parse("FILE \"CDImage.wav\" WAVE\n")
        XCTAssertEqual(CueSheetArrangement.resolvedFiles(of: one, at: sheetURL).tracks.map { $0?.path }, ["Album.flac"])

        let two = CueSheet.parse("FILE \"CDImage.wav\" WAVE\nFILE \"Second.wav\" WAVE\n")
        XCTAssertEqual(CueSheetArrangement.resolvedFiles(of: two, at: sheetURL).tracks.map { $0?.path }, [nil, nil])
    }

    /// A folder's arrangement names the lists whose sections it uses, in
    /// Finder's order, so that, should the book's reading find one of their
    /// sections past its file's end after all, the notice can say whose
    /// headings the tracks were imported without.
    func testAFoldersArrangementNamesTheListsItUses() throws {
        let folder = try makeSandboxDirectory("cue-used").appendingPathComponent("cue", isDirectory: true)
        try FileManager.default.copyItem(at: CueSheetTests.sample("cue"), to: folder)

        let arrangement = try XCTUnwrap(CueSheetArrangement.arranging(folder: folder) { _ in [:] })

        XCTAssertEqual(arrangement.usedLists, ["album.cue", "two-files.cue"])
        XCTAssertEqual(
            arrangement.noticeWithoutItsSections,
            "The headings from “album.cue” and “two-files.cue” run past the end of the audio, so the tracks were imported without them."
        )
    }

    /// The performer every track shares is the book's author when the sheet
    /// names none of its own, so no heading repeats it; the sheet's own
    /// performer wins when it names one.
    func testTheAuthorIsTheSheetsPerformerOrOneEveryTrackShares() throws {
        let folder = try makeSandboxDirectory("cue-author")
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("book.wav"), duration: 2)
        let shared = folder.appendingPathComponent("shared.cue")
        try Data("""
        FILE "book.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Chapter One"
            PERFORMER "Ada Okafor"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Chapter Two"
            PERFORMER "Ada Okafor"
            INDEX 01 00:01:00
        """.utf8).write(to: shared)

        let arrangement = try CueSheetArrangement.arranging(sheetAt: shared) { _ in [:] }
        XCTAssertEqual(arrangement.author, "Ada Okafor")
        XCTAssertEqual(arrangement.segments.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertEqual(arrangement.files.map(\.path), ["book.wav"])
        XCTAssertNil(arrangement.notice)
    }
}
