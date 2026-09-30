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

        XCTAssertNil(index.validationFailure(for: .epub))
        XCTAssertTrue(index.isValid(for: .epub))
    }

    /// Every audio layout the builder makes passes: a single file whose
    /// chapters name no file, one file per chapter, and segments of a file.
    func testBuiltAudioIndexesAreValid() {
        for index in [singleFileIndex(), multiFileIndex(), segmentedIndex()] {
            XCTAssertNil(index.validationFailure(for: .audio), "\(String(describing: index.audioLayout))")
            XCTAssertTrue(index.isValid(for: .audio))
        }
    }

    // MARK: - Identity

    /// An index from another builder version may derive text differently.
    func testOutdatedVersionIsRejected() {
        var index = textIndex()
        index.version = "0.9.0"

        XCTAssertEqual(
            index.validationFailure(for: .epub),
            "version \"0.9.0\" is not the current \"\(BookContentIndex.currentVersion)\""
        )
        XCTAssertFalse(index.isValid(for: .epub))
    }

    /// An index made for another format describes a different reading.
    func testIndexForAnotherFormatIsRejected() {
        XCTAssertEqual(
            textIndex().validationFailure(for: .txt),
            "format epub does not match the book's format txt"
        )
    }

    /// A text book's index must be a text index, and an audio book's audio.
    func testKindThatDoesNotSuitTheFormatIsRejected() {
        var index = textIndex()
        index.kind = .audio

        XCTAssertEqual(index.validationFailure(for: .epub), "kind audio does not match format epub")
    }

    // MARK: - Chapters

    /// A book always has at least one chapter; an empty list is damage.
    func testEmptyChapterListIsRejected() {
        var index = textIndex()
        index.chapters = []

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters is empty")
    }

    /// Headings name their chapter by number, so numbers must match places.
    func testChapterOutOfPlaceIsRejected() {
        var index = textIndex()
        index.chapters[1].chapterIndex = 2

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[1].chapterIndex is 2, expected 1")
    }

    func testNegativeCharacterCountIsRejected() {
        var index = textIndex()
        index.chapters[1].characterCount = -5

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[1].characterCount is -5, below 0")
    }

    /// Word counts can be neither negative nor larger than the character
    /// count, since every word holds at least one character.
    func testWordCountOutsideTheChapterIsRejected() {
        var negative = textIndex()
        negative.chapters[1].wordCount = -1
        var excessive = textIndex()
        excessive.chapters[0].wordCount = 11

        XCTAssertEqual(negative.validationFailure(for: .epub), "chapters[1].wordCount is -1, outside 0 through 15")
        XCTAssertEqual(excessive.validationFailure(for: .epub), "chapters[0].wordCount is 11, outside 0 through 10")
    }

    /// Chapter start offsets are the running sums of the lengths before
    /// them; anything else misplaces every reading position after it.
    func testStartOffsetThatIsNotTheRunningSumIsRejected() {
        var index = textIndex()
        index.chapters[1].startCharacterOffset = 9

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[1].startCharacterOffset is 9, expected 10")
    }

    func testCharacterTotalMismatchIsRejected() {
        var index = textIndex()
        index.totalCharacterCount = 24

        XCTAssertEqual(index.validationFailure(for: .epub), "totalCharacterCount is 24, expected 25")
    }

    func testWordTotalMismatchIsRejected() {
        var index = textIndex()
        index.totalWordCount = 7

        XCTAssertEqual(index.validationFailure(for: .epub), "totalWordCount is 7, expected 6")
    }

    /// One chapter longer than any real book is rejected before playback
    /// could allocate a placeholder of that length.
    func testOversizedChapterIsRejected() {
        let index = resized(textIndex(), to: [10, limit + 1])

        XCTAssertEqual(
            index.validationFailure(for: .epub),
            "chapters[1].characterCount is \(limit + 1), above the limit of \(limit)"
        )
    }

    /// Chapters each within the limit can still add up past it.
    func testOversizedBookIsRejected() {
        let index = resized(textIndex(), to: [limit / 2 + 1, limit / 2 + 1])

        XCTAssertEqual(
            index.validationFailure(for: .epub),
            "the chapters hold \(limit + 2) characters, above the limit of \(limit)"
        )
    }

    /// The limit itself is allowed, for one chapter and for the book.
    func testBookAtTheLimitIsValid() {
        XCTAssertNil(resized(textIndex(), to: [limit - 15, 15]).validationFailure(for: .epub))
    }

    /// Counts near `Int.max` fail cleanly instead of overflowing a sum.
    func testExtremeCountsFailWithoutOverflow() {
        var index = textIndex()
        index.chapters[0].characterCount = .max
        index.chapters[1].startCharacterOffset = .max
        index.totalCharacterCount = .max

        XCTAssertEqual(
            index.validationFailure(for: .epub),
            "chapters[0].characterCount is \(Int.max), above the limit of \(limit)"
        )
    }

    // MARK: - Headings

    func testHeadingLevelZeroIsRejected() {
        var index = textIndex()
        index.chapters[0].headings[0].level = 0

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[0].headings[0].level is 0, outside 1 through 6")
    }

    func testHeadingLevelSevenIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[1].level = 7

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[1].headings[1].level is 7, outside 1 through 6")
    }

    func testHeadingWithoutIDIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[0].id = ""

        XCTAssertEqual(index.validationFailure(for: .epub), "chapters[1].headings[0].id is empty")
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
            pastEnd.validationFailure(for: .epub),
            "chapters[1].headings[1].characterOffset is 16, outside 0 through 15"
        )
        XCTAssertEqual(
            beforeStart.validationFailure(for: .epub),
            "chapters[1].headings[0].characterOffset is -1, outside 0 through 15"
        )
    }

    /// A heading may sit at the very end of its chapter.
    func testHeadingAtTheEndOfItsChapterIsValid() {
        var index = textIndex()
        index.chapters[1].headings[1].characterOffset = 15
        index.chapters[1].headings[1].globalCharacterOffset = 25

        XCTAssertNil(index.validationFailure(for: .epub))
    }

    /// The global offset must be the chapter's start plus the local offset;
    /// here it repeats the local offset, as a builder bug could.
    func testWrongGlobalHeadingOffsetIsRejected() {
        var index = textIndex()
        index.chapters[1].headings[1].globalCharacterOffset = 11

        XCTAssertEqual(
            index.validationFailure(for: .epub),
            "chapters[1].headings[1].globalCharacterOffset is 11, expected 21"
        )
    }

    /// Headings within a chapter are stored in reading order.
    func testHeadingsOutOfOrderAreRejected() {
        var index = textIndex()
        index.chapters[1].headings.reverse()

        XCTAssertEqual(
            index.validationFailure(for: .epub),
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

        XCTAssertEqual(layout.validationFailure(for: .epub), "audioLayout is present in a text index")
        XCTAssertEqual(duration.validationFailure(for: .epub), "totalAudioDuration is present in a text index")
        XCTAssertEqual(chapterAudio.validationFailure(for: .epub), "chapters[1].audio is present in a text index")
    }

    // MARK: - Audio

    func testAudioIndexWithoutLayoutIsRejected() {
        var index = multiFileIndex()
        index.audioLayout = nil

        XCTAssertEqual(index.validationFailure(for: .audio), "audioLayout is missing")
    }

    func testAudioChapterWithoutTimingIsRejected() {
        var index = multiFileIndex()
        index.chapters[1].audio = nil

        XCTAssertEqual(index.validationFailure(for: .audio), "chapters[1].audio is missing")
    }

    /// Playback restores at least one placeholder character per chapter, so
    /// a zero-length audio chapter would disagree with its restored text.
    func testEmptyAudioChapterIsRejected() {
        let index = resized(multiFileIndex(), to: [100, 0, 300])

        XCTAssertEqual(
            index.validationFailure(for: .audio),
            "chapters[1].characterCount is 0, but an audio chapter holds at least 1 placeholder character"
        )
    }

    func testNonFiniteStartTimeIsRejected() {
        var index = segmentedIndex()
        index.chapters[1].audio?.startTime = .nan

        XCTAssertEqual(
            index.validationFailure(for: .audio),
            "chapters[1].audio.startTime is nan, expected a finite number of seconds, 0 or more"
        )
    }

    func testNegativeStartTimeIsRejected() {
        var index = segmentedIndex()
        index.chapters[0].audio?.startTime = -1

        XCTAssertEqual(
            index.validationFailure(for: .audio),
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
                index.validationFailure(for: .audio),
                "chapters[2].audio.duration is \(duration), expected a finite number of seconds, 0 or more"
            )
        }
    }

    func testNegativeDurationIsRejected() {
        var index = multiFileIndex()
        index.chapters[2].audio?.duration = -10

        XCTAssertEqual(
            index.validationFailure(for: .audio),
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

        XCTAssertEqual(larger.validationFailure(for: .audio), "totalAudioDuration is 61.0, expected 60.0")
        XCTAssertEqual(missing.validationFailure(for: .audio), "totalAudioDuration is missing")
        XCTAssertEqual(notANumber.validationFailure(for: .audio), "totalAudioDuration is nan, expected 60.0")
    }

    /// Rounding far below a millisecond is not damage.
    func testDurationTotalWithinToleranceIsValid() {
        var index = multiFileIndex()
        index.totalAudioDuration = 60.0005

        XCTAssertNil(index.validationFailure(for: .audio))
    }

    /// Every chapter of a multi-file book must name its file; a missing or
    /// empty path used to drop out and shift later chapters' files.
    func testMultiFileChapterWithoutPathIsRejected() {
        for path in [nil, ""] {
            var index = multiFileIndex()
            index.chapters[1].audio?.relativeFilePath = path

            XCTAssertEqual(
                index.validationFailure(for: .audio),
                "chapters[1].audio.relativeFilePath is missing",
                String(describing: path)
            )
        }
    }

    func testAbsoluteAudioPathIsRejected() {
        var index = multiFileIndex()
        index.chapters[1].audio?.relativeFilePath = "/etc/hosts"

        XCTAssertEqual(
            index.validationFailure(for: .audio),
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
                index.validationFailure(for: .audio),
                "chapters[1].audio.relativeFilePath \(String(reflecting: path)) contains a \"..\" component"
            )
        }
    }

    /// Segments name their shared file per chapter and are checked the same way.
    func testSegmentedPathsAreChecked() {
        var index = segmentedIndex()
        index.chapters[0].audio?.relativeFilePath = "../book.wav"

        XCTAssertEqual(
            index.validationFailure(for: .audio),
            "chapters[0].audio.relativeFilePath \"../book.wav\" contains a \"..\" component"
        )
    }

    // MARK: - Fixtures

    /// A two-chapter text index. The emoji makes the first chapter's UTF-16
    /// length (10) differ from its character count; the second chapter
    /// (15 long, starting at 10) has headings at offsets 0 and 11.
    private func textIndex() -> BookContentIndex {
        BookContentIndex.build(
            fromChapters: [
                Chapter(title: "One", text: "🙂 one two", headings: [Heading(level: 1, text: "One")]),
                Chapter(title: "Two", text: "three four five", headings: [
                    Heading(level: 2, text: "Two", chapterIndex: 1),
                    Heading(level: 3, text: "Five", chapterIndex: 1, characterOffset: 11),
                ]),
            ],
            format: .epub
        )
    }

    /// One chapter spanning a whole audio file, whose chapters name no file.
    private func singleFileIndex() -> BookContentIndex {
        BookContentIndex.build(
            fromChapters: [Chapter(title: "Whole", text: placeholder(300), headings: [Heading(level: 1, text: "Whole")])],
            format: .audio
        )
    }

    /// Three tracks of 10, 20, and 30 seconds, one in a disc subfolder,
    /// as `analyzeAudio` indexes a folder of files. The files need not exist:
    /// these checks look at the index alone.
    private func multiFileIndex() -> BookContentIndex {
        let folder = URL(fileURLWithPath: "/tmp/audio", isDirectory: true)
        let tracks = ["01.wav", "02.wav", "Disc 2/03.wav"]
        return BookContentIndex.build(
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
