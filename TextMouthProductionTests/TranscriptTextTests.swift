import XCTest
@testable import TextMouth

/// A transcript as an audiobook's text (FR05): its sentences laid over the
/// book's chapters, whatever the book's layout; content.md written from
/// them and read back exactly; the index that aligns each sentence with its
/// stretch of the chapter's audio, validated as a text book's is; the cursor
/// placed by time and a time found for a place in the text; and the text
/// saved into the book, read as it opens, written again when content.md or
/// its index is lost or edited, and set aside once the audio changes.
@MainActor
final class TranscriptTextTests: XCTestCase {

    // MARK: - Laying a Transcript over Chapters

    /// Each file of a multi-file book is its chapter, timed from its start.
    func testEachFileOfAMultiFileBookIsItsChapter() throws {
        let world = try makeIntegrationWorld("Transcript Multi-File")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Self.sentences)

        let chapters = TranscriptTextBuilder.chapters(of: transcript, over: try audioIndex(of: book), bookFileName: "")

        XCTAssertEqual(chapters.map(\.title), ["01", "02"])
        XCTAssertEqual(chapters.map { $0.sentences.map(\.text) }, [
            ["Quillwort grows by the ferry slip.", "Tide tables hang in the harbor office.", "Nobody reads them twice."],
            ["The salt road bends east.", "Carts wait at the toll."],
        ])
        let secondChapter = try XCTUnwrap(chapters[safe: 1], "the transcript has no second chapter")
        XCTAssertEqual(secondChapter.sentences.map(\.startMilliseconds), [0, 1_980])
    }

    /// A segmented book's chapter takes the sentences its clips play, timed
    /// as its clips play one after another, across files; a sentence goes to
    /// the chapter that plays the most of it, so one whose start the
    /// recognizer placed in the pause before a chapter opens that chapter;
    /// and a sentence no chapter plays is left out.
    func testASegmentedChapterTakesTheSentencesItsClipsPlay() throws {
        let world = try makeIntegrationWorld("Transcript Segmented")
        let book = try world.makeSegmentedAudioBook(
            title: "Toll Road",
            files: ["a.wav": 10, "b.wav": 10],
            sections: [
                AudioSegment(title: "Gate", file: "a.wav", startTime: 0, endTime: 6),
                try XCTUnwrap(AudioSegment(title: "Bridge", clips: [
                    AudioClip(file: "a.wav", startTime: 6, endTime: 10),
                    AudioClip(file: "b.wav", startTime: 0, endTime: 4),
                ])),
                AudioSegment(title: "Market", file: "b.wav", startTime: 4, endTime: 8),
            ]
        )
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: [
            "a.wav": [
                TranscriptFixtures.sentence("Carts queue at the gate.", from: 0, to: 2_400),
                TranscriptFixtures.sentence("The keeper counts them.", from: 2_400, to: 5_700),
                TranscriptFixtures.sentence("The bridge sways underfoot.", from: 5_700, to: 8_000),
                TranscriptFixtures.sentence("Nobody looks down.", from: 8_000, to: 9_500),
            ],
            "b.wav": [
                TranscriptFixtures.sentence("Then the far bank.", from: 0, to: 3_500),
                TranscriptFixtures.sentence("Stalls line the square.", from: 4_200, to: 7_000),
                TranscriptFixtures.sentence("Music plays past closing.", from: 8_500, to: 9_800),
            ],
        ])

        let chapters = TranscriptTextBuilder.chapters(of: transcript, over: try audioIndex(of: book), bookFileName: "")

        XCTAssertEqual(chapters.map(\.title), ["Gate", "Bridge", "Market"])
        XCTAssertEqual(chapters.map { $0.sentences.map(\.text) }, [
            ["Carts queue at the gate.", "The keeper counts them."],
            ["The bridge sways underfoot.", "Nobody looks down.", "Then the far bank."],
            ["Stalls line the square."],
        ])
        let secondChapter = try XCTUnwrap(chapters[safe: 1], "the transcript has no second chapter")
        let thirdChapter = try XCTUnwrap(chapters[safe: 2], "the transcript has no third chapter")
        XCTAssertEqual(secondChapter.sentences.map(\.startMilliseconds), [0, 2_000, 4_000])
        XCTAssertEqual(secondChapter.sentences.map(\.endMilliseconds), [2_000, 3_500, 7_500])
        XCTAssertEqual(thirdChapter.sentences.map(\.startMilliseconds), [200])
    }

    /// A single file's chapters split its sentences where the reader starts
    /// each chapter, and time them from there.
    func testAChapteredFilesSentencesAreSplitAtItsChapters() throws {
        let audio = BookContentIndex.build(
            fromChapters: [
                Chapter(title: "Morning", text: String(repeating: " ", count: 100)),
                Chapter(title: "Evening", text: String(repeating: " ", count: 200)),
            ],
            format: .audio
        )
        let transcript = TranscriptFixtures.transcript([(path: "book.m4b", duration: 30_000, sentences: [
            TranscriptFixtures.sentence("The ferry leaves early.", from: 0, to: 4_000),
            TranscriptFixtures.sentence("It returns at dusk.", from: 9_000, to: 12_000),
            TranscriptFixtures.sentence("Lamps are lit.", from: 15_000, to: 18_000),
        ])])

        let chapters = TranscriptTextBuilder.chapters(of: transcript, over: audio, bookFileName: "book.m4b")

        XCTAssertEqual(chapters.map { $0.sentences.map(\.text) }, [
            ["The ferry leaves early."],
            ["It returns at dusk.", "Lamps are lit."],
        ])
        let secondChapter = try XCTUnwrap(chapters[safe: 1], "the transcript has no second chapter")
        XCTAssertEqual(secondChapter.sentences.map(\.startMilliseconds), [0, 5_000])
        XCTAssertEqual(secondChapter.sentences.map(\.endMilliseconds), [2_000, 8_000])
    }

    // MARK: - content.md

    /// content.md gives every chapter its marker and a heading, a chapter
    /// without a title a numbered one, and writes each paragraph as one line
    /// of literal Markdown: a new paragraph after four sentences, before a
    /// sentence that would take it past 600 characters, and after two
    /// seconds of silence.
    func testContentMarkdownHasAHeadingPerChapterAndAParagraphPerFewSentences() {
        let first = String(repeating: "a", count: 299) + "."
        let second = String(repeating: "b", count: 249) + "."
        let third = String(repeating: "c", count: 99) + "."
        let chapters = [
            TranscriptTextBuilder.ChapterTranscript(title: "The\nFerry", sentences: [
                sentence("One.", 0, 1_000), sentence("Two.", 1_000, 2_000), sentence("Three.", 2_000, 3_000),
                sentence("Four.", 3_000, 4_000), sentence("Five.", 4_000, 5_000), sentence("Six.", 7_000, 8_000),
            ]),
            TranscriptTextBuilder.ChapterTranscript(title: " ", sentences: [
                sentence(first, 0, 20_000), sentence(second, 20_000, 36_000), sentence(third, 36_000, 42_000),
            ]),
        ]

        let markdown = TranscriptTextBuilder.markdown(of: chapters)

        XCTAssertEqual(markdown, """
        <!-- chapter: The Ferry -->
        # The Ferry

        One\\. Two\\. Three\\. Four\\.

        Five\\.

        Six\\.

        <!-- chapter: Heading 2 -->
        # Heading 2

        \(first.dropLast())\\. \(second.dropLast())\\.

        \(third.dropLast())\\.
        """)
    }

    /// The text reads back exactly as the transcript wrote it, Markdown's
    /// own characters included, with every sentence placed where it lies,
    /// and its index passes validation and lines up with it, as a text
    /// book's index does.
    func testTheTextReadsBackExactlyWithEverySentencePlaced() throws {
        let tricky = [
            "# Not a heading.", "*Stars* and _underscores_ stay.", "1. Not a list?", "<b>Not markup</b> here.",
            "A | B | C.", "\"Quotes\" -- and dashes... stay straight.", "Back\\slash & ampersand;", "Café naïve über.",
        ]
        let chapters = [
            TranscriptTextBuilder.ChapterTranscript(
                title: "Chapter *One*",
                sentences: tricky.enumerated().map { sentence($1, $0 * 1_000, $0 * 1_000 + 900) }
            ),
            TranscriptTextBuilder.ChapterTranscript(title: "Quiet", sentences: []),
        ]

        let text = try XCTUnwrap(TranscriptTextBuilder.text(of: chapters, bookTitle: "Toll Road", bookAuthor: "Unknown"))

        XCTAssertEqual(text.chapters.count, 2)
        let firstChapter = try XCTUnwrap(text.chapters[safe: 0], "the transcript has no first chapter")
        let secondChapter = try XCTUnwrap(text.chapters[safe: 1], "the transcript has no second chapter")
        let firstSentences = try XCTUnwrap(text.sentences[safe: 0], "the text has no sentences for its first chapter")
        XCTAssertEqual(firstChapter.headings.map(\.text), ["Chapter *One*"])
        XCTAssertEqual(secondChapter.text, "Quiet")
        let chapterText = Array(firstChapter.text.utf16)
        XCTAssertEqual(firstSentences.count, tricky.count)
        for (placed, expected) in zip(firstSentences, tricky) {
            // A sentence placed outside its chapter's text would trap the
            // slice below, so it stops the test instead.
            guard placed.characterOffset >= 0, placed.characterOffset <= placed.characterEnd,
                  placed.characterEnd <= chapterText.count else {
                XCTFail("the sentence \"\(expected)\" is placed outside its chapter's text")
                return
            }
            let found = String(decoding: chapterText[placed.characterOffset..<placed.characterEnd], as: UTF16.self)
            XCTAssertEqual(found, expected)
        }
        XCTAssertEqual(firstSentences.map(\.startMilliseconds), Array(stride(from: 0, to: 8_000, by: 1_000)))
        XCTAssertNil(text.readingIndex.validationFailure(for: .markdown, audioBaseURL: nil))
        XCTAssertNil(text.readingIndex.alignmentFailure(with: text.chapters))
    }

    // MARK: - Time and Place

    /// A time places the cursor at the start of the sentence heard then:
    /// the chapter's start before the first sentence, the next sentence's
    /// start in a pause, and the last sentence's start after it.
    func testATimePlacesTheCursorAtTheSentenceHeard() {
        let text = Self.timedText
        XCTAssertEqual(text.textOffset(atChapterTime: 0.5, inChapter: 0), 0)
        XCTAssertEqual(text.textOffset(atChapterTime: 1, inChapter: 0), 7)
        XCTAssertEqual(text.textOffset(atChapterTime: 2.9, inChapter: 0), 7)
        XCTAssertEqual(text.textOffset(atChapterTime: 3, inChapter: 0), 18, "in the pause before the second sentence")
        XCTAssertEqual(text.textOffset(atChapterTime: 4, inChapter: 0), 18)
        XCTAssertEqual(text.textOffset(atChapterTime: 4.5, inChapter: 0), 30)
        XCTAssertEqual(text.textOffset(atChapterTime: 99, inChapter: 0), 30)
        XCTAssertEqual(text.textOffset(atChapterTime: 5, inChapter: 1), 0, "a chapter without sentences")
        XCTAssertEqual(text.textOffset(atChapterTime: 5, inChapter: 7), 0, "no such chapter")
    }

    /// A place in the text has the time its sentence was heard: the
    /// chapter's start in the heading, the next sentence's between two, and
    /// the last sentence's end after it.
    func testAPlaceInTheTextHasTheTimeItsSentenceWasHeard() {
        let text = Self.timedText
        XCTAssertEqual(text.chapterTime(atTextOffset: 0, inChapter: 0), 0)
        XCTAssertEqual(text.chapterTime(atTextOffset: 3, inChapter: 0), 0, "the heading")
        XCTAssertEqual(text.chapterTime(atTextOffset: 7, inChapter: 0), 1)
        XCTAssertEqual(text.chapterTime(atTextOffset: 16, inChapter: 0), 1)
        XCTAssertEqual(text.chapterTime(atTextOffset: 17, inChapter: 0), 4, "between the sentences")
        XCTAssertEqual(text.chapterTime(atTextOffset: 20, inChapter: 0), 4)
        XCTAssertEqual(text.chapterTime(atTextOffset: 30, inChapter: 0), 4.5)
        XCTAssertEqual(text.chapterTime(atTextOffset: 39, inChapter: 0), 4.5)
        XCTAssertEqual(text.chapterTime(atTextOffset: 40, inChapter: 0), 6, "past the last sentence")
    }

    /// The reader's audio cursor, ten characters a second, converts both
    /// ways through the sentences.
    func testTheReadersAudioCursorConvertsThroughTheSentences() {
        let text = Self.timedText
        XCTAssertEqual(text.textOffset(atAudioOffset: 12, inChapter: 0), 7)
        XCTAssertEqual(text.textOffset(atAudioOffset: 41, inChapter: 0), 18)
        XCTAssertEqual(text.audioOffset(atTextOffset: 20, inChapter: 0), 40)
        XCTAssertEqual(text.audioOffset(atTextOffset: 30, inChapter: 0), 45)
        XCTAssertEqual(text.audioOffset(atTextOffset: 0, inChapter: 0), 0)
    }

    /// The sentence heard at the reader's audio cursor is the one whose
    /// start the cursor converts to, so Where Am I quotes the sentence the
    /// reader's text is shown around: none before the first sentence, the
    /// next one in a pause, the last one after it, and none in a chapter
    /// without sentences.
    func testTheSentenceHeardAtTheReadersAudioCursorIsTheOneTheTextShows() {
        let text = Self.timedText
        XCTAssertNil(text.sentenceText(atAudioOffset: 5, inChapter: 0), "before the first sentence")
        XCTAssertEqual(text.sentenceText(atAudioOffset: 12, inChapter: 0), "First one.")
        XCTAssertEqual(text.sentenceText(atAudioOffset: 35, inChapter: 0), "Second one.", "in the pause before it")
        XCTAssertEqual(text.sentenceText(atAudioOffset: 41, inChapter: 0), "Second one.")
        XCTAssertEqual(text.sentenceText(atAudioOffset: 600, inChapter: 0), "Third one.", "past the last sentence")
        XCTAssertNil(text.sentenceText(atAudioOffset: 50, inChapter: 1), "a chapter without sentences")
        XCTAssertNil(text.sentenceText(atAudioOffset: 50, inChapter: 7), "no such chapter")
        for audioOffset in 0...70 {
            XCTAssertEqual(
                text.sentence(atAudioOffset: audioOffset, inChapter: 0)?.characterOffset ?? 0,
                text.textOffset(atAudioOffset: audioOffset, inChapter: 0),
                "audio offset \(audioOffset)"
            )
        }
    }

    // MARK: - Saving a Transcript into Its Book

    /// Saving a transcript writes transcript.json and, from it, content.md;
    /// the book's audio index carries the text's layer, which validates
    /// against the audio and fingerprints both files; the record notes the
    /// transcript; and the book reads as text, chapter by chapter, its
    /// sentences timed, while its audio index and position are unchanged.
    func testSavingATranscriptMakesItTheBooksText() throws {
        let world = try makeIntegrationWorld("Transcript Saved")
        let book = try world.makeSilentAudioBook(
            title: "Harbor Notes",
            trackDurations: [9, 6],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 25)
        )
        let audioBefore = try audioIndex(of: book)
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Self.sentences)

        let installation = try TranscriptStore.install(transcript, for: book)

        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(transcript))
        let cache = MarkdownCacheService.cacheURL(for: book)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), Self.expectedMarkdown)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.transcript, transcript.note)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 25)
        let saved = try XCTUnwrap(record.contentIndex)
        XCTAssertEqual(saved, installation.index)
        var audioOnly = saved
        audioOnly.transcript = nil
        XCTAssertEqual(audioOnly, audioBefore, "the audio index itself is unchanged")
        let layer = try XCTUnwrap(saved.transcript)
        XCTAssertNil(layer.validationFailure(against: saved))
        XCTAssertEqual(layer.transcript, transcript.note)
        XCTAssertEqual(layer.audioFiles, transcript.audioFiles)
        XCTAssertEqual(layer.textCacheFingerprint.source.digest, try FileImportService.md5Hash(of: TextMouthPaths.transcriptPath(in: book.tmbDirectory)))
        XCTAssertEqual(layer.textCacheFingerprint.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(layer.chapters.map { $0.sentences.count }, [3, 2])

        let text = installation.text
        XCTAssertEqual(text.chapters.map(\.title), ["01", "02"])
        XCTAssertEqual(text.chapterText(0), "01\n\nQuillwort grows by the ferry slip. Tide tables hang in the harbor office. "
            + "Nobody reads them twice.")
        XCTAssertEqual(text.textOffset(atChapterTime: 2.5, inChapter: 0), 39, "the second sentence")
        XCTAssertEqual(text.chapterTime(atTextOffset: 39, inChapter: 0), 2.4)
        XCTAssertEqual(text.textOffset(atAudioOffset: 25, inChapter: 1), 30, "the book's saved position, in the text")
    }

    /// A save of the book's state keeps the record's note of its transcript;
    /// an index written without the text's layer clears it, since the note
    /// follows the index it describes.
    func testTheRecordsNoteFollowsTheIndex() throws {
        let world = try makeIntegrationWorld("Transcript Note")
        var book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Self.sentences)
        let installation = try TranscriptStore.install(transcript, for: book)

        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 12)
        try book.saveBookInfoThrowing()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.transcript, transcript.note)

        var withoutText = installation.index
        withoutText.transcript = nil
        try book.saveBookInfoThrowing(contentIndex: withoutText)
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).state.transcript)
    }

    /// Transcribing a book again replaces its transcript and text, and drops
    /// the reading text this Mac kept for it.
    func testTranscribingAgainReplacesTheTextAndDropsTheKeptReadingText() throws {
        let world = try makeIntegrationWorld("Transcript Again")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let kept = ReadingTextCache.shared.url(for: book.id)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept reading text".utf8).write(to: kept)
        addTeardownBlock { ReadingTextCache.shared.remove(bookID: book.id) }

        let again = try TranscriptFixtures.transcript(of: book, sentences: [
            "01.wav": [TranscriptFixtures.sentence("Quillwort grows by the ferry slipway.", from: 0, to: 2_400)],
        ])
        let installation = try TranscriptStore.install(again, for: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(again))
        XCTAssertEqual(installation.text.chapterText(0), "01\n\nQuillwort grows by the ferry slipway.")
        XCTAssertEqual(installation.text.chapterText(1), "02")
        XCTAssertEqual(try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8),
                       TranscriptTextBuilder.markdown(of: TranscriptTextBuilder.chapters(
                           of: again, over: try audioIndex(of: book), bookFileName: ""
                       )))
    }

    // MARK: - Reading the Text as the Book Opens

    /// A saved text is read as the book opens, from content.md, without
    /// writing anything, and its index needs no saving.
    func testASavedTextIsReadWithoutWritingAnything() throws {
        let world = try makeIntegrationWorld("Transcript Read")
        let title = uniqueTitle("Harbor Notes")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [9, 6])
        let installation = try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let stamp = FileStamp(of: cache)

        let load = TranscriptTextLoader.load(for: book, audioIndex: try savedIndex(of: book))

        XCTAssertFalse(load.indexChanged)
        XCTAssertEqual(load.index, installation.index)
        XCTAssertEqual(load.text?.chapters.map(\.text), installation.text.chapters.map(\.text))
        XCTAssertEqual(FileStamp(of: cache), stamp)
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_TEXT_REBUILT: \(title):"), [])
    }

    /// A book without a transcript is left alone: no text, no change, and
    /// no file made.
    func testABookWithoutATranscriptIsLeftAlone() throws {
        let world = try makeIntegrationWorld("Transcript None")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        let index = try savedIndex(of: book)

        let load = TranscriptTextLoader.load(for: book, audioIndex: index)

        XCTAssertNil(load.text)
        XCTAssertFalse(load.indexChanged)
        XCTAssertEqual(load.index, index)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: book.tmbDirectory.path).sorted(),
                       ["Tracks", "bookInfo.json", "contentIndex.json"])
    }

    /// An index that lost the text's layer, as an index made afresh from the
    /// audio has none, gets it back from transcript.json, without content.md
    /// being written again when it holds the text already.
    func testALostLayerIsMadeAgainFromTheTranscript() throws {
        let world = try makeIntegrationWorld("Transcript Lost Layer")
        let title = uniqueTitle("Harbor Notes")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [9, 6])
        let installation = try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let stamp = FileStamp(of: cache)
        var audioOnly = installation.index
        audioOnly.transcript = nil

        let load = TranscriptTextLoader.load(for: book, audioIndex: audioOnly)

        XCTAssertTrue(load.indexChanged)
        XCTAssertEqual(load.index.transcript?.chapters, installation.index.transcript?.chapters)
        XCTAssertNotNil(load.text)
        XCTAssertEqual(FileStamp(of: cache), stamp, "content.md already held the text")
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_TEXT_REBUILT: \(title): content.md and its index were written "
            + "again from transcript.json: the book's index holds no transcript text").count, 1)
    }

    /// A content.md edited by hand no longer matches what the transcript
    /// wrote, so it is written again from transcript.json as the book
    /// opens, and the change is logged without quoting the book.
    func testAnEditedTextIsWrittenAgainFromTheTranscript() throws {
        let world = try makeIntegrationWorld("Transcript Edited")
        let title = uniqueTitle("Harbor Notes")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [9, 6])
        let installation = try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        try Data((Self.expectedMarkdown + "\n\nA line added by hand.").utf8).write(to: cache)

        let load = TranscriptTextLoader.load(for: book, audioIndex: try savedIndex(of: book))

        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), Self.expectedMarkdown)
        XCTAssertTrue(load.indexChanged, "the new content.md has new fingerprints")
        XCTAssertEqual(load.text?.chapters.map(\.text), installation.text.chapters.map(\.text))
        let lines = debugLogLines(containing: "TRANSCRIPT_TEXT_REBUILT: \(title): content.md and its index were written "
            + "again from transcript.json: content.md changed")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("Quillwort") && !$0.contains("by hand") }, "\(lines)")
    }

    /// An audio file changed since it was transcribed, as an edit changes
    /// it, makes the transcript stale: the book shows no text, the change
    /// is logged, the index is left for a transcription to replace, and
    /// saving the old transcript again is refused.
    func testAChangedAudioFileMakesTheTranscriptStale() throws {
        let world = try makeIntegrationWorld("Transcript Stale")
        let title = uniqueTitle("Harbor Notes")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [9, 6])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Self.sentences)
        try TranscriptStore.install(transcript, for: book)
        let index = try savedIndex(of: book)
        try AudioTestFixtures.writeSilence(to: URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav"), duration: 7)

        let load = TranscriptTextLoader.load(for: book, audioIndex: index)

        XCTAssertNil(load.text)
        XCTAssertFalse(load.indexChanged)
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_STALE: \(title): 02.wav changed since it was transcribed").count, 1)
        XCTAssertThrowsError(try TranscriptStore.install(transcript, for: book)) { error in
            XCTAssertEqual(error as? TranscriptionError, .audioChanged("02.wav changed since it was transcribed"))
        }
    }

    /// A transcript made again for edited audio, as another Mac sharing the
    /// library makes one, is read even while the index still describes the
    /// old audio: the book is stale only when transcript.json is too.
    func testATranscriptMadeAgainForEditedAudioIsReadBeforeTheIndexCatchesUp() throws {
        let world = try makeIntegrationWorld("Transcript Made Again")
        let title = uniqueTitle("Harbor Notes")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [9, 6])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let oldIndex = try savedIndex(of: book)
        try AudioTestFixtures.writeSilence(to: URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav"), duration: 7)
        let again = try TranscriptFixtures.transcript(of: book, sentences: [
            "02.wav": [TranscriptFixtures.sentence("The salt road bends east again.", from: 0, to: 2_400)],
        ])
        try TranscriptStore.write(again, into: book.tmbDirectory)

        let load = TranscriptTextLoader.load(for: book, audioIndex: oldIndex)

        XCTAssertEqual(load.text?.chapterText(1), "02\n\nThe salt road bends east again.")
        XCTAssertTrue(load.indexChanged)
        XCTAssertEqual(load.index.transcript?.audioFiles, again.audioFiles)
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_STALE: \(title):"), [])
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_TEXT_REBUILT: \(title): content.md and its index were written "
            + "again from transcript.json: its index describes other audio: 02.wav changed since it was transcribed").count, 1)
    }

    /// An audio file only touched, its date moved but its contents the
    /// same, keeps its transcript, and its new date is recorded so it is
    /// not read for its digest again.
    func testATouchedAudioFileKeepsItsTranscript() throws {
        let world = try makeIntegrationWorld("Transcript Touched")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let track = URL(fileURLWithPath: book.filePath).appendingPathComponent("01.wav")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: track.path)

        let load = TranscriptTextLoader.load(for: book, audioIndex: try savedIndex(of: book))

        XCTAssertNotNil(load.text)
        XCTAssertTrue(load.indexChanged)
        XCTAssertEqual(load.index.transcript?.audioFiles.first?.fingerprint.stamp, FileStamp(of: track))
    }

    /// A transcript.json that cannot be used leaves the book without text,
    /// and the index without the layer that describes it.
    func testAnUnusableTranscriptLeavesNoText() throws {
        let world = try makeIntegrationWorld("Transcript Unusable")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        try Data("{\"version\": 1".utf8).write(to: TextMouthPaths.transcriptPath(in: book.tmbDirectory))

        let load = TranscriptTextLoader.load(for: book, audioIndex: try savedIndex(of: book))

        XCTAssertNil(load.text)
        XCTAssertTrue(load.indexChanged)
        XCTAssertNil(load.index.transcript)
    }

    /// Files only in the cloud are never read: the book shows no text until
    /// they are on this Mac, and nothing is written or changed.
    func testFilesOnlyInTheCloudAreNotRead() throws {
        let world = try makeIntegrationWorld("Transcript Cloud")
        let book = try world.makeSilentAudioBook(title: "Harbor Notes", trackDurations: [9, 6])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)
        let index = try savedIndex(of: book)

        let load = TranscriptTextLoader.load(for: book, audioIndex: index, isDataless: { $0.lastPathComponent == "content.md" })

        XCTAssertNil(load.text)
        XCTAssertFalse(load.indexChanged)
        XCTAssertEqual(load.index, index)
    }

    // MARK: - The Reader

    /// A transcribed audiobook opens showing its transcript around the
    /// time its cursor stands for, and still plays its audio from its
    /// files: a move to another chapter shows that chapter's text.
    func testTheReaderShowsTheTranscriptAndStillPlaysTheAudio() throws {
        let world = try makeIntegrationWorld("Transcript Reader")
        let book = try world.makeSilentAudioBook(
            title: "Harbor Notes",
            trackDurations: [9, 6],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 30)
        )
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)

        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)

        let content = try XCTUnwrap(reader.content)
        XCTAssertNotNil(content.transcript)
        XCTAssertEqual(reader.currentCharacterOffset, 30, "the position still counts time")
        XCTAssertTrue(reader.displayVisibleTextWindow.contains("Tide tables hang in the harbor office."), reader.displayVisibleTextWindow)
        XCTAssertEqual(
            ReaderViewModel.shownText(of: content, chapterIndex: 0, cursorOffset: 30).offset,
            39,
            "three seconds in, the second sentence is heard"
        )
        let tracks = URL(fileURLWithPath: book.filePath, isDirectory: true)
        XCTAssertEqual(reader.chapterAudioSource(forChapterAt: 1), .file(tracks.appendingPathComponent("02.wav")))

        reader.navigateTo(chapterIndex: 1, characterOffset: 25)

        XCTAssertTrue(waitUntil { reader.displayVisibleTextWindow.contains("Carts wait at the toll.") }, reader.displayVisibleTextWindow)
        XCTAssertFalse(reader.isCurrentlyPlaying)
    }

    /// Where Am I on a transcribed audiobook quotes the sentence being
    /// heard after the times, the sentence the reader's text is shown
    /// around, in its brief and its full announcement alike. A move to
    /// another chapter quotes that chapter's sentence, and once the
    /// transcript is gone, nothing is quoted. Only the announcements' words
    /// are built: nothing is spoken.
    func testWhereAmIQuotesTheSentenceTheReaderShows() throws {
        let world = try makeIntegrationWorld("Transcript Where Am I")
        let book = try world.makeSilentAudioBook(
            title: "Harbor Notes",
            trackDurations: [9, 6],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 30)
        )
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: Self.sentences), for: book)

        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let content = try XCTUnwrap(reader.content)

        // Three seconds in, the second sentence is heard.
        let heard = "Tide tables hang in the harbor office."
        XCTAssertTrue(reader.displayVisibleTextWindow.contains(heard), reader.displayVisibleTextWindow)
        XCTAssertEqual(reader.heardTranscriptSentence, heard)
        let brief = reader.buildBriefWhereAmI()
        XCTAssertTrue(brief.hasSuffix(" remaining. \(heard)"), brief)
        let full = reader.buildFullWhereAmI(content: content)
        XCTAssertTrue(full.hasPrefix(reader.book.title + "."), full)
        XCTAssertTrue(full.contains("Total book time: "), full)
        XCTAssertTrue(full.hasSuffix(". \(heard)"), full)

        reader.navigateTo(chapterIndex: 1, characterOffset: 25)

        XCTAssertTrue(waitUntil { reader.displayVisibleTextWindow.contains("Carts wait at the toll.") }, reader.displayVisibleTextWindow)
        XCTAssertEqual(reader.heardTranscriptSentence, "Carts wait at the toll.")
        XCTAssertTrue(reader.buildBriefWhereAmI().hasSuffix(" Carts wait at the toll."), reader.buildBriefWhereAmI())

        reader.showTranscript(nil)

        XCTAssertNil(reader.heardTranscriptSentence)
        XCTAssertTrue(reader.buildBriefWhereAmI().hasSuffix(" remaining."), reader.buildBriefWhereAmI())
    }

    // MARK: - Fixtures

    /// The sentences heard in the tests' two-track book, by file.
    static let sentences: [String: [TranscriptSentence]] = [
        "01.wav": [
            TranscriptFixtures.sentence("Quillwort grows by the ferry slip.", from: 0, to: 2_400),
            TranscriptFixtures.sentence("Tide tables hang in the harbor office.", from: 2_400, to: 5_100),
            TranscriptFixtures.sentence("Nobody reads them twice.", from: 5_100, to: 6_960),
        ],
        "02.wav": [
            TranscriptFixtures.sentence("The salt road bends east.", from: 0, to: 1_980),
            TranscriptFixtures.sentence("Carts wait at the toll.", from: 1_980, to: 3_900),
        ],
    ]

    /// The content.md those sentences make: a chapter for each track, named
    /// as the track is, each with its heading and one paragraph.
    static let expectedMarkdown = """
    <!-- chapter: 01 -->
    # 01

    Quillwort grows by the ferry slip\\. Tide tables hang in the harbor office\\. Nobody reads them twice\\.

    <!-- chapter: 02 -->
    # 02

    The salt road bends east\\. Carts wait at the toll\\.
    """

    /// A chapter's transcript text with three sentences, timed for the
    /// time and place tests: "Title" heads it, the first sentence runs from
    /// 1 to 3 seconds, the second from 4 to 4.5, and the third from 4.5 to
    /// 6; a second chapter has a heading and no sentence.
    static var timedText: TranscriptText {
        let text = "Title\n\nFirst one. Second one. Third one."
        let sentences = [
            BookContentSentenceIndex(characterOffset: 7, characterCount: 10, startMilliseconds: 1_000, endMilliseconds: 3_000),
            BookContentSentenceIndex(characterOffset: 18, characterCount: 11, startMilliseconds: 4_000, endMilliseconds: 4_500),
            BookContentSentenceIndex(characterOffset: 30, characterCount: 10, startMilliseconds: 4_500, endMilliseconds: 6_000),
        ]
        let chapters = [
            Chapter(title: "Title", text: text, headings: [Heading(level: 1, text: "Title")]),
            Chapter(title: "Quiet", text: "Quiet", headings: [Heading(level: 1, text: "Quiet", chapterIndex: 1)]),
        ]
        let reading = BookContentIndex.build(fromChapters: chapters, format: .markdown)
        let index = BookContentTranscriptIndex(
            version: BookContentTranscriptIndex.currentVersion,
            transcript: TranscriptFixtures.twoFiles.note,
            textCacheFingerprint: TextCacheFingerprint(source: TranscriptFixtures.fingerprint(), cache: TranscriptFixtures.fingerprint()),
            audioFiles: [],
            totalWordCount: reading.totalWordCount,
            totalCharacterCount: reading.totalCharacterCount,
            chapters: [
                BookContentTranscriptChapterIndex(text: reading.chapters[0], sentences: sentences),
                BookContentTranscriptChapterIndex(text: reading.chapters[1], sentences: []),
            ]
        )
        return TranscriptText(chapters: chapters, index: index)
    }

    /// `base` followed by a few characters no other test's book has, so a
    /// line of the shared debug log names this test's book alone.
    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// A sentence laid over a chapter, from `start` to `end` milliseconds.
    private func sentence(_ text: String, _ start: Int, _ end: Int) -> TranscriptTextBuilder.ChapterSentence {
        TranscriptTextBuilder.ChapterSentence(text: text, startMilliseconds: start, endMilliseconds: end)
    }

    /// `book`'s audio index, as its load gives it.
    private func audioIndex(of book: Book) throws -> BookContentIndex {
        try BookContentAnalysisService.load(book: book).index
    }

    /// The index saved in `book`'s package.
    private func savedIndex(of book: Book) throws -> BookContentIndex {
        try XCTUnwrap(try BookInfo.load(from: book.tmbDirectory).contentIndex)
    }
}
