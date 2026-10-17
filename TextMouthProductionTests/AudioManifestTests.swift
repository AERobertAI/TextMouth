import XCTest
@testable import TextMouth

/// The manifest.json an archive of audio tracks can carry: where it is
/// found, how its names are spelled, and how it is read. Each test lays out
/// an audiobook's folder of its own under the temporary directory; the
/// tracks are empty files, since nothing here plays or measures them.
final class AudioManifestTests: XCTestCase {
    /// The audiobook folder this test lays out, removed when it ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Where the Manifest Lies

    /// A manifest at the folder's top level is found there, and names
    /// tracks from the top level, a track in a folder by its folder too.
    func testManifestAtTheTopLevelIsFoundThere() throws {
        try write("{}", to: "manifest.json")
        try write("", to: "Discs/01.ogg")

        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder))

        XCTAssertEqual(location.url.lastPathComponent, "manifest.json")
        XCTAssertEqual(location.url.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(location.prefix, "")
        XCTAssertEqual(location.name(ofTrackAt: "Discs/01.ogg"), "Discs/01.ogg")
        XCTAssertEqual(location.path(ofTrackNamed: "Discs/01.ogg"), "Discs/01.ogg")
    }

    /// Finder's Compress command puts a folder's contents under the
    /// folder's name, with its resource forks in `__MACOSX`: a manifest
    /// made beside the tracks is found inside that one folder, and names
    /// the tracks from there. Hidden entries and `__MACOSX` beside the
    /// folder do not count against it.
    func testManifestInsideTheOnlyFolderIsFoundThere() throws {
        try write("{}", to: "Radio Plays/manifest.json")
        try write("", to: "Radio Plays/elegy.ogg")
        try write("", to: "__MACOSX/Radio Plays/._elegy.ogg")
        try write("", to: ".DS_Store")

        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder))

        XCTAssertEqual(location.url.lastPathComponent, "manifest.json")
        XCTAssertEqual(location.url.deletingLastPathComponent().lastPathComponent, "Radio Plays")
        XCTAssertEqual(location.prefix, "Radio Plays/")
        XCTAssertEqual(location.name(ofTrackAt: "Radio Plays/elegy.ogg"), "elegy.ogg")
        XCTAssertEqual(location.path(ofTrackNamed: "elegy.ogg"), "Radio Plays/elegy.ogg")
    }

    /// A manifest at the top level is the one used, even when the one
    /// folder beside it holds another.
    func testManifestAtTheTopLevelComesFirst() throws {
        try write("{}", to: "manifest.json")
        try write("{}", to: "Radio Plays/manifest.json")

        XCTAssertEqual(try XCTUnwrap(AudioManifestLocation.find(in: folder)).prefix, "")
    }

    /// Two visible folders at the top level are no wrapper: a manifest in
    /// either is not looked for, and only a top-level one would count.
    func testTwoFoldersAtTheTopLevelHaveNoWrapper() throws {
        try write("{}", to: "Part One/manifest.json")
        try write("", to: "Part One/01.ogg")
        try write("", to: "Part Two/02.ogg")

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A visible file beside the one folder means the folder is no
    /// wrapper either.
    func testAFileBesideTheOneFolderMeansNoWrapper() throws {
        try write("{}", to: "Radio Plays/manifest.json")
        try write("", to: "cover.jpg")

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A wrapper folder without a manifest, and a folder with nothing at
    /// all, have none.
    func testFolderWithoutAManifestHasNone() throws {
        XCTAssertNil(AudioManifestLocation.find(in: folder))
        try write("", to: "Radio Plays/elegy.ogg")
        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A symbolic link to a folder is not a wrapper folder: what it leads
    /// to is not inside the book.
    func testALinkedFolderIsNoWrapper() throws {
        let elsewhere = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Radio Plays"), withDestinationURL: elsewhere)

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    // MARK: - Reading the Manifest

    /// A manifest is read wherever it lies, with its location, and a UTF-8
    /// byte order mark at its start is passed over.
    func testManifestIsReadPastAByteOrderMark() throws {
        let json = Data(#"{"title": "Harbor Plays", "author": "Wenzel Okafor"}"#.utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Radio Plays"), withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + json).write(to: folder.appendingPathComponent("Radio Plays/manifest.json"))

        let found = try XCTUnwrap(AudioManifest.read(inAudioFolder: folder))

        XCTAssertEqual(found.manifest.title, "Harbor Plays")
        XCTAssertEqual(found.manifest.author, "Wenzel Okafor")
        XCTAssertEqual(found.location.prefix, "Radio Plays/")
    }

    /// A manifest that cannot be decoded is read as none, so a book whose
    /// manifest went wrong after its import still opens, in Finder's order.
    func testManifestThatCannotBeDecodedIsReadAsNone() throws {
        try write(#"{"title": 7}"#, to: "manifest.json")
        XCTAssertNil(AudioManifest.read(inAudioFolder: folder))
        try write("not JSON at all", to: "manifest.json")
        XCTAssertNil(AudioManifest.read(inAudioFolder: folder))
    }

    // MARK: - The Book's Title and Author

    /// A manifest with no title or author, or with only blank ones, gives
    /// the book none, so the book keeps the archive's name and the unknown
    /// author; real text comes through untouched, spaces and all.
    func testABlankTitleOrAuthorReadsAsNone() {
        XCTAssertNil(AudioManifest().bookTitle)
        XCTAssertNil(AudioManifest().bookAuthor)
        for blank in ["", "   ", " \n\t "] {
            XCTAssertNil(AudioManifest(title: blank, author: blank).bookTitle, "title \(blank.debugDescription)")
            XCTAssertNil(AudioManifest(title: blank, author: blank).bookAuthor, "author \(blank.debugDescription)")
        }
        let manifest = AudioManifest(title: " Harbor Plays ", author: "Wenzel Okafor")
        XCTAssertEqual(manifest.bookTitle, " Harbor Plays ")
        XCTAssertEqual(manifest.bookAuthor, "Wenzel Okafor")
        // The stored fields keep every byte a hand edit gave them.
        XCTAssertEqual(AudioManifest(title: "  ").title, "  ")
    }

    // MARK: - The Tracks List

    /// The manifest the tracks list was designed with, as a person writes
    /// it: group headings, tracks with and without titles and pauses, and a
    /// track given by its name alone.
    static let exampleJSON = """
    {
      "title": "Radio Dramas",
      "author": "Various",
      "pauseBetweenTracksMs": 250,
      "tracks": [
        { "heading": "Season One" },
        { "file": "where_is_everybody.ogg", "title": "Where Is Everybody?" },
        { "file": "one_for_the_angels.ogg", "title": "One for the Angels", "pauseAfterMs": 1500 },
        "mr_denton_on_dooms_day.ogg",
        { "heading": "Season Two" },
        { "file": "king_nine_will_not_return.ogg" }
      ]
    }
    """

    /// Each entry of the tracks list is read as a track or a group heading:
    /// a string is a track's file alone, and an object a track with its
    /// title and pause, or a heading.
    func testTracksAreReadFromStringsAndObjects() throws {
        let manifest = try AudioManifest.decoded(from: Data(Self.exampleJSON.utf8))

        XCTAssertEqual(manifest.title, "Radio Dramas")
        XCTAssertEqual(manifest.author, "Various")
        XCTAssertEqual(manifest.pauseBetweenTracksMs, 250)
        XCTAssertEqual(manifest.tracks, [
            .heading("Season One"),
            .track(AudioManifestTrack(file: "where_is_everybody.ogg", title: "Where Is Everybody?")),
            .track(AudioManifestTrack(file: "one_for_the_angels.ogg", title: "One for the Angels", pauseAfterMs: 1500)),
            .track(AudioManifestTrack(file: "mr_denton_on_dooms_day.ogg")),
            .heading("Season Two"),
            .track(AudioManifestTrack(file: "king_nine_will_not_return.ogg"))
        ])
        XCTAssertTrue(manifest.arrangesByTracks)
    }

    /// A manifest is written as it is read: a track with nothing but its
    /// file as the file's name, everything else as an object holding only
    /// the keys that have values, and no key at all for what is absent.
    func testTracksAreWrittenAsTheyAreRead() throws {
        let manifest = try AudioManifest.decoded(from: Data(Self.exampleJSON.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let written = try encoder.encode(manifest)

        XCTAssertEqual(
            String(decoding: written, as: UTF8.self),
            #"{"author":"Various","pauseBetweenTracksMs":250,"title":"Radio Dramas","tracks":["#
                + #"{"heading":"Season One"},{"file":"where_is_everybody.ogg","title":"Where Is Everybody?"},"#
                + #"{"file":"one_for_the_angels.ogg","pauseAfterMs":1500,"title":"One for the Angels"},"#
                + #""mr_denton_on_dooms_day.ogg",{"heading":"Season Two"},"king_nine_will_not_return.ogg"]}"#
        )
        XCTAssertEqual(try AudioManifest.decoded(from: written).tracks, manifest.tracks)
    }

    /// A manifest without the newer keys, as the DAISY converter writes,
    /// is written exactly as before they existed.
    func testManifestWithoutTheNewerKeysIsWrittenAsBefore() throws {
        let manifest = AudioManifest(
            title: "Ferry Log",
            author: "Odile Marchetti",
            segments: [AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1.5)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(
            String(decoding: try encoder.encode(manifest), as: UTF8.self),
            #"{"author":"Odile Marchetti","segments":[{"endTime":1.5,"file":"a.wav","startTime":0,"title":"Opening"}],"title":"Ferry Log"}"#
        )
    }

    /// The newer keys are read only when they hold what they should, and as
    /// absent otherwise, so a manifest read before they existed, whatever it
    /// held under those names, is read as it was: its title still counts.
    func testNewerKeysOfTheWrongKindAreReadAsAbsent() throws {
        let manifests = [
            #"{"title": "Harbor Plays", "pauseBetweenTracksMs": "slow", "tracks": [5]}"#,
            #"{"title": "Harbor Plays", "tracks": [{"file": "a.ogg", "heading": "Both"}]}"#,
            #"{"title": "Harbor Plays", "tracks": [{"title": "Neither"}]}"#,
            #"{"title": "Harbor Plays", "tracks": {"file": "a.ogg"}}"#
        ]
        for json in manifests {
            let manifest = try AudioManifest.decoded(from: Data(json.utf8))
            XCTAssertEqual(manifest.title, "Harbor Plays", json)
            XCTAssertNil(manifest.tracks, json)
            XCTAssertNil(manifest.pauseBetweenTracksMs, json)
            XCTAssertFalse(manifest.arrangesByTracks, json)
        }
    }

    // MARK: - Arranging the Tracks

    /// The tracks list gives the book its order and titles, and its group
    /// headings, each beginning at the next track listed; every track after
    /// the first group heading is a level 2 heading under it. A track the
    /// list leaves out follows, in Finder's order, with a level 1 heading of
    /// its own, outside any group.
    func testTracksArrangeOrderTitlesAndGroupHeadings() throws {
        let manifest = try AudioManifest.decoded(from: Data(Self.exampleJSON.utf8))
        let names = [
            "where_is_everybody.ogg", "one_for_the_angels.ogg", "mr_denton_on_dooms_day.ogg",
            "king_nine_will_not_return.ogg", "the_lonely.ogg", "elegy.ogg"
        ]

        let plan = AudioTrackPlan(arranging: names, by: manifest)

        XCTAssertEqual(plan.tracks.map(describe), [
            "where_is_everybody.ogg | Where Is Everybody? | level 2 | group Season One",
            "one_for_the_angels.ogg | One for the Angels | level 2",
            "mr_denton_on_dooms_day.ogg | mr_denton_on_dooms_day | level 2",
            "king_nine_will_not_return.ogg | king_nine_will_not_return | level 2 | group Season Two",
            "elegy.ogg | elegy | level 1",
            "the_lonely.ogg | the_lonely | level 1"
        ])
    }

    /// Tracks listed before the first group heading keep level 1 headings;
    /// those after it are level 2, whether or not a heading of their own
    /// begins at them.
    func testTracksBeforeTheFirstGroupHeadingKeepLevelOne() throws {
        let manifest = try AudioManifest.decoded(from: Data(
            #"{"tracks": ["prologue.ogg", {"heading": "Act One"}, "scene1.ogg", "scene2.ogg"]}"#.utf8
        ))

        let plan = AudioTrackPlan(arranging: ["scene1.ogg", "prologue.ogg", "scene2.ogg"], by: manifest)

        XCTAssertEqual(plan.tracks.map(describe), [
            "prologue.ogg | prologue | level 1",
            "scene1.ogg | scene1 | level 2 | group Act One",
            "scene2.ogg | scene2 | level 2"
        ])
    }

    /// A tracks list without group headings gives every track a level 1
    /// heading, as a book of tracks has always had.
    func testTracksWithoutGroupHeadingsAreAllLevelOne() throws {
        let manifest = try AudioManifest.decoded(from: Data(
            #"{"tracks": ["b.ogg", {"file": "a.ogg", "title": "First Light"}]}"#.utf8
        ))

        let plan = AudioTrackPlan(arranging: ["a.ogg", "b.ogg", "c.ogg"], by: manifest)

        XCTAssertEqual(plan.tracks.map(describe), [
            "b.ogg | b | level 1",
            "a.ogg | First Light | level 1",
            "c.ogg | c | level 1"
        ])
    }

    /// Without a tracks list, order and chapters arrange the book exactly as
    /// they always have; so they do in a manifest that has a tracks list
    /// too, which an import refuses, but which a book imported before the
    /// list existed may hold.
    func testOrderAndChaptersArrangeAsBefore() throws {
        let names = ["Disc 1/01.ogg", "Disc 1/02.ogg", "Disc 2/01.ogg"]
        let older = AudioManifest(chapters: ["Disc 2/01.ogg": "Night Shift"], order: ["Disc 2/01.ogg", "Disc 2/01.ogg"])
        var both = older
        both.tracks = [.heading("Never Used"), .track(AudioManifestTrack(file: "Disc 1/02.ogg"))]

        for manifest in [older, both] {
            XCTAssertEqual(AudioTrackPlan(arranging: names, by: manifest).tracks.map(describe), [
                "Disc 2/01.ogg | Night Shift | level 1",
                "Disc 1/01.ogg | 01 | level 1",
                "Disc 1/02.ogg | 02 | level 1"
            ])
        }
        XCTAssertEqual(
            AudioTrackPlan(arranging: names, by: nil).tracks.map(describe),
            ["Disc 1/01.ogg | 01 | level 1", "Disc 1/02.ogg | 02 | level 1", "Disc 2/01.ogg | 01 | level 1"]
        )
    }

    /// A manifest changed after its import is still read as well as it can
    /// be: a name the folder does not hold, or one given twice, is passed
    /// over, and the group heading before it waits for the next track
    /// placed; a blank heading names no group, a heading with no track after
    /// it begins none, and a blank title shows the file's name.
    func testEntriesThatCannotBePlacedArePassedOver() throws {
        let manifest = try AudioManifest.decoded(from: Data(#"""
        {"tracks": [
          {"heading": "  "},
          "a.ogg",
          {"heading": "Part Two"},
          "missing.ogg",
          "a.ogg",
          {"file": "b.ogg", "title": " "},
          {"heading": "Nothing Follows"}
        ]}
        """#.utf8))

        let plan = AudioTrackPlan(arranging: ["b.ogg", "a.ogg"], by: manifest)

        XCTAssertEqual(plan.tracks.map(describe), [
            "a.ogg | a | level 1",
            "b.ogg | b | level 2 | group Part Two"
        ])
    }

    // MARK: - The Pauses Between Tracks

    /// Each track's pause is its own pauseAfterMs, else the book's
    /// pauseBetweenTracksMs, else a quarter of a second; a track the list
    /// leaves out takes the book's; a manifest arranging the older way gives
    /// the book's after every track; without a manifest there is none.
    func testEachTracksPauseComesFromItsEntryTheBookOrTheDefault() throws {
        var manifest = try AudioManifest.decoded(from: Data(Self.exampleJSON.utf8))
        let names = [
            "where_is_everybody.ogg", "one_for_the_angels.ogg", "mr_denton_on_dooms_day.ogg",
            "king_nine_will_not_return.ogg", "the_lonely.ogg"
        ]
        XCTAssertEqual(AudioTrackPlan(arranging: names, by: manifest).tracks.map(\.pauseAfter), [0.25, 1.5, 0.25, 0.25, 0.25])

        manifest.pauseBetweenTracksMs = 1000
        XCTAssertEqual(AudioTrackPlan(arranging: names, by: manifest).tracks.map(\.pauseAfter), [1, 1.5, 1, 1, 1])
        manifest.pauseBetweenTracksMs = nil
        XCTAssertEqual(AudioTrackPlan(arranging: names, by: manifest).tracks.map(\.pauseAfter), [0.25, 1.5, 0.25, 0.25, 0.25])

        let older = AudioManifest(order: ["b.ogg"], pauseBetweenTracksMs: 500)
        XCTAssertEqual(AudioTrackPlan(arranging: ["a.ogg", "b.ogg"], by: older).tracks.map(\.pauseAfter), [0.5, 0.5])
        XCTAssertEqual(AudioTrackPlan(arranging: ["a.ogg", "b.ogg"], by: nil).tracks.map(\.pauseAfter), [0, 0])
    }

    /// A pause outside 0 to 60000 milliseconds, which only a manifest
    /// changed after its import can hold, is brought within that range.
    func testAPauseOutsideItsRangeIsBroughtWithinIt() {
        var manifest = AudioManifest(pauseBetweenTracksMs: 90_000)
        XCTAssertEqual(manifest.pause(after: nil), 60)
        manifest.pauseBetweenTracksMs = -40
        XCTAssertEqual(manifest.pause(after: nil), 0)
        XCTAssertEqual(manifest.pause(after: AudioManifestTrack(file: "a.ogg", pauseAfterMs: 1500)), 1.5)
    }

    /// The pauses between a multi-file book's chapters follow its manifest
    /// track by track, wherever the manifest lies, with none after the last
    /// chapter, which nothing follows; a book without a manifest, and a
    /// segmented book, have none.
    func testThePausesBetweenChaptersFollowTheManifestTrackByTrack() throws {
        for name in ["Radio Plays/a.ogg", "Radio Plays/b.ogg", "Radio Plays/c.ogg"] {
            try write("", to: name)
        }
        try write(#"{"tracks": [{"file": "b.ogg", "pauseAfterMs": 1000}, "a.ogg", "c.ogg"]}"#, to: "Radio Plays/manifest.json")
        let index = multiFileIndex(playing: ["Radio Plays/b.ogg", "Radio Plays/a.ogg", "Radio Plays/c.ogg"])

        let pauses = ChapterPauses.betweenTracks(of: index, inAudioFolder: folder)

        XCTAssertEqual([0, 1, 2, 3].map(pauses.after(chapter:)), [1, 0.25, 0, 0])
        let segmented = BookContentIndex.build(
            fromChapters: index.chapters.map { Chapter(title: $0.title, text: String(repeating: " ", count: 10)) },
            format: .audio,
            audioSegments: ["a", "b", "c"].map {
                AudioSegment(title: $0, file: "Radio Plays/\($0).ogg", startTime: 0, endTime: 1)
            },
            audioBaseURL: folder
        )
        XCTAssertEqual(ChapterPauses.betweenTracks(of: segmented, inAudioFolder: folder), .none)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Radio Plays/manifest.json"))
        XCTAssertEqual(ChapterPauses.betweenTracks(of: index, inAudioFolder: folder), .none)
    }

    /// The pauses between chapters, from any source, are never below 0,
    /// and a chapter past the list has none.
    func testAChaptersPauseIsNeverBelowZero() {
        let pauses = ChapterPauses(afterEachChapter: [1, -2, .nan, .infinity])
        XCTAssertEqual([-1, 0, 1, 2, 3, 4].map(pauses.after(chapter:)), [0, 1, 0, 0, 0, 0])
        XCTAssertEqual(ChapterPauses.none.after(chapter: 0), 0)
    }

    /// No pause anywhere is one value whatever its source: a list of zeros
    /// (what a manifest with no pause gives, one entry per chapter), of
    /// pauses cleaned to 0, and the empty list are all `.none`, and a
    /// trailing run of zeros never makes two otherwise equal pauses differ.
    /// What each chapter is given is unchanged by this.
    func testNoPauseAnywhereIsOneValueWhateverItsSource() {
        XCTAssertEqual(ChapterPauses.none, ChapterPauses(afterEachChapter: [0, 0, 0]))
        XCTAssertEqual(ChapterPauses(afterEachChapter: [-1, .nan, .infinity]), .none)
        XCTAssertEqual(ChapterPauses(afterEachChapter: [0.5, 0]), ChapterPauses(afterEachChapter: [0.5]))
        XCTAssertNotEqual(ChapterPauses(afterEachChapter: [0, 0.5]), ChapterPauses(afterEachChapter: [0.5]))
        XCTAssertNotEqual(ChapterPauses(afterEachChapter: [0.5]), .none)
        // The pause after each chapter is what it was: the dropped entries were all 0.
        let trailing = ChapterPauses(afterEachChapter: [0.5, 0, 0])
        XCTAssertEqual([0, 1, 2, 3].map(trailing.after(chapter:)), [0.5, 0, 0, 0])
        let zeros = ChapterPauses(afterEachChapter: [0, 0, 0])
        XCTAssertEqual([0, 1, 2, 3].map(zeros.after(chapter:)), [0, 0, 0, 0])
        let leading = ChapterPauses(afterEachChapter: [0, 0.5, 0])
        XCTAssertEqual([0, 1, 2].map(leading.after(chapter:)), [0, 0.5, 0])
    }

    // MARK: - Helpers

    /// The index of a multi-file audiobook in this test's folder whose
    /// chapters play `paths` (from the folder) in order, a second each.
    private func multiFileIndex(playing paths: [String]) -> BookContentIndex {
        let chapters = paths.enumerated().map { number, path in
            Chapter(
                title: path,
                text: String(repeating: " ", count: 10),
                headings: [Heading(level: 1, text: path, chapterIndex: number, characterOffset: 0)]
            )
        }
        return BookContentIndex.build(
            fromChapters: chapters,
            format: .audio,
            audioFilePaths: paths.map { folder.appendingPathComponent($0).path },
            audioBaseURL: folder
        )
    }

    /// A planned track as one line, "name | title | level N | group G",
    /// which compares as a whole and reads clearly in a failure message.
    private func describe(_ track: AudioTrackPlan.Track) -> String {
        let group = track.groupHeading.map { " | group \($0)" } ?? ""
        return "\(track.name) | \(track.title) | level \(track.level)\(group)"
    }

    /// Write `text` as UTF-8 to `path` inside this test's folder, making
    /// the folders on the way.
    private func write(_ text: String, to path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
