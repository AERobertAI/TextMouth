import XCTest
@testable import TextMouth

/// An audiobook's headings exported as a CUE sheet (FMT24): the sheet's
/// text, its times, the round trip through TextMouth's own reader, and the
/// Export dialog's Headings item for a book of tracks, a book of sections,
/// and books of one file, whose exact starts come from their files. Nothing
/// is played.
@MainActor
final class ChapterListExportTests: XCTestCase {
    // MARK: - The Sheet's Text

    /// The sheet names the book and its author, a FILE line where each file
    /// begins, and a track per chapter at its start to the nearest frame, in
    /// UTF-8 after a byte-order mark with CRLF line ends; a quotation mark
    /// becomes an apostrophe and a line break a space.
    func testTheSheetsTextIsExact() {
        let entries = [
            ChapterListEntry(title: "Opening", file: "Tides/01 - Opening.mp3", start: 0),
            ChapterListEntry(title: "Say \"Ahoy\"\nTwice", file: "Tides/01 - Opening.mp3", start: 61.5),
            ChapterListEntry(title: "Ebb", file: "Tides/02 - Ebb.flac", start: 0),
        ]

        let text = CueSheetWriter.text(of: entries, title: "Tides", performer: "Ada Okafor")

        XCTAssertEqual(text, [
            "TITLE \"Tides\"",
            "PERFORMER \"Ada Okafor\"",
            "FILE \"Tides/01 - Opening.mp3\" MP3",
            "  TRACK 01 AUDIO",
            "    TITLE \"Opening\"",
            "    INDEX 01 00:00:00",
            "  TRACK 02 AUDIO",
            "    TITLE \"Say 'Ahoy' Twice\"",
            "    INDEX 01 01:01:38",
            "FILE \"Tides/02 - Ebb.flac\" WAVE",
            "  TRACK 03 AUDIO",
            "    TITLE \"Ebb\"",
            "    INDEX 01 00:00:00",
        ].map { $0 + "\r\n" }.joined())
        let bytes = CueSheetWriter.fileBytes(of: entries, title: "Tides", performer: nil)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PERFORMER"))
    }

    /// A time is written to the nearest frame of 1/75 second, minutes past
    /// 99 in more digits, and anything that is no time above zero as the
    /// start.
    func testTimesAreWrittenToTheNearestFrame() {
        let times: [(TimeInterval, String)] = [
            (0, "00:00:00"), (1, "00:01:00"), (2.4933, "00:02:37"), (59.999, "01:00:00"), (61.5, "01:01:38"),
            (7_200, "120:00:00"), (-3, "00:00:00"), (.nan, "00:00:00"), (.infinity, "00:00:00"),
        ]
        let mismatches = times.filter { CueSheetWriter.time($0.0) != $0.1 }
            .map { "\($0.0): \(CueSheetWriter.time($0.0)), not \($0.1)" }
        XCTAssertEqual(mismatches, [])
    }

    /// A sheet written here reads back through TextMouth's own reader as the
    /// same titles, files, and starts, to the frame.
    func testAWrittenSheetReadsBackAsTheSameChapters() {
        let entries = (0..<120).map { number in
            ChapterListEntry(title: "Part \(number + 1)", file: number < 60 ? "a.wav" : "b.wav", start: Double(number % 60) * 7.31)
        }

        let sheet = CueSheet.parse(CueSheetWriter.text(of: entries, title: "Long", performer: nil))

        XCTAssertEqual(sheet.title, "Long")
        XCTAssertEqual(sheet.files, ["a.wav", "b.wav"])
        XCTAssertEqual(sheet.tracks.map(\.title), entries.map(\.title))
        XCTAssertEqual(sheet.tracks.map(\.number), Array(1...120), "past 99 the tracks are numbered on")
        let drift = zip(sheet.tracks, entries).map { abs($0.startTime - $1.start) }.max() ?? 0
        XCTAssertLessThanOrEqual(drift, 0.5 / 75 + 1e-9, "each start is within half a frame")
    }

    // MARK: - Exporting a Book's Headings

    /// A book of tracks offers its headings, and exports them as a sheet that
    /// names each track as Audio exports it; exported together, the sheet
    /// and the tracks import again as the same headings.
    func testABookOfTracksExportsASheetOfItsExportedTracks() throws {
        let world = try makeIntegrationWorld("Headings Tracks")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 2, 1])
        let index = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let destination = try makeSandboxDirectory("Headings Tracks Destination")

        let offer = BookExportService.offer(for: book)
        let item = try XCTUnwrap(offer.item(.headings))
        XCTAssertEqual(item.suggestedName, "Tide Clock Recordings.cue")
        let outcome = BookExportService.export(
            [offer], kinds: [.audio, .headings], conversions: [.headings: .chapterList(.cueSheet, of: .headings)], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let sheetURL = destination.appendingPathComponent("Tide Clock Recordings.cue")
        let sheet = try CueSheet.read(at: sheetURL)
        let trackNames = try XCTUnwrap(offer.item(.audio)).files.map(\.path)
        XCTAssertEqual(sheet.files, trackNames.map { "Tide Clock Recordings/\($0)" })
        XCTAssertEqual(sheet.tracks.map(\.title), index.chapters.map(\.title))
        XCTAssertEqual(sheet.tracks.map(\.startFrame), [0, 0, 0])

        let again = try world.importBook(from: sheetURL)
        XCTAssertEqual(try BookContentAnalysisService.load(book: again).content.chapters.map(\.title), index.chapters.map(\.title))
    }

    /// A book of sections, as a DAISY audiobook is read, writes each section
    /// at its own start in the file it begins in.
    func testABookOfSectionsWritesEachSectionsStart() throws {
        let world = try makeIntegrationWorld("Headings Sections")
        let book = try world.makeSegmentedAudioBook(
            title: "Harbour Sections",
            files: ["part1.wav": 4, "part2.wav": 3],
            sections: [
                AudioSegment(title: "First", file: "part1.wav", startTime: 0, endTime: 1.5),
                AudioSegment(title: "Second", file: "part1.wav", startTime: 1.5, endTime: 0),
                AudioSegment(title: "Third", file: "part2.wav", startTime: 0.4, endTime: 0),
            ]
        )
        let destination = try makeSandboxDirectory("Headings Sections Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.headings],
            conversions: [.headings: .chapterList(.cueSheet, of: .headings)], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let sheet = try CueSheet.read(at: destination.appendingPathComponent("Harbour Sections.cue"))
        XCTAssertEqual(sheet.tracks.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(sheet.tracks.map(\.startFrame), [0, 113, 30], "1.5 s is 112.5 frames, rounded to 113; 0.4 s is 30")
        XCTAssertEqual(sheet.tracks.map(\.fileIndex), [0, 0, 1])
    }

    /// A book of one file writes its chapters at the starts its file's own
    /// chapter list gives, exactly (to the frame), not at the index's
    /// lengths rounded down to a tenth of a second: the M4B sample and the
    /// FLAC sample, each imported as it is.
    func testABookOfOneFileWritesItsFilesOwnStarts() async throws {
        let world = try makeIntegrationWorld("Headings One File")
        for sample in ["m4b-chapters/three-tones.m4b", "flac-chapters/three-tones.flac"] {
            let copy = try makeSandboxDirectory("Headings One File Source").appendingPathComponent((sample as NSString).lastPathComponent)
            try FileManager.default.copyItem(at: CueSheetTests.sample(sample), to: copy)
            let book = try world.importBook(from: copy)
            let expected = await AudioPlaybackService.extractChapters(from: book.bookFileURL)
            XCTAssertEqual(expected.count, 3, sample)
            let destination = try makeSandboxDirectory("Headings One File Destination")

            let outcome = BookExportService.export(
                [BookExportService.offer(for: book)], kinds: [.headings],
                conversions: [.headings: .chapterList(.cueSheet, of: .headings)], to: destination
            )

            XCTAssertEqual(outcome.failures, [], sample)
            let name = BookExportService.fileNameStem(for: book.title) + ".cue"
            let sheet = try CueSheet.read(at: destination.appendingPathComponent(name))
            XCTAssertEqual(sheet.files, [book.bookFileURL.lastPathComponent], sample)
            XCTAssertEqual(sheet.tracks.map(\.title), expected.map(\.title), sample)
            XCTAssertEqual(
                sheet.tracks.map(\.startFrame),
                expected.map { Int(($0.startTime * 75).rounded()) },
                "\(sample): the file's own starts, to the frame"
            )
        }
    }

    /// A book of one chapter, which a sheet would say nothing of, offers no
    /// headings; nor does a text book.
    func testABookOfOneChapterOffersNoHeadings() throws {
        let world = try makeIntegrationWorld("Headings One Chapter")
        let single = try world.makeSilentAudioFileBook(title: "Weir", duration: 2)
        let oneTrack = try world.makeSilentAudioBook(title: "Night Shift Notes", trackDurations: [1])
        let text = try world.importBook(from: writeSource(named: "Lock Keeper.md"))

        XCTAssertNil(BookExportService.offer(for: single).item(.headings))
        XCTAssertNil(BookExportService.offer(for: oneTrack).item(.headings))
        XCTAssertNil(BookExportService.offer(for: text).item(.headings))
    }

    /// A book whose package keeps no content index has no headings to write,
    /// and its export says so with the file's name.
    func testABookWithoutAnIndexSaysSo() throws {
        for source in [ChapterListSource.headings, .bookmarks] {
            XCTAssertThrowsError(
                try BookExportService.chapterListEntries(
                    of: source,
                    ofAudioAt: try makeSandboxDirectory("Headings No Index").appendingPathComponent("audio"),
                    stem: "Nothing",
                    access: .live
                )
            )
        }
        XCTAssertEqual(
            ChapterListExportError.noHeadings.errorDescription,
            "TextMouth hasn't read this book's headings yet. Open the book once, then export again."
        )
    }

    // MARK: - Audacity Labels (FMT06)

    /// A book of one file exports its headings as Audacity labels at the
    /// starts its file's own chapter list gives, each a point named by its
    /// chapter's title, in Audacity's text.
    func testABookOfOneFileExportsItsHeadingsAsLabels() async throws {
        let world = try makeIntegrationWorld("Labels One File")
        let copy = try makeSandboxDirectory("Labels One File Source").appendingPathComponent("three-tones.m4b")
        try FileManager.default.copyItem(at: CueSheetTests.sample("m4b-chapters/three-tones.m4b"), to: copy)
        let book = try world.importBook(from: copy)
        let expected = await AudioPlaybackService.extractChapters(from: book.bookFileURL)
        let destination = try makeSandboxDirectory("Labels One File Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.headings],
            conversions: [.headings: .chapterList(.audacityLabels, of: .headings)], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let name = BookExportService.fileNameStem(for: book.title) + ".txt"
        let text = try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8)
        XCTAssertEqual(text, AudacityLabels.text(of: expected.map {
            AudacityLabels.Label(start: $0.startTime, end: $0.startTime, text: $0.title)
        }))
        XCTAssertEqual(AudacityLabels.parse(text).map(\.text), expected.map(\.title))
    }

    /// A book of several files cannot export labels, which mark one file:
    /// the export says so with the file's name, and writes nothing.
    func testABookOfSeveralFilesExportsNoLabels() throws {
        let world = try makeIntegrationWorld("Labels Several Files")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1, 1])
        let destination = try makeSandboxDirectory("Labels Several Files Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.headings],
            conversions: [.headings: .chapterList(.audacityLabels, of: .headings)], to: destination
        )

        XCTAssertEqual(outcome.failures, [BookExportFailure(
            name: "Tide Clock Recordings.txt",
            reason: "Audacity labels mark one audio file, and this book's audio is in 3 files."
        )])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    /// A book with bookmarks offers them, and exports them as Audacity labels
    /// at the places the reader plays them, in their numbers' order, a
    /// bookmark without a name named by its number.
    func testBookmarksExportAsLabelsWhereTheReaderPlaysThem() throws {
        let world = try makeIntegrationWorld("Labels Bookmarks")
        let book = try world.makeSegmentedAudioBook(
            title: "Harbour Sections",
            files: ["harbour.wav": 6],
            sections: [
                AudioSegment(title: "First", file: "harbour.wav", startTime: 0, endTime: 2),
                AudioSegment(title: "Second", file: "harbour.wav", startTime: 2, endTime: 0),
            ]
        )
        var record = try BookInfo.load(from: book.tmbDirectory)
        record.bookmarks = [
            Bookmark(number: 2, chapterIndex: 1, characterOffset: 15, label: ""),
            Bookmark(number: 1, chapterIndex: 0, characterOffset: 5, label: "Pilot boat"),
        ]
        try record.save(to: book.tmbDirectory)
        let destination = try makeSandboxDirectory("Labels Bookmarks Destination")

        let offer = BookExportService.offer(for: book)
        XCTAssertEqual(offer.item(.bookmarks)?.suggestedName, "Harbour Sections - Bookmarks.txt")
        let outcome = BookExportService.export(
            [offer], kinds: [.bookmarks], conversions: [.bookmarks: .chapterList(.audacityLabels, of: .bookmarks)], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let text = try String(contentsOf: destination.appendingPathComponent("Harbour Sections - Bookmarks.txt"), encoding: .utf8)
        // Ten placeholder characters are a second: 5 is half a second into
        // the first section, 15 a second and a half into the second, at 2.
        XCTAssertEqual(text, "0.500000\t0.500000\tPilot boat\n3.500000\t3.500000\tBookmark 2\n")
        XCTAssertEqual(BookExportWording.untitledBookmark(number: 2), "Bookmark 2")
    }

    /// A bookmark of a book of one file lies where the index's chapter
    /// lengths before it add up to, as the reader seeks; one of a chapter
    /// the index does not hold has no place.
    func testABookmarksPlaceInABookOfOneFile() throws {
        let index = BookContentIndex.build(
            from: DocumentContent(title: "One", author: "", chapters: [
                Chapter(title: "A", text: String(repeating: " ", count: 25), headings: []),
                Chapter(title: "B", text: String(repeating: " ", count: 40), headings: []),
            ]),
            format: .audio,
            audioFilePaths: nil,
            audioSegments: nil,
            audioBaseURL: nil
        )
        let place = BookExportService.bookmarkPlace(Bookmark(number: 1, chapterIndex: 1, characterOffset: 12), in: index)
        XCTAssertNil(place?.file)
        XCTAssertEqual(place?.start ?? -1, 3.7, accuracy: 1e-9, "25 characters before it, and 12 into it, at ten a second")
        XCTAssertNil(BookExportService.bookmarkPlace(Bookmark(number: 2, chapterIndex: 5, characterOffset: 0), in: index))
    }

    // MARK: - The Dialog

    /// The Headings checkbox's picker lists the chapter list formats, a CUE
    /// sheet first and chosen; checked, the headings are written as one; its
    /// label and hint name the format, and its picker has its own name. With
    /// labels chosen, its label and hint say so.
    func testTheDialogWritesTheHeadingsInTheFormatChosen() async throws {
        let world = try makeIntegrationWorld("Headings Dialog")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1])
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Headings Dialog Folder"))

        await model.load()

        XCTAssertEqual(model.choices.map(\.kind), [.audio, .headings])
        XCTAssertEqual(model.conversionChoices(for: .headings), [
            BookExportConversionChoice(
                id: "chapter-list-cue",
                name: "CUE sheet",
                hint: "Each heading's title and start, as a CUE sheet naming the audio as Audio exports it."
            ),
            BookExportConversionChoice(
                id: "chapter-list-labels",
                name: "Audacity labels",
                hint: "Each heading's title and start, as Audacity labels, for a book with one audio file."
            ),
        ])
        XCTAssertEqual(model.conversionID(for: .headings), "chapter-list-cue")
        XCTAssertNil(model.conversions[.headings], "unchecked, the headings are not written")
        model.setChecked(true, for: .headings)
        XCTAssertEqual(model.conversions[.headings], .chapterList(.cueSheet, of: .headings))
        let headings = try XCTUnwrap(model.choices.first { $0.kind == .headings })
        XCTAssertEqual(model.label(for: headings), "Headings as CUE sheet")
        XCTAssertEqual(model.hint(for: .headings), BookExportWording.chapterListChoiceHint(for: .cueSheet, source: .headings))
        model.setConversionID("chapter-list-labels", for: .headings)
        XCTAssertEqual(model.conversions[.headings], .chapterList(.audacityLabels, of: .headings))
        XCTAssertEqual(model.label(for: headings), "Headings as Audacity labels")
        XCTAssertEqual(BookExportWording.convertToLabel(for: .headings), "Convert headings to")
        XCTAssertEqual(BookExportConversion.chapterList(.cueSheet, of: .headings).fileExtension, "cue")
        XCTAssertEqual(BookExportConversion.chapterList(.audacityLabels, of: .headings).fileExtension, "txt")
        XCTAssertEqual(BookExportKind.allCases.filter { BookExportConversion.chapterList(.cueSheet, of: .headings).applies(to: $0) }, [.headings])
        XCTAssertEqual(BookExportKind.allCases.filter { BookExportConversion.chapterList(.audacityLabels, of: .bookmarks).applies(to: $0) }, [.bookmarks])
    }

    /// A book with bookmarks lists a Bookmarks checkbox with no pop-up beside
    /// it, Audacity labels being its one format, which its label and hint
    /// name.
    func testTheDialogListsBookmarksForABookWithThem() async throws {
        let world = try makeIntegrationWorld("Bookmarks Dialog")
        let book = try world.makeSilentAudioFileBook(title: "Weir", duration: 2)
        var record = try BookInfo.load(from: book.tmbDirectory)
        record.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 3, label: "Sluice")]
        try record.save(to: book.tmbDirectory)
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Bookmarks Dialog Folder"))

        await model.load()

        XCTAssertEqual(model.choices.map(\.kind), [.audio, .bookmarks])
        // One format needs no pop-up of one choice: the checkbox names it.
        XCTAssertEqual(model.conversionChoices(for: .bookmarks), [])
        model.setChecked(true, for: .bookmarks)
        XCTAssertEqual(model.conversions[.bookmarks], .chapterList(.audacityLabels, of: .bookmarks))
        let bookmarks = try XCTUnwrap(model.choices.first { $0.kind == .bookmarks })
        XCTAssertEqual(model.label(for: bookmarks), "Bookmarks as Audacity labels")
        XCTAssertEqual(
            model.hint(for: .bookmarks),
            "Each bookmark's name and place, as Audacity labels, for a book with one audio file."
        )
    }

    // MARK: - Helpers

    /// A Markdown file named `name`, of two short chapters, in a sandbox
    /// folder of this test's.
    private func writeSource(named name: String) throws -> URL {
        let url = try makeSandboxDirectory("Headings Source").appendingPathComponent(name)
        try Data("# First\n\nThe tide came in.\n\n# Second\n\nIt went out again.\n".utf8).write(to: url)
        return url
    }
}
