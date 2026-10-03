import XCTest
@testable import TextMouth

/// A DAISY heading whose narration continues past one audio clip, into
/// other files or other parts of one, plays every clip in order (TODO I03).
/// These tests cover a section's clips as manifest.json stores them, the
/// converter that gathers each heading's clips from a DAISY book's
/// synchronization files, and, end to end, a converted heading spanning
/// three files parsed, indexed, and played.
///
/// Packages are built in memory. Their audio is stand-in bytes, which
/// conversion copies without decoding, except in the end-to-end test,
/// whose audio is silent WAVs.
final class DAISYMultiClipSectionTests: XCTestCase {

    // MARK: - Sections in manifest.json

    /// A section written before sections held several clips names one file
    /// and one time range; it reads as a section of exactly that one clip.
    func testSectionWithoutAClipListReadsAsOneClip() throws {
        let json = #"{"title":"Tide Tables","file":"Disc 1/03.mp3","startTime":12.5,"endTime":40}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.title, "Tide Tables")
        XCTAssertEqual(segment.clips, [AudioClip(file: "Disc 1/03.mp3", startTime: 12.5, endTime: 40)])
        XCTAssertEqual(segment.file, "Disc 1/03.mp3")
        XCTAssertEqual(segment.startTime, 12.5)
        XCTAssertEqual(segment.endTime, 40)
    }

    /// A one-clip section is written exactly as it always was, with no
    /// clip list, so manifests of one-clip sections do not change.
    func testOneClipSectionIsWrittenWithoutAClipList() throws {
        let segment = AudioSegment(title: "Tide Tables", file: "03.mp3", startTime: 12.5, endTime: 40)

        XCTAssertEqual(
            try Self.sortedJSON(segment),
            #"{"endTime":40,"file":"03.mp3","startTime":12.5,"title":"Tide Tables"}"#
        )
    }

    /// A section of several clips lists every clip and reads back the same,
    /// and still keeps its first clip where a reader that knows one clip
    /// per section looks for it.
    func testSeveralClipSectionRoundTripsAndKeepsItsFirstClipWhereOlderReadersLook() throws {
        let segment = try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))
        let data = try JSONEncoder().encode(segment)

        XCTAssertEqual(try JSONDecoder().decode(AudioSegment.self, from: data), segment)
        let older = try JSONDecoder().decode(OneClipSection.self, from: data)
        XCTAssertEqual(older.title, "Harbor Survey")
        XCTAssertEqual(older.file, "a.mp3")
        XCTAssertEqual(older.startTime, 30)
        XCTAssertEqual(older.endTime, 60)
    }

    /// A manifest's sections, of one clip and of several, survive a round
    /// trip through manifest.json together.
    func testManifestKeepsEverySectionsClips() throws {
        let manifest = AudioManifest(
            title: "Harbor Soundings",
            author: "Odile Marchetti",
            segments: [
                AudioSegment(title: "Opening", file: "a.mp3", startTime: 0, endTime: 30),
                try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))
            ]
        )

        let decoded = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(manifest))

        XCTAssertEqual(decoded.segments, manifest.segments)
    }

    /// An empty clip list, as a hand-edited manifest could hold, names no
    /// clip at all; the section's own fields still give its one clip.
    func testEmptyClipListFallsBackToTheSectionsOwnClip() throws {
        let json = #"{"title":"Coda","file":"c.mp3","startTime":1,"endTime":0,"clips":[]}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.clips, [AudioClip(file: "c.mp3", startTime: 1, endTime: 0)])
    }

    /// The clip list, when present, is the section: fields that disagree
    /// with its first clip, as a hand edit can leave them, are ignored.
    func testClipListWinsOverTheFieldsBesideIt() throws {
        let json = #"{"title":"Coda","file":"stale.mp3","startTime":9,"endTime":9.5,"clips":"#
            + #"[{"file":"b.mp3","startTime":0,"endTime":2},{"file":"c.mp3","startTime":0,"endTime":3}]}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.clips, [
            AudioClip(file: "b.mp3", startTime: 0, endTime: 2),
            AudioClip(file: "c.mp3", startTime: 0, endTime: 3)
        ])
        XCTAssertEqual(segment.file, "b.mp3")
    }

    /// A section always plays something, so there is no section of no clips.
    func testSectionNeedsAtLeastOneClip() {
        XCTAssertNil(AudioSegment(title: "Silence", clips: []))
    }

    /// Mapping a section's clips keeps every clip, in order, and the title.
    func testMappingClipsKeepsEveryClipInOrder() throws {
        let segment = try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))

        let shifted = segment.mappingClips { clip in
            AudioClip(file: clip.file, startTime: clip.startTime + 1, endTime: clip.endTime)
        }

        XCTAssertEqual(shifted.title, "Harbor Survey")
        XCTAssertEqual(shifted.clips.map(\.file), ["a.mp3", "b.mp3", "c.mp3"])
        XCTAssertEqual(shifted.clips.map(\.startTime), [31, 1, 1])
    }

    // MARK: - Converting DAISY 3

    /// The heading whose narration spans three audio files gets every clip
    /// in order: the phrases that continue one another in a file play as
    /// one clip, the section ends where the next heading starts, in the
    /// next SMIL file, and every clip's file is copied.
    func testDAISY3HeadingSpanningThreeFilesGetsEveryClipInOrder() throws {
        let audioDirectory = try makeAudioDirectory()

        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: Self.daisy3Package(
                headings: Self.threeFileHeadings,
                smilFiles: Self.threeFileSMILFiles
            ),
            version: .daisy3,
            toDirectory: audioDirectory
        )

        XCTAssertEqual(manifest.title, "Harbor Soundings")
        XCTAssertEqual(Self.describe(manifest.segments), Self.threeFileSections)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).sorted(),
            ["a.mp3", "b.mp3", "c.mp3", "d.mp3", "intro.mp3"]
        )
    }

    /// A section's narration continues into a SMIL file no heading names,
    /// in the order the spine plays the files.
    func testSectionContinuesIntoASMILFileNoHeadingNames() throws {
        let smilFiles = [
            "content/part1.smil": Self.smil([("p1", "a.mp3", 0, 10)]),
            "content/part2.smil": Self.smil([("p2", "b.mp3", 0, 10)]),
            "content/part3.smil": Self.smil([("p3", "c.mp3", 0, 10)])
        ]

        let manifest = try convertDAISY3(
            headings: [("Opening", "content/part1.smil#p1"), ("Closing", "content/part3.smil#p3")],
            smilFiles: smilFiles
        )

        XCTAssertEqual(Self.describe(manifest.segments), [
            "Opening: a.mp3 0.0–10.0, b.mp3 0.0–10.0",
            "Closing: c.mp3 0.0–10.0"
        ])
    }

    /// A spine that leaves out a file a heading starts in cannot give the
    /// playing order; the headings' own order is used, as before.
    func testSpineMissingAHeadingsFileGivesWayToTheHeadingsOrder() throws {
        let smilFiles = [
            "content/part1.smil": Self.smil([("p1", "a.mp3", 0, 10)]),
            "content/part2.smil": Self.smil([("p2", "b.mp3", 0, 10)]),
            "content/part3.smil": Self.smil([("p3", "c.mp3", 0, 10)])
        ]

        let manifest = try convertDAISY3(
            headings: [("Opening", "content/part1.smil#p1"), ("Closing", "content/part3.smil#p3")],
            smilFiles: smilFiles,
            spine: ["content/part1.smil", "content/part2.smil"]
        )

        XCTAssertEqual(Self.describe(manifest.segments), [
            "Opening: a.mp3 0.0–10.0",
            "Closing: c.mp3 0.0–10.0"
        ])
    }

    /// A heading starts where its fragment starts playing: a `text` in a
    /// `par`, before or after the `par`'s audio, starts with that `par`, and
    /// a `seq` starts with the first clip inside it.
    func testHeadingStartsWhereItsFragmentStartsPlaying() throws {
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq id="root">
        <seq id="s1">
        <par id="p1"><text id="t1" src="book.xml#x1"/><audio src="../audio/a.mp3" clipBegin="0:00:00.000" clipEnd="0:00:05.000"/></par>
        <par id="p2"><audio src="../audio/a.mp3" clipBegin="0:00:05.000" clipEnd="0:00:09.000"/><text id="t2" src="book.xml#x2"/></par>
        </seq>
        <seq id="s2">
        <par id="p3"><text src="book.xml#x3"/><audio src="../audio/b.mp3" clipBegin="0:00:00.000" clipEnd="0:00:05.000"/></par>
        </seq>
        </seq></body></smil>
        """

        let manifest = try convertDAISY3(
            headings: [("One", "content/part1.smil#t1"), ("Two", "content/part1.smil#t2"), ("Three", "content/part1.smil#s2")],
            smilFiles: ["content/part1.smil": smil]
        )

        XCTAssertEqual(Self.describe(manifest.segments), [
            "One: a.mp3 0.0–5.0",
            "Two: a.mp3 5.0–9.0",
            "Three: b.mp3 0.0–5.0"
        ])
    }

    /// A heading that the next heading starts at the same place as, such as
    /// a part's heading followed at once by its first chapter's, has no
    /// audio of its own and is left out; the later heading plays it.
    func testHeadingSharingItsStartWithTheNextIsLeftOut() throws {
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq id="root">
        <seq id="part"><par id="p1"><audio src="../audio/a.mp3" clipBegin="0:00:00.000" clipEnd="0:00:05.000"/></par>
        <par id="p2"><audio src="../audio/a.mp3" clipBegin="0:00:05.000" clipEnd="0:00:09.000"/></par></seq>
        </seq></body></smil>
        """

        let manifest = try convertDAISY3(
            headings: [("Part One", "content/part1.smil#part"), ("Chapter 1", "content/part1.smil#p1")],
            smilFiles: ["content/part1.smil": smil]
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Chapter 1: a.mp3 0.0–9.0"])
    }

    /// A heading whose SMIL file holds no audio is left out, as it always
    /// was, rather than playing the next heading's audio.
    func testHeadingWithoutAudioIsLeftOut() throws {
        let textOnly = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        <par id="p0"><text src="book.xml#x0"/></par>
        </seq></body></smil>
        """

        let manifest = try convertDAISY3(
            headings: [("Title Page", "content/part0.smil#p0"), ("Opening", "content/part1.smil#p1")],
            smilFiles: ["content/part0.smil": textOnly, "content/part1.smil": Self.smil([("p1", "a.mp3", 0, 10)])],
            spine: ["content/part0.smil", "content/part1.smil"]
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Opening: a.mp3 0.0–10.0"])
    }

    /// A fragment that names nothing in its SMIL file starts the heading at
    /// the file's first clip, as the converter always fell back.
    func testUnknownFragmentStartsAtItsFilesFirstClip() throws {
        let manifest = try convertDAISY3(
            headings: [("Opening", "content/part1.smil#nowhere")],
            smilFiles: ["content/part1.smil": Self.smil([("p1", "a.mp3", 0, 10), ("p2", "b.mp3", 0, 4)])]
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Opening: a.mp3 0.0–10.0, b.mp3 0.0–4.0"])
    }

    /// A clip of no length plays nothing and is dropped; a clip without an
    /// end plays to the end of its file (an end of 0).
    func testClipsOfNoLengthAreDroppedAndOpenEndedClipsPlayToTheirFilesEnd() throws {
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        <par id="p1"><audio src="../audio/a.mp3" clipBegin="0:00:00.000" clipEnd="0:00:10.000"/></par>
        <par id="p2"><audio src="../audio/a.mp3" clipBegin="0:00:12.000" clipEnd="0:00:12.000"/></par>
        <par id="p3"><audio src="../audio/b.mp3" clipBegin="0:00:05.000"/></par>
        </seq></body></smil>
        """

        let manifest = try convertDAISY3(
            headings: [("Opening", "content/part1.smil#p1")],
            smilFiles: ["content/part1.smil": smil]
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Opening: a.mp3 0.0–10.0, b.mp3 5.0–0.0"])
    }

    /// Clips within `continuityTolerance` of one another in a file join;
    /// clips further apart keep the gap the book's producer left.
    func testOnlyClipsThatContinueOneAnotherJoin() throws {
        let manifest = try convertDAISY3(
            headings: [("Opening", "content/part1.smil#p1")],
            smilFiles: ["content/part1.smil": Self.smil([
                ("p1", "a.mp3", 0, 10),
                ("p2", "a.mp3", 10.04, 20),
                ("p3", "a.mp3", 25, 30)
            ])]
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Opening: a.mp3 0.0–20.0, a.mp3 25.0–30.0"])
    }

    /// Files sharing a name in different folders are copied apart, and each
    /// clip names its own copy.
    func testFilesSharingANameAreCopiedApart() throws {
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        <par id="p1"><audio src="../disc1/track.mp3" clipBegin="0:00:00.000" clipEnd="0:00:10.000"/></par>
        <par id="p2"><audio src="../disc2/track.mp3" clipBegin="0:00:00.000" clipEnd="0:00:08.000"/></par>
        </seq></body></smil>
        """
        let audioDirectory = try makeAudioDirectory()
        var files = Self.daisy3Files(headings: [("Opening", "content/part1.smil#p1")], smilFiles: ["content/part1.smil": smil])
        files["disc1/track.mp3"] = "first disc"
        files["disc2/track.mp3"] = "second disc"

        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: InMemoryDAISYPackage(files), version: .daisy3, toDirectory: audioDirectory
        )

        XCTAssertEqual(Self.describe(manifest.segments), ["Opening: track.mp3 0.0–10.0, track-2.mp3 0.0–8.0"])
        XCTAssertEqual(try String(contentsOf: audioDirectory.appendingPathComponent("track.mp3"), encoding: .utf8), "first disc")
        XCTAssertEqual(try String(contentsOf: audioDirectory.appendingPathComponent("track-2.mp3"), encoding: .utf8), "second disc")
    }

    // MARK: - Converting DAISY 2.02

    /// A DAISY 2.02 heading spanning three audio files gets every clip in
    /// order, exactly as a DAISY 3 heading does.
    func testDAISY202HeadingSpanningThreeFilesGetsEveryClipInOrder() throws {
        let audioDirectory = try makeAudioDirectory()
        let ncc = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="dc:title" content="Harbor Soundings"/>
        <meta name="dc:creator" content="Odile Marchetti"/>
        </head><body>
        <h1 id="h1"><a href="part1.smil#p1">Opening</a></h1>
        <h1 id="h2"><a href="part1.smil#p2">Harbor Survey</a></h1>
        <h1 id="h3"><a href="part2.smil#p7">Closing</a></h1>
        </body></html>
        """
        let files = [
            "ncc.html": ncc,
            "part1.smil": Self.smil202([
                ("p1", "intro.mp3", 0, 30), ("p2", "a.mp3", 30, 45), ("p3", "a.mp3", 45, 60),
                ("p4", "b.mp3", 0, 40), ("p5", "b.mp3", 40, 55.5), ("p6", "c.mp3", 0, 12)
            ]),
            "part2.smil": Self.smil202([("p7", "d.mp3", 0, 20)])
        ].merging(Self.standInAudio(prefix: "")) { text, _ in text }

        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: InMemoryDAISYPackage(files), version: .daisy202, toDirectory: audioDirectory
        )

        XCTAssertEqual(manifest.author, "Odile Marchetti")
        XCTAssertEqual(Self.describe(manifest.segments), Self.threeFileSections)
    }

    // MARK: - End to End

    /// The acceptance case: a DAISY heading whose narration spans three
    /// audio files is converted with every clip, parses to a heading as
    /// long as its clips together (two seconds), and is indexed with every
    /// clip, which the index restores exactly.
    func testHeadingSpanningThreeFilesConvertsParsesAndIndexesEveryClip() async throws {
        let audioDirectory = try convertThreeFileWAVBook()

        let parsed = try await AudioBookParser.parseDirectory(url: audioDirectory)
        let index = BookContentIndex.build(
            from: parsed.content,
            format: .audio,
            audioFilePaths: parsed.filePaths,
            audioSegments: parsed.segments,
            audioBaseURL: audioDirectory
        )

        let survey = try XCTUnwrap(parsed.segments?.last)
        XCTAssertEqual(survey.clips.map(\.file), ["a.wav", "b.wav", "c.wav"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.utf16Length), [10, 20])
        XCTAssertEqual(index.chapters[1].audio?.duration, 2)
        XCTAssertEqual(index.chapters[1].audio?.clips?.count, 3)
        XCTAssertNil(index.validationFailure(for: .audio, audioBaseURL: audioDirectory))
        XCTAssertEqual(index.restoredAudioSegments()?.last, survey)
    }

    /// The converted heading, played as the reader plays it from its start,
    /// plays every clip in order, in the three files, and finishes once.
    @MainActor
    func testConvertedHeadingSpanningThreeFilesPlaysEveryClipInOrder() throws {
        let audioDirectory = try convertThreeFileWAVBook()
        let manifest = try JSONDecoder().decode(
            AudioManifest.self,
            from: Data(contentsOf: audioDirectory.appendingPathComponent("manifest.json"))
        )
        let survey = try XCTUnwrap(manifest.segments?.last)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        var playedFiles: [String] = []
        var finishedCount = 0
        playback.onPositionUpdate = { [weak playback] _ in
            guard let file = playback?.loadedURL?.lastPathComponent, playedFiles.last != file else { return }
            playedFiles.append(file)
        }
        playback.onPlaybackFinished = { finishedCount += 1 }

        XCTAssertTrue(playback.playClips(AudioClipChain(segment: survey, folder: audioDirectory), fromChapterTime: 0))
        XCTAssertTrue(eventually(within: 15) { finishedCount == 1 }, "The heading never finished")
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(playedFiles, ["a.wav", "b.wav", "c.wav"])
        XCTAssertEqual(finishedCount, 1)
        XCTAssertNil(playback.failure)
    }

    // MARK: - Fixtures

    /// The headings of the three-file book: an opening, the heading whose
    /// narration spans three files, and a closing in a second SMIL file.
    private static let threeFileHeadings = [
        ("Opening", "content/part1.smil#p1"),
        ("Harbor Survey", "content/part1.smil#p2"),
        ("Closing", "content/part2.smil#p7")
    ]

    /// The three-file book's SMIL files: the opening; the heading's two
    /// phrases in a.mp3, two in b.mp3, and one in c.mp3; and the closing.
    private static let threeFileSMILFiles = [
        "content/part1.smil": smil([
            ("p1", "intro.mp3", 0, 30),
            ("p2", "a.mp3", 30, 45), ("p3", "a.mp3", 45, 60),
            ("p4", "b.mp3", 0, 40), ("p5", "b.mp3", 40, 55.5),
            ("p6", "c.mp3", 0, 12)
        ]),
        "content/part2.smil": smil([("p7", "d.mp3", 0, 20)])
    ]

    /// The three-file book's sections, as `describe` gives them.
    private static let threeFileSections = [
        "Opening: intro.mp3 0.0–30.0",
        "Harbor Survey: a.mp3 30.0–60.0, b.mp3 0.0–55.5, c.mp3 0.0–12.0",
        "Closing: d.mp3 0.0–20.0"
    ]

    /// Convert a DAISY 3 book of silent WAVs into a new folder, removed when
    /// the test ends, and write its manifest.json there, as an import does.
    /// Its opening plays half a second of intro.wav; its second heading the
    /// second half of a.wav (two phrases), all of b.wav, and c.wav from a
    /// quarter second in: two seconds in three files.
    private func convertThreeFileWAVBook() throws -> URL {
        let audioDirectory = try makeAudioDirectory()
        var audio: [String: Data] = [:]
        for (file, duration) in [("intro.wav", 0.5), ("a.wav", 1.0), ("b.wav", 0.75), ("c.wav", 1.0)] {
            audio["audio/\(file)"] = try Self.silentWAV(lasting: duration)
        }
        let package = InMemoryDAISYPackage(
            text: Self.daisy3Files(
                headings: [("Opening", "content/part1.smil#p1"), ("Harbor Survey", "content/part1.smil#p2")],
                smilFiles: ["content/part1.smil": Self.smil([
                    ("p1", "intro.wav", 0, 0.5),
                    ("p2", "a.wav", 0.5, 0.75), ("p3", "a.wav", 0.75, 1),
                    ("p4", "b.wav", 0, 0.75),
                    ("p5", "c.wav", 0.25, 1)
                ])],
                audioExtension: nil
            ),
            binary: audio
        )
        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: package, version: .daisy3, toDirectory: audioDirectory
        )
        try JSONEncoder().encode(manifest).write(to: audioDirectory.appendingPathComponent("manifest.json"))
        return audioDirectory
    }

    /// Convert the DAISY 3 package of `headings` and `smilFiles` into a new
    /// folder, removed when the test ends.
    private func convertDAISY3(
        headings: [(String, String)],
        smilFiles: [String: String],
        spine: [String]? = nil
    ) throws -> AudioManifest {
        try DAISYAudioConverter.convertToAudioBook(
            from: Self.daisy3Package(headings: headings, smilFiles: smilFiles, spine: spine),
            version: .daisy3,
            toDirectory: try makeAudioDirectory()
        )
    }

    /// A DAISY 3 package (see `daisy3Files`) with stand-in audio.
    private static func daisy3Package(
        headings: [(String, String)],
        smilFiles: [String: String],
        spine: [String]? = nil
    ) -> InMemoryDAISYPackage {
        InMemoryDAISYPackage(daisy3Files(headings: headings, smilFiles: smilFiles, spine: spine))
    }

    /// The text files of a DAISY 3 book: book.opf, whose manifest lists the
    /// SMIL files and whose spine plays `spine` (every SMIL file in name
    /// order when nil), navigation.ncx naming each of `headings` (title and
    /// content source), and the SMIL files. With an audio extension, the
    /// book's audio folder also holds a stand-in file of each name.
    private static func daisy3Files(
        headings: [(String, String)],
        smilFiles: [String: String],
        spine: [String]? = nil,
        audioExtension: String? = "mp3"
    ) -> [String: String] {
        let smilPaths = smilFiles.keys.sorted()
        let items = smilPaths.enumerated().map { number, path in
            "<item id=\"smil\(number)\" href=\"\(path)\" media-type=\"application/smil\"/>"
        }
        let itemRefs = (spine ?? smilPaths).compactMap { path in
            smilPaths.firstIndex(of: path).map { "<itemref idref=\"smil\($0)\"/>" }
        }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/" unique-identifier="uid">
        <metadata><dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:Title>Harbor Soundings</dc:Title><dc:Creator>Odile Marchetti</dc:Creator>
        </dc-metadata></metadata>
        <manifest>
        <item id="ncx" href="navigation.ncx" media-type="application/x-dtbncx+xml"/>
        \(items.joined(separator: "\n"))
        </manifest>
        <spine>\(itemRefs.joined())</spine>
        </package>
        """
        let navPoints = headings.enumerated().map { number, heading in
            "<navPoint id=\"n\(number)\"><navLabel><text>\(heading.0)</text></navLabel>"
                + "<content src=\"\(heading.1)\"/></navPoint>"
        }
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        \(navPoints.joined(separator: "\n"))
        </navMap></ncx>
        """
        var files = smilFiles.merging(["book.opf": opf, "navigation.ncx": ncx]) { smil, _ in smil }
        if let audioExtension {
            files.merge(standInAudio(prefix: "audio/", extension: audioExtension)) { text, _ in text }
        }
        return files
    }

    /// Stand-in audio for every file the fixtures name, in the folder
    /// `prefix`: conversion copies audio without decoding it.
    private static func standInAudio(prefix: String, extension ext: String = "mp3") -> [String: String] {
        let names = ["intro", "a", "b", "c", "d"]
        return Dictionary(uniqueKeysWithValues: names.map { ("\(prefix)\($0).\(ext)", "stand-in audio \($0)") })
    }

    /// A DAISY 3 SMIL file of one `par` per clip, each with its ID, its
    /// audio file in the book's audio folder, and its start and end in
    /// seconds, written as DAISY 3 clock values.
    private static func smil(_ clips: [(String, String, Double, Double)]) -> String {
        let pars = clips.map { id, file, start, end in
            "<par id=\"\(id)\"><text src=\"book.xml#\(id)\"/>"
                + "<audio src=\"../audio/\(file)\" clipBegin=\"\(clock(start))\" clipEnd=\"\(clock(end))\"/></par>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        \(pars.joined(separator: "\n"))
        </seq></body></smil>
        """
    }

    /// A DAISY 2.02 SMIL file of one `par` per clip, its audio beside it and
    /// its times written as "npt" values.
    private static func smil202(_ clips: [(String, String, Double, Double)]) -> String {
        let pars = clips.map { id, file, start, end in
            "<par endsync=\"last\" id=\"\(id)\"><text src=\"content.html#\(id)\"/>"
                + "<audio src=\"\(file)\" clip-begin=\"npt=\(String(format: "%.3f", start))s\" "
                + "clip-end=\"npt=\(String(format: "%.3f", end))s\"/></par>"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        \(pars.joined(separator: "\n"))
        </seq></body></smil>
        """
    }

    /// `seconds` as a DAISY 3 clock value, "H:MM:SS.mmm".
    private static func clock(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(
            format: "%ld:%02ld:%02ld.%03ld",
            milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000
        )
    }

    /// Each section as "title: file start–end, file start–end", which
    /// compare as a whole and read clearly in a failure message.
    private static func describe(_ sections: [AudioSegment]?) -> [String] {
        (sections ?? []).map { section in
            "\(section.title): " + section.clips.map { "\($0.file) \($0.startTime)–\($0.endTime)" }
                .joined(separator: ", ")
        }
    }

    /// The bytes of a WAVE file of `duration` seconds of silence.
    private static func silentWAV(lasting duration: TimeInterval) throws -> Data {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("silence.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: duration)
        return try Data(contentsOf: file)
    }

    /// A new, empty folder for converted audio, removed when the test ends.
    private func makeAudioDirectory() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// One heading's clips in three files: the second half of the first
    /// file, the start of the second, and all of the third (an end of 0
    /// plays to the end of the file).
    private static let threeFiles = [
        AudioClip(file: "a.mp3", startTime: 30, endTime: 60),
        AudioClip(file: "b.mp3", startTime: 0, endTime: 45.5),
        AudioClip(file: "c.mp3", startTime: 0, endTime: 0)
    ]

    /// A section as a release that knew one clip per section decoded it.
    private struct OneClipSection: Decodable {
        var title: String
        var file: String
        var startTime: Double
        var endTime: Double
    }

    /// `segment` as JSON with its keys sorted, so a test can compare it
    /// with the exact text manifest.json holds.
    private static func sortedJSON(_ segment: AudioSegment) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(segment), as: UTF8.self)
    }
}

extension InMemoryDAISYPackage {
    /// A package of `textFiles`, as UTF-8, and `binaryFiles`, such as real
    /// audio, as they are.
    init(text textFiles: [String: String], binary binaryFiles: [String: Data]) {
        files = textFiles.mapValues { Data($0.utf8) }.merging(binaryFiles) { _, binary in binary }
    }
}
