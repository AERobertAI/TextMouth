import XCTest
@testable import TextMouth

/// A persisted content index is trusted only after validation (TODO T01).
/// Each malformed case starts from an index the builder made, damages one
/// field the way a corrupted or hand-edited bookInfo.json could, and expects
/// the reason naming exactly that field.
final class ContentIndexValidationTests: XCTestCase {
    private let limit = BookContentIndex.maximumCharacterCount

    // MARK: - Sound indexes

    /// The builder's text index passes, and `isValid` agrees.
    func testBuiltTextIndexIsValid() {
        let index = textIndex()

        XCTAssertNil(index.validationFailure(for: .epub, audioBaseURL: nil))
        XCTAssertTrue(index.isValid(for: .epub, audioBaseURL: nil))
    }

    /// Every audio layout the builder makes passes: a single file whose
    /// chapters name no file, one file per chapter, and segments of a file.
    func testBuiltAudioIndexesAreValid() {
        for index in [singleFileIndex(), multiFileIndex(), segmentedIndex()] {
            XCTAssertNil(index.validationFailure(for: .audio, audioBaseURL: nil), "\(String(describing: index.audioLayout))")
            XCTAssertTrue(index.isValid(for: .audio, audioBaseURL: nil))
        }
    }

    // MARK: - Building

    /// A heading placed past its chapter's end, or before its start, is
    /// built at the nearest end, with the ID `Heading` derives there, so
    /// the builder never writes an index validation would reject.
    func testBuilderKeepsHeadingsInsideTheirChapter() {
        let chapter = Chapter(title: "Body", text: "Body.", headings: [
            Heading(level: 1, text: "Before", characterOffset: -3),
            Heading(level: 1, text: "<br>", characterOffset: 7),
        ])

        let index = BookContentIndex.build(fromChapters: [chapter], format: .markdown)

        XCTAssertEqual(index.chapters[0].headings.map(\.characterOffset), [0, 5])
        XCTAssertEqual(index.chapters[0].headings.map(\.globalCharacterOffset), [0, 5])
        XCTAssertEqual(index.chapters[0].headings.map(\.id), index.allHeadings.map(\.id))
        XCTAssertNil(index.validationFailure(for: .markdown, audioBaseURL: nil))
    }

    /// A Markdown heading made only of inline HTML adds no reading text; at
    /// the end of a chapter it still yields a valid index, so such a book is
    /// not rejected and rebuilt every time it opens.
    func testHeadingOfInlineHTMLAtAChapterEndYieldsAValidIndex() {
        for markdown in ["Body.\n\n# <br>", "<!-- chapter: A -->\nBody.\n\n# <b></b>\n\n<!-- chapter: B -->\nMore."] {
            let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Book", bookAuthor: "Author")

            XCTAssertNil(
                content.contentIndex.replacingFormat(.markdown).validationFailure(for: .markdown, audioBaseURL: nil),
                String(reflecting: markdown)
            )
        }
    }

    // MARK: - Identity

    /// An index from another builder version may derive text differently.
    func testOutdatedVersionIsRejected() {
        var index = textIndex()
        index.version = "0.9.0"

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "version \"0.9.0\" is not the current \"\(BookContentIndex.currentVersion)\""
        )
        XCTAssertFalse(index.isValid(for: .epub, audioBaseURL: nil))
    }

    /// An index made for another format describes a different reading.
    func testIndexForAnotherFormatIsRejected() {
        XCTAssertEqual(
            textIndex().validationFailure(for: .txt, audioBaseURL: nil),
            "format epub does not match the book's format txt"
        )
    }

    /// A text book's index must be a text index, and an audio book's audio.
    func testKindThatDoesNotSuitTheFormatIsRejected() {
        var index = textIndex()
        index.kind = .audio

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "kind audio does not match format epub")
    }

    // MARK: - Chapters

    /// A book always has at least one chapter; an empty list is damage.
    func testEmptyChapterListIsRejected() {
        var index = textIndex()
        index.chapters = []

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters is empty")
    }

    /// Headings name their chapter by number, so numbers must match places.
    func testChapterOutOfPlaceIsRejected() {
        var index = textIndex()
        index.chapters[1].chapterIndex = 2

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].chapterIndex is 2, expected 1")
    }

    /// A chapter cannot hold fewer than no characters.
    func testNegativeCharacterCountIsRejected() {
        var index = textIndex()
        index.chapters[1].characterCount = -5

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].characterCount is -5, below 0")
    }

    /// Word counts can be neither negative nor larger than the character
    /// count, since every word holds at least one character.
    func testWordCountOutsideTheChapterIsRejected() {
        var negative = textIndex()
        negative.chapters[1].wordCount = -1
        var excessive = textIndex()
        excessive.chapters[0].wordCount = 11

        XCTAssertEqual(negative.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].wordCount is -1, outside 0 through 15")
        XCTAssertEqual(excessive.validationFailure(for: .epub, audioBaseURL: nil), "chapters[0].wordCount is 11, outside 0 through 10")
    }

    /// Chapter start offsets are the running sums of the lengths before
    /// them; anything else misplaces every reading position after it.
    func testStartOffsetThatIsNotTheRunningSumIsRejected() {
        var index = textIndex()
        index.chapters[1].startCharacterOffset = 9

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].startCharacterOffset is 9, expected 10")
    }

    /// The character total must be the sum of the chapter lengths (25).
    func testCharacterTotalMismatchIsRejected() {
        var index = textIndex()
        index.totalCharacterCount = 24

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "totalCharacterCount is 24, expected 25")
    }

    /// The word total must be the sum of the chapter word counts (6).
    func testWordTotalMismatchIsRejected() {
        var index = textIndex()
        index.totalWordCount = 7

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "totalWordCount is 7, expected 6")
    }

    /// One chapter longer than any real book is rejected before playback
    /// could allocate a placeholder of that length.
    func testOversizedChapterIsRejected() {
        let index = resized(textIndex(), to: [10, limit + 1])

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[1].characterCount is \(limit + 1), above the limit of \(limit)"
        )
    }

    /// Chapters each within the limit can still add up past it.
    func testOversizedBookIsRejected() {
        let index = resized(textIndex(), to: [limit / 2 + 1, limit / 2 + 1])

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "the chapters hold \(limit + 2) characters, above the limit of \(limit)"
        )
    }

    /// The limit itself is allowed, for one chapter and for the book.
    func testBookAtTheLimitIsValid() {
        XCTAssertNil(resized(textIndex(), to: [limit - 15, 15]).validationFailure(for: .epub, audioBaseURL: nil))
    }

    /// Counts near `Int.max` fail cleanly instead of overflowing a sum.
    func testExtremeCountsFailWithoutOverflow() {
        var index = textIndex()
        index.chapters[0].characterCount = .max
        index.chapters[1].startCharacterOffset = .max
        index.totalCharacterCount = .max

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[0].characterCount is \(Int.max), above the limit of \(limit)"
        )
    }

    // MARK: - Headings

    /// Headings run from level 1 through 6; the navigator knows no level 0.
    func testHeadingLevelZeroIsRejected() {
        var index = textIndex()
        index.chapters[0].headings[0].level = 0

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[0].headings[0].level is 0, outside 1 through 6")
    }

    /// Nor any level past 6.
    func testHeadingLevelSevenIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[1].level = 7

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].headings[1].level is 7, outside 1 through 6")
    }

    /// Every heading the builder writes has an ID.
    func testHeadingWithoutIDIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[0].id = ""

        XCTAssertEqual(index.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].headings[0].id is empty")
    }

    /// A heading past the end of its chapter, or before its start, would
    /// send navigation outside the chapter's text.
    func testHeadingOutsideItsChapterIsRejected() {
        var pastEnd = textIndex()
        pastEnd.chapters[1].headings[1].characterOffset = 16
        pastEnd.chapters[1].headings[1].globalCharacterOffset = 26
        var beforeStart = textIndex()
        beforeStart.chapters[1].headings[0].characterOffset = -1
        beforeStart.chapters[1].headings[0].globalCharacterOffset = 9

        XCTAssertEqual(
            pastEnd.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[1].headings[1].characterOffset is 16, outside 0 through 15"
        )
        XCTAssertEqual(
            beforeStart.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[1].headings[0].characterOffset is -1, outside 0 through 15"
        )
    }

    /// A heading may sit at the very end of its chapter.
    func testHeadingAtTheEndOfItsChapterIsValid() {
        var index = textIndex()
        index.chapters[1].headings[1].characterOffset = 15
        index.chapters[1].headings[1].globalCharacterOffset = 25

        XCTAssertNil(index.validationFailure(for: .epub, audioBaseURL: nil))
    }

    /// The global offset must be the chapter's start plus the local offset;
    /// here it repeats the local offset, as a builder bug could.
    func testWrongGlobalHeadingOffsetIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[1].globalCharacterOffset = 11

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[1].headings[1].globalCharacterOffset is 11, expected 21"
        )
    }

    /// Headings within a chapter are stored in reading order.
    func testHeadingsOutOfOrderAreRejected() {
        var index = textIndex()
        index.chapters[1].headings.reverse()

        XCTAssertEqual(
            index.validationFailure(for: .epub, audioBaseURL: nil),
            "chapters[1].headings[1].characterOffset is 0, before the previous heading's 11"
        )
    }

    // MARK: - Text

    /// The builder writes no audio layout, duration, or chapter timing for a
    /// text book; any of them means the index came from somewhere else.
    func testTextIndexCarryingAudioIsRejected() {
        var layout = textIndex()
        layout.audioLayout = .singleFile
        var duration = textIndex()
        duration.totalAudioDuration = 1
        var chapterAudio = textIndex()
        chapterAudio.chapters[1].audio = BookContentAudioChapterIndex(relativeFilePath: nil, startTime: 0, duration: 1)

        XCTAssertEqual(layout.validationFailure(for: .epub, audioBaseURL: nil), "audioLayout is present in a text index")
        XCTAssertEqual(duration.validationFailure(for: .epub, audioBaseURL: nil), "totalAudioDuration is present in a text index")
        XCTAssertEqual(chapterAudio.validationFailure(for: .epub, audioBaseURL: nil), "chapters[1].audio is present in a text index")
    }

    // MARK: - Audio

    /// Without a layout, playback cannot tell how chapters map to files.
    func testAudioIndexWithoutLayoutIsRejected() {
        var index = multiFileIndex()
        index.audioLayout = nil

        XCTAssertEqual(index.validationFailure(for: .audio, audioBaseURL: nil), "audioLayout is missing")
    }

    /// Every audio chapter carries its timing, even in a single-file book.
    func testAudioChapterWithoutTimingIsRejected() {
        var index = multiFileIndex()
        index.chapters[1].audio = nil

        XCTAssertEqual(index.validationFailure(for: .audio, audioBaseURL: nil), "chapters[1].audio is missing")
    }

    /// Playback restores at least one placeholder character per chapter, so
    /// a zero-length audio chapter would disagree with its restored text.
    func testEmptyAudioChapterIsRejected() {
        let index = resized(multiFileIndex(), to: [100, 0, 300])

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[1].characterCount is 0, but an audio chapter holds at least 1 placeholder character"
        )
    }

    /// A segment cannot start at a time that is not a number.
    func testNonFiniteStartTimeIsRejected() {
        var index = segmentedIndex()
        index.chapters[1].audio?.startTime = .nan

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[1].audio.startTime is nan, expected a finite number of seconds, 0 or more"
        )
    }

    /// Nor before the start of its file.
    func testNegativeStartTimeIsRejected() {
        var index = segmentedIndex()
        index.chapters[0].audio?.startTime = -1

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[0].audio.startTime is -1.0, expected a finite number of seconds, 0 or more"
        )
    }

    /// NaN and infinite durations would make the total, and every time
    /// remaining derived from it, meaningless.
    func testNonFiniteDurationIsRejected() {
        for duration in [TimeInterval.nan, .infinity] {
            var index = multiFileIndex()
            index.chapters[2].audio?.duration = duration

            XCTAssertEqual(
                index.validationFailure(for: .audio, audioBaseURL: nil),
                "chapters[2].audio.duration is \(duration), expected a finite number of seconds, 0 or more"
            )
        }
    }

    /// A chapter cannot last less than no time.
    func testNegativeDurationIsRejected() {
        var index = multiFileIndex()
        index.chapters[2].audio?.duration = -10

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[2].audio.duration is -10.0, expected a finite number of seconds, 0 or more"
        )
    }

    /// The total must equal the sum of the chapter durations (60 seconds);
    /// a missing or NaN total fails too.
    func testDurationTotalMismatchIsRejected() {
        var larger = multiFileIndex()
        larger.totalAudioDuration = 61
        var missing = multiFileIndex()
        missing.totalAudioDuration = nil
        var notANumber = multiFileIndex()
        notANumber.totalAudioDuration = .nan

        XCTAssertEqual(larger.validationFailure(for: .audio, audioBaseURL: nil), "totalAudioDuration is 61.0, expected 60.0")
        XCTAssertEqual(missing.validationFailure(for: .audio, audioBaseURL: nil), "totalAudioDuration is missing")
        XCTAssertEqual(notANumber.validationFailure(for: .audio, audioBaseURL: nil), "totalAudioDuration is nan, expected 60.0")
    }

    /// Rounding far below a millisecond is not damage.
    func testDurationTotalWithinToleranceIsValid() {
        var index = multiFileIndex()
        index.totalAudioDuration = 60.0005

        XCTAssertNil(index.validationFailure(for: .audio, audioBaseURL: nil))
    }

    /// Every chapter of a multi-file book must name its file; a missing or
    /// empty path used to drop out and shift later chapters' files.
    func testMultiFileChapterWithoutPathIsRejected() {
        for path in [nil, ""] {
            var index = multiFileIndex()
            index.chapters[1].audio?.relativeFilePath = path

            XCTAssertEqual(
                index.validationFailure(for: .audio, audioBaseURL: nil),
                "chapters[1].audio.relativeFilePath is missing",
                String(describing: path)
            )
        }
    }

    /// An absolute path could name any file on disk.
    func testAbsoluteAudioPathIsRejected() {
        var index = multiFileIndex()
        index.chapters[1].audio?.relativeFilePath = "/etc/hosts"

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[1].audio.relativeFilePath \"/etc/hosts\" is absolute"
        )
    }

    /// A ".." component anywhere in the path could climb out of the book's
    /// folder, even after a subfolder name.
    func testParentFolderAudioPathIsRejected() {
        for path in ["../02.wav", "Disc 2/../../02.wav"] {
            var index = multiFileIndex()
            index.chapters[1].audio?.relativeFilePath = path

            XCTAssertEqual(
                index.validationFailure(for: .audio, audioBaseURL: nil),
                "chapters[1].audio.relativeFilePath \(String(reflecting: path)) contains a \"..\" component"
            )
        }
    }

    /// Segments name their shared file per chapter and are checked the same way.
    func testSegmentedPathsAreChecked() {
        var index = segmentedIndex()
        index.chapters[0].audio?.relativeFilePath = "../book.wav"

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[0].audio.relativeFilePath \"../book.wav\" contains a \"..\" component"
        )
    }

    // MARK: - Audio files on disk

    /// Files present in the folder pass, including one in a subfolder and a
    /// file shared by segments, whether the folder is named directly or
    /// through a symbolic link to it.
    func testAudioFilesInsideTheFolderAreValid() throws {
        let folder = try audioFolder()
        let link = try scratchFolder("ContentIndexLink").appendingPathComponent("audio")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        for base in [folder, link] {
            XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: base), base.path)
            XCTAssertNil(segmentedIndex().validationFailure(for: .audio, audioBaseURL: base), base.path)
        }
    }

    /// A track deleted after analysis leaves the index valid. Playback then
    /// names the missing file for its chapter and offers Retry, while every
    /// other chapter keeps its own track; analyzing the folder again would
    /// silently drop the chapter and shift every later one.
    func testMissingAudioFileKeepsTheIndexValid() throws {
        let folder = try audioFolder()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("02.wav"))

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder))
    }

    /// So does a missing folder: with nothing of it on disk, only each
    /// path's own form is checked.
    func testMissingAudioFolderKeepsTheIndexValid() throws {
        let folder = try audioFolder()
        let missingFolder = folder.appendingPathComponent("moved away", isDirectory: true)
        var climbing = multiFileIndex(in: folder)
        climbing.chapters[0].audio?.relativeFilePath = "../01.wav"

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: missingFolder))
        XCTAssertEqual(
            climbing.validationFailure(for: .audio, audioBaseURL: missingFolder),
            "chapters[0].audio.relativeFilePath \"../01.wav\" contains a \"..\" component"
        )
    }

    /// A missing file is not a rejection, but something at a track's path
    /// that exists and is not a regular file still is. Here it is a named
    /// pipe, which could block playback's loading forever.
    func testMissingFileIsAcceptedWhileANonRegularFileIsNot() throws {
        let folder = try audioFolder()
        let track = folder.appendingPathComponent("02.wav")
        try FileManager.default.removeItem(at: track)

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder))

        XCTAssertEqual(mkfifo(track.path, 0o644), 0, "Could not create the named pipe")
        XCTAssertEqual(
            multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[1].audio.relativeFilePath \"02.wav\" is not a regular file"
        )
    }

    /// The part of a path that exists must stay inside the folder even when
    /// the file itself is missing: here a linked subfolder leads out of it.
    func testMissingFileBehindALinkLeavingTheFolderIsRejected() throws {
        let folder = try audioFolder()
        let emptyOutside = try scratchFolder("ContentIndexOutsideEmptyDisc")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Disc 2"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Disc 2"),
            withDestinationURL: emptyOutside
        )

        XCTAssertEqual(
            multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[2].audio.relativeFilePath \"Disc 2/03.wav\" resolves outside the audio folder"
        )
    }

    /// A broken link is a missing file, as playback judges it, so it keeps
    /// the index valid; nothing it names exists to be read.
    func testBrokenLinkCountsAsAMissingFile() throws {
        let folder = try audioFolder()
        let vanished = try scratchFolder("ContentIndexVanished").appendingPathComponent("vanished.wav")
        try replaceWithLink("02.wav", in: folder, to: vanished)

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder))
    }

    /// A path that stays inside the folder by its spelling can still leave
    /// it through a symbolic link; the link's destination decides.
    func testLinkToAFileOutsideTheFolderIsRejected() throws {
        let folder = try audioFolder()
        let outside = try scratchFolder("ContentIndexOutside").appendingPathComponent("elsewhere.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data()))
        try replaceWithLink("02.wav", in: folder, to: outside)

        XCTAssertEqual(
            multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[1].audio.relativeFilePath \"02.wav\" resolves outside the audio folder"
        )
    }

    /// The same holds for a linked subfolder the path passes through.
    func testLinkedSubfolderOutsideTheFolderIsRejected() throws {
        let folder = try audioFolder()
        let outside = try scratchFolder("ContentIndexOutsideDisc")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.appendingPathComponent("03.wav").path, contents: Data()))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Disc 2"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Disc 2"), withDestinationURL: outside)

        XCTAssertEqual(
            multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[2].audio.relativeFilePath \"Disc 2/03.wav\" resolves outside the audio folder"
        )
    }

    /// A link whose destination is inside the folder is harmless.
    func testLinkToAFileInsideTheFolderIsValid() throws {
        let folder = try audioFolder()
        try replaceWithLink("02.wav", in: folder, to: folder.appendingPathComponent("01.wav"))

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder))
    }

    /// A folder, even one inside the book's folder, is not a playable file.
    func testAudioPathNamingAFolderIsRejected() throws {
        let folder = try audioFolder()
        var index = multiFileIndex(in: folder)
        index.chapters[2].audio?.relativeFilePath = "Disc 2"

        XCTAssertEqual(
            index.validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[2].audio.relativeFilePath \"Disc 2\" is not a regular file"
        )
    }

    /// Segments sharing a missing file keep the index valid too.
    func testMissingSharedSegmentFileKeepsTheIndexValid() throws {
        let folder = try audioFolder()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("book.wav"))

        XCTAssertNil(segmentedIndex().validationFailure(for: .audio, audioBaseURL: folder))
    }

    /// Without a folder nothing is looked up on disk: a track linked to a
    /// file outside the folder passes, though it fails once the folder is
    /// known, while a path's own form is checked either way.
    func testWithoutAFolderOnlyThePathFormIsChecked() throws {
        let folder = try audioFolder()
        let outside = try scratchFolder("ContentIndexUnchecked").appendingPathComponent("elsewhere.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data()))
        try replaceWithLink("02.wav", in: folder, to: outside)
        var climbing = multiFileIndex(in: folder)
        climbing.chapters[0].audio?.relativeFilePath = "../01.wav"

        XCTAssertNil(multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: nil))
        XCTAssertEqual(
            multiFileIndex(in: folder).validationFailure(for: .audio, audioBaseURL: folder),
            "chapters[1].audio.relativeFilePath \"02.wav\" resolves outside the audio folder"
        )
        XCTAssertEqual(
            climbing.validationFailure(for: .audio, audioBaseURL: nil),
            "chapters[0].audio.relativeFilePath \"../01.wav\" contains a \"..\" component"
        )
    }

    /// Parsing reports the files of a library reached through a symbolic
    /// link by the link's destination. The builder still records each file
    /// relative to the folder as the book names it, subfolder included, so
    /// the index validates instead of naming "03.wav" for "Disc 2/03.wav".
    func testIndexBuiltThroughALinkedLibraryKeepsSubfolders() throws {
        let library = try scratchFolder("ContentIndexLinkedLibrary")
        try createAudioFiles(in: library.appendingPathComponent("real/audio", isDirectory: true))
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("linked"),
            withDestinationURL: library.appendingPathComponent("real")
        )
        let folder = library.appendingPathComponent("linked/audio", isDirectory: true)
        let reported = try AudioBookParser.audioFiles(in: folder).map(\.path)

        let index = BookContentIndex.build(
            fromChapters: reported.map { Chapter(title: $0, text: placeholder(10)) },
            format: .audio,
            audioFilePaths: reported,
            audioBaseURL: folder
        )

        XCTAssertEqual(index.chapters.compactMap(\.audioFilePath).sorted(), (tracks + ["book.wav"]).sorted())
        XCTAssertNil(index.validationFailure(for: .audio, audioBaseURL: folder))
    }

    /// A single-file book's chapters name no file, so validation looks none
    /// up, just as opening the book from its index never opens its file.
    func testSingleFileIndexLooksUpNoFiles() throws {
        let emptyFolder = try scratchFolder("ContentIndexSingle")

        XCTAssertNil(singleFileIndex().validationFailure(for: .audio, audioBaseURL: emptyFolder))
    }

    // MARK: - Alignment with the reading text

    /// An index is aligned with the chapters it was built from.
    func testIndexIsAlignedWithItsOwnChapters() {
        XCTAssertNil(textIndex().alignmentFailure(with: textChapters()))
    }

    /// Text with another number of chapters cannot share the index's offsets.
    func testIndexIsMisalignedWithAnotherChapterCount() {
        XCTAssertEqual(
            textIndex().alignmentFailure(with: Array(textChapters().prefix(1))),
            "chapters has 2 entries, but the reading text has 1"
        )
    }

    /// A chapter of another length shifts every offset after it.
    func testIndexIsMisalignedWithAnotherChapterLength() {
        var chapters = textChapters()
        chapters[1].text += "!"

        XCTAssertEqual(
            textIndex().alignmentFailure(with: chapters),
            "chapters[1].characterCount is 15, but the reading text holds 16"
        )
    }

    // MARK: - Opening a book

    /// A sound saved text index keeps the fast path.
    func testSoundTextIndexIsReused() throws {
        let book = try makeTextBook()

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.index, try savedIndex(of: book))
        XCTAssertTrue(rejections(of: book).isEmpty)
    }

    /// A damaged text index is reported and set aside: the book re-indexes
    /// its cache, the new index matches the chapters it is paired with, and
    /// once the caller saves it as usual the next load reuses it.
    func testMalformedTextIndexIsRebuiltAndReplaced() throws {
        let book = try makeTextBook()
        var damaged = try savedIndex(of: book)
        let start = damaged.chapters[1].startCharacterOffset
        damaged.chapters[1].startCharacterOffset += 7
        try book.saveBookInfoThrowing(contentIndex: damaged)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        assertAligned(result, for: book)
        XCTAssertEqual(result.index.chapters[1].startCharacterOffset, start)
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].startCharacterOffset is \(start + 7), expected \(start)"]
        )
        try assertRepairIsReused(result, for: book)
    }

    /// A sound index describing other text than content.md now holds is set
    /// aside and the cache re-indexed, so offsets point into the words the
    /// reader shows.
    func testTextIndexDescribingOtherTextIsRebuilt() throws {
        let book = try makeTextBook()
        let saved = try savedIndex(of: book)
        let addition = " Nine ten."
        let cache = TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
        try String(contentsOf: cache, encoding: .utf8)
            .replacingOccurrences(of: "Six seven eight.", with: "Six seven eight.\(addition)")
            .write(to: cache, atomically: true, encoding: .utf8)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        assertAligned(result, for: book)
        let savedLength = saved.chapters[1].characterCount
        XCTAssertEqual(result.index.chapters[1].characterCount, savedLength + addition.utf16.count)
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].characterCount is \(savedLength), but the reading text holds \(savedLength + addition.utf16.count)"]
        )
        try assertRepairIsReused(result, for: book)
    }

    /// A sound saved audio index keeps the fast path, with every chapter's
    /// file in order.
    func testSoundAudioIndexIsReused() throws {
        let book = try makeAudioBook()

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(relativeAudioPaths(of: result, in: book), tracks)
        XCTAssertTrue(rejections(of: book).isEmpty)
    }

    /// A chapter without its file used to shift every later chapter onto
    /// the wrong track. Now the index is set aside and the folder analyzed
    /// again, so each chapter plays its own file.
    func testAudioIndexMissingAPathIsRebuiltAndReplaced() throws {
        let book = try makeAudioBook()
        var damaged = try savedIndex(of: book)
        damaged.chapters[1].audio?.relativeFilePath = nil
        try book.saveBookInfoThrowing(contentIndex: damaged)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        assertAligned(result, for: book)
        XCTAssertEqual(relativeAudioPaths(of: result, in: book), tracks)
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].audio.relativeFilePath is missing"]
        )
        try assertRepairIsReused(result, for: book)
    }

    /// A track deleted after analysis keeps the saved index: every chapter
    /// still names its own file, the deleted one included, so playback can
    /// say which file is missing rather than the book silently losing a
    /// chapter and shifting every later one.
    func testAudioIndexNamingADeletedFileIsKept() throws {
        let book = try makeAudioBook()
        let folder = URL(fileURLWithPath: book.filePath)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("02.wav"))

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.index, try savedIndex(of: book))
        XCTAssertEqual(result.audioFilePaths, tracks.map { folder.appendingPathComponent($0).path })
        XCTAssertTrue(rejections(of: book).isEmpty)
    }

    /// So does a missing audio folder: the book opens from its index, and
    /// playback reports each chapter's missing file.
    func testAudioIndexOfAMissingFolderIsKept() throws {
        let book = try makeAudioBook()
        let folder = URL(fileURLWithPath: book.filePath)
        try FileManager.default.removeItem(at: folder)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.content.chapters.count, tracks.count)
        XCTAssertEqual(result.audioFilePaths, tracks.map { folder.appendingPathComponent($0).path })
        XCTAssertTrue(rejections(of: book).isEmpty)
    }

    /// A track replaced by a link to a file elsewhere on disk is never
    /// handed to playback.
    func testAudioIndexLinkingOutsideTheFolderIsRebuilt() throws {
        let book = try makeAudioBook()
        let folder = URL(fileURLWithPath: book.filePath)
        let outside = try scratchFolder("ContentIndexOutsideTrack").appendingPathComponent("elsewhere.wav")
        try writeSilence(to: outside)
        try replaceWithLink("02.wav", in: folder, to: outside)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        assertAligned(result, for: book)
        // Every file handed to playback resolves inside the folder. (Which
        // tracks remain is the parser's business: it skips links.)
        let played = try XCTUnwrap(relativeAudioPaths(of: result, in: book))
        XCTAssertFalse(played.isEmpty)
        XCTAssertTrue(played.allSatisfy { !$0.hasPrefix("/") && $0 != "02.wav" }, "\(played)")
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].audio.relativeFilePath \"02.wav\" resolves outside the audio folder"]
        )
    }

    /// An absurd chapter length is rejected before the placeholder text is
    /// allocated; without validation this load would request a terabyte.
    func testOversizedAudioIndexIsRebuiltWithoutAllocating() throws {
        let book = try makeAudioBook()
        var damaged = try savedIndex(of: book)
        damaged.chapters[0].characterCount = 1_000_000_000_000
        try book.saveBookInfoThrowing(contentIndex: damaged)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        assertAligned(result, for: book)
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[0].characterCount is 1000000000000, above the limit of \(limit)"]
        )
    }

    /// A library batch resuming after a crash reuses only a sound index; a
    /// damaged one is reported, so the book's cache and index are rebuilt.
    func testCompletedCheckpointWithMalformedIndexIsNotReused() throws {
        let book = try makeTextBook()
        XCTAssertEqual(BookContentAnalysisService.completedTextCacheIndex(for: book), try savedIndex(of: book))
        var damaged = try savedIndex(of: book)
        damaged.chapters[0].headings[0].level = 9
        try book.saveBookInfoThrowing(contentIndex: damaged)

        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book))
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[0].headings[0].level is 9, outside 1 through 6"]
        )
    }

    /// An index that would not be used anyway, because the outdated cache is
    /// being regenerated with it, is not reported.
    func testIndexReplacedByRegenerationIsNotReported() throws {
        var book = try makeTextBook()
        var damaged = try savedIndex(of: book)
        damaged.totalWordCount += 1
        try book.saveBookInfoThrowing(contentIndex: damaged)
        book.cacheFormatVersion = "3.0.3"

        let result = try BookContentAnalysisService.load(book: book, regenerateTextCache: true)

        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertTrue(rejections(of: book).isEmpty)
    }

    /// The report stays one line even when the book's title has two.
    func testReportKeepsAMultilineTitleOnOneLine() throws {
        var book = try makeTextBook()
        book.title = "First line\nSecond line \(UUID().uuidString)"
        var damaged = try savedIndex(of: book)
        damaged.totalCharacterCount += 1
        try book.saveBookInfoThrowing(contentIndex: damaged)

        _ = try BookContentAnalysisService.load(book: book)

        let flattenedTitle = book.title.replacingOccurrences(of: "\n", with: " ")
        XCTAssertEqual(
            debugLogLines(containing: "CONTENT_INDEX_REJECTED: \(flattenedTitle): totalCharacterCount is").count,
            1
        )
    }

    // MARK: - Every fixture

    /// Every book in TestData, imported the way a user imports it, saves an
    /// index that passes validation and matches its cache, so opening the
    /// book reuses it: the checks reject nothing the parsers produce.
    func testEveryImportedFixtureKeepsTheFastPath() throws {
        let testData = try requireFile("sample.md").deletingLastPathComponent()
        let fixtures = try FileManager.default.contentsOfDirectory(at: testData, includingPropertiesForKeys: nil)
            .filter { BookFormat.detect(from: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Guard against a vacuous pass if the fixtures cannot be found.
        XCTAssertGreaterThanOrEqual(fixtures.count, 12)

        for fixture in fixtures {
            let name = fixture.lastPathComponent
            let book = try FileImportService.importFile(from: fixture)
            addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
            let saved = try savedIndex(of: book)

            XCTAssertNil(
                saved.validationFailure(for: book.format, audioBaseURL: URL(fileURLWithPath: book.filePath)),
                name
            )
            let result = try BookContentAnalysisService.load(book: book)
            XCTAssertTrue(result.usedPersistedIndex, name)
            XCTAssertEqual(result.index, saved, name)
        }
    }

    // MARK: - Fixtures

    /// Two chapters of reading text. The emoji makes the first chapter's
    /// UTF-16 length (10) differ from its character count; the second
    /// chapter (15 long, starting at 10) has headings at offsets 0 and 11.
    private func textChapters() -> [Chapter] {
        [
            Chapter(title: "One", text: "🙂 one two", headings: [Heading(level: 1, text: "One")]),
            Chapter(title: "Two", text: "three four five", headings: [
                Heading(level: 2, text: "Two", chapterIndex: 1),
                Heading(level: 3, text: "Five", chapterIndex: 1, characterOffset: 11),
            ]),
        ]
    }

    /// The index the builder makes for `textChapters()` as an EPUB.
    private func textIndex() -> BookContentIndex {
        BookContentIndex.build(fromChapters: textChapters(), format: .epub)
    }

    /// One chapter spanning a whole audio file, whose chapters name no file.
    private func singleFileIndex() -> BookContentIndex {
        BookContentIndex.build(
            fromChapters: [Chapter(title: "Whole", text: placeholder(300), headings: [Heading(level: 1, text: "Whole")])],
            format: .audio
        )
    }

    /// The tracks of `multiFileIndex`, relative to its folder.
    private let tracks = ["01.wav", "02.wav", "Disc 2/03.wav"]

    /// Three tracks of 10, 20, and 30 seconds, one in a disc subfolder, as
    /// `analyzeAudio` indexes a folder of files. Unless `folder` comes from
    /// `audioFolder()`, the files need not exist, for checks that look at the
    /// index alone.
    private func multiFileIndex(
        in folder: URL = URL(fileURLWithPath: "/tmp/audio", isDirectory: true)
    ) -> BookContentIndex {
        BookContentIndex.build(
            fromChapters: tracks.enumerated().map { number, track in
                Chapter(
                    title: track,
                    text: placeholder(100 * (number + 1)),
                    headings: [Heading(level: 1, text: track, chapterIndex: number)]
                )
            },
            format: .audio,
            audioFilePaths: tracks.map { folder.appendingPathComponent($0).path },
            audioBaseURL: folder
        )
    }

    /// Two segments of one shared file, as a converted DAISY book has.
    private func segmentedIndex() -> BookContentIndex {
        BookContentIndex.build(
            fromChapters: [
                Chapter(title: "Opening", text: placeholder(50), headings: [Heading(level: 1, text: "Opening")]),
                Chapter(title: "Middle", text: placeholder(75), headings: [Heading(level: 1, text: "Middle", chapterIndex: 1)]),
            ],
            format: .audio,
            audioSegments: [
                AudioSegment(title: "Opening", file: "book.wav", startTime: 0, endTime: 5),
                AudioSegment(title: "Middle", file: "book.wav", startTime: 5, endTime: 12.5),
            ]
        )
    }

    /// Placeholder text of `length` spaces, as the audio parser writes.
    private func placeholder(_ length: Int) -> String {
        String(repeating: " ", count: length)
    }

    /// A new folder under the temporary directory holding every track of
    /// `multiFileIndex` and the shared file of `segmentedIndex`, removed when
    /// the test ends. Validation never reads the files, so they are empty.
    /// The temporary directory lies under /var, a symbolic link to
    /// /private/var, so every folder check also crosses a link.
    private func audioFolder() throws -> URL {
        let folder = try scratchFolder("ContentIndexAudio")
        try createAudioFiles(in: folder)
        return folder
    }

    /// Create the (empty) files of `audioFolder()` inside `folder`, creating
    /// the folder and its subfolders as needed.
    private func createAudioFiles(in folder: URL) throws {
        for file in tracks + ["book.wav"] {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
    }

    /// A new, empty folder under the temporary directory, removed when the
    /// test ends.
    private func scratchFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Replace the file at `relativePath` inside `folder` with a symbolic
    /// link to `destination`.
    private func replaceWithLink(_ relativePath: String, in folder: URL, to destination: URL) throws {
        let link = folder.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    // MARK: - Book fixtures

    /// A Markdown book as a completed import leaves it: source, current
    /// content.md, and the index built from them saved in bookInfo.json. Its
    /// two chapters make offsets between chapters observable. The title is
    /// unique, so each test finds only its own debug log reports.
    private func makeTextBook() throws -> Book {
        let package = try makePackage("ContentIndexText")
        let source = package.url.appendingPathComponent("book.md")
        try """
        <!-- chapter: First -->
        # First

        One two three.

        <!-- chapter: Second -->
        # Second

        Four five.

        ## Later

        Six seven eight.
        """.write(to: source, atomically: true, encoding: .utf8)
        var book = Book(
            title: "Index Fixture \(UUID().uuidString)", format: .markdown, filePath: source.path,
            md5Hash: UUID().uuidString, tmbDirectoryName: package.name
        )
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))
        XCTAssertEqual(index.chapters.count, 2)
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: index, cacheFormatVersion: book.cacheFormatVersion
        )
        return book
    }

    /// A multi-file audiobook whose audio folder holds `tracks` as real
    /// one-second WAVs, analyzed once and saved, as an audio import leaves it.
    private func makeAudioBook() throws -> Book {
        let package = try makePackage("ContentIndexAudio")
        let folder = package.url.appendingPathComponent("audio", isDirectory: true)
        for track in tracks {
            try writeSilence(to: folder.appendingPathComponent(track))
        }
        let book = Book(
            title: "Index Fixture \(UUID().uuidString)", format: .audio, filePath: folder.path,
            md5Hash: UUID().uuidString, tmbDirectoryName: package.name
        )
        let analysis = try BookContentAnalysisService.load(book: book)
        XCTAssertFalse(analysis.usedPersistedIndex)
        try LibraryPersistenceService.saveContentAnalysis(for: book, index: analysis.index, cacheFormatVersion: nil)
        return book
    }

    /// A new package folder in the hosted test library, removed when the
    /// test ends.
    private func makePackage(_ prefix: String) throws -> (name: String, url: URL) {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "\(prefix)-\(UUID().uuidString).tmb"
        let url = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (name, url)
    }

    /// The index saved in `book`'s package.
    private func savedIndex(of book: Book) throws -> BookContentIndex {
        try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
    }

    /// The debug log's reports of an index rejected for `book`, each from
    /// its prefix onwards (without the timestamp).
    private func rejections(of book: Book) -> [String] {
        debugLogLines(containing: "CONTENT_INDEX_REJECTED: \(book.title):").compactMap { line in
            line.range(of: "CONTENT_INDEX_REJECTED:").map { String(line[$0.lowerBound...]) }
        }
    }

    /// `result`'s audio files relative to `book`'s audio folder. Both sides
    /// are compared through their resolved locations, because parsing
    /// reports files by the folder's canonical path (/private/var for /var);
    /// a file outside the folder keeps its full resolved path.
    private func relativeAudioPaths(of result: BookContentAnalysisService.Result, in book: Book) -> [String]? {
        let prefix = URL(fileURLWithPath: book.filePath).resolvingSymlinksInPath().path + "/"
        return result.audioFilePaths?.map { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : resolved
        }
    }

    /// Assert that `result` pairs its content with an index describing
    /// exactly that content: the same index, one entry per chapter with the
    /// length the reader sees, valid for the book, and for audio one file
    /// per chapter.
    private func assertAligned(
        _ result: BookContentAnalysisService.Result,
        for book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.content.contentIndex, result.index, file: file, line: line)
        XCTAssertEqual(
            result.index.chapters.map(\.characterCount),
            result.content.chapters.map(\.text.utf16Length),
            file: file, line: line
        )
        XCTAssertNil(
            result.index.validationFailure(for: book.format, audioBaseURL: URL(fileURLWithPath: book.filePath)),
            file: file, line: line
        )
        if book.format.isAudio {
            XCTAssertEqual(result.audioFilePaths?.count, result.content.chapters.count, file: file, line: line)
        }
    }

    /// Save `result` as callers do after a fresh analysis and assert that
    /// the next load reuses exactly that index.
    private func assertRepairIsReused(
        _ result: BookContentAnalysisService.Result,
        for book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: result.index, cacheFormatVersion: result.cacheFormatVersion
        )
        let reopened = try BookContentAnalysisService.load(book: book)
        XCTAssertTrue(reopened.usedPersistedIndex, file: file, line: line)
        XCTAssertEqual(reopened.index, result.index, file: file, line: line)
    }

    /// `index` with new chapter lengths and everything derived from them
    /// (start offsets, global heading offsets, the total) kept consistent,
    /// so a test can reach huge counts without allocating their text.
    private func resized(_ index: BookContentIndex, to lengths: [Int]) -> BookContentIndex {
        var resized = index
        var start = 0
        for (position, length) in lengths.enumerated() {
            resized.chapters[position].characterCount = length
            resized.chapters[position].startCharacterOffset = start
            for heading in resized.chapters[position].headings.indices {
                resized.chapters[position].headings[heading].globalCharacterOffset =
                    start + resized.chapters[position].headings[heading].characterOffset
            }
            start += length
        }
        resized.totalCharacterCount = start
        return resized
    }
}
