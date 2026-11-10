import XCTest
@testable import TextMouth

/// A transcript from outside TextMouth's recognizer, in the one transcript
/// store (FMT23, FMT25): where it came from, kept in transcript.json and in
/// the book's record so that a later TextMouth's values survive; a
/// transcript made from timed sentences as recognition makes one, cut from
/// the book's timeline into its files, and refused when it runs past the
/// end of its audio; an install that keeps a transcript the book has; the
/// Retranscribe sheet saying where the book's transcript came from; and no
/// offer to transcribe a book that has a transcript.
///
/// The sentences are invented, so a line of the debug log that quoted them
/// would stand out. Each book is silent tracks in a library folder of the
/// test's own: nothing plays, and nothing reaches the user's library.
@MainActor
final class OutsideTranscriptTests: XCTestCase {

    // MARK: - Where a Transcript Came From

    /// A source is written with its keys sorted, as transcript.json writes
    /// every key, and leaves out a file name it does not have; it reads its
    /// origin and format as this TextMouth knows them.
    func testASourceIsWrittenWithItsKeysSorted() throws {
        XCTAssertEqual(
            try Self.sortedJSON(Self.lectureSource),
            #"{"fileName":"lecture.vtt","format":"webvtt","origin":"attached"}"#
        )
        XCTAssertEqual(try Self.sortedJSON(Self.podcastSource), #"{"format":"podcast-json","origin":"podcast"}"#)
        XCTAssertEqual(Self.lectureSource.knownOrigin, .attached)
        XCTAssertEqual(Self.lectureSource.knownFormat, .webVTT)
        XCTAssertEqual(Self.podcastSource.knownOrigin, .podcast)
        XCTAssertEqual(Self.podcastSource.knownFormat, .podcastJSON)
    }

    /// An origin and a format a later TextMouth wrote, which this one does
    /// not know, are read as they were written, known as neither, and
    /// written back unchanged.
    func testASourceALaterTextMouthWroteIsReadAndWrittenBackUnchanged() throws {
        let source = try Self.laterSource()

        XCTAssertEqual(source.origin, "radio")
        XCTAssertEqual(source.format, "ttml")
        XCTAssertEqual(source.fileName, "evening.ttml")
        XCTAssertNil(source.knownOrigin)
        XCTAssertNil(source.knownFormat)
        XCTAssertEqual(try Self.sortedJSON(source), Self.laterSourceJSON)
    }

    /// A transcript.json holding a later TextMouth's source is found in its
    /// package, not set aside as unusable, and saving the transcript again
    /// writes the source as it was.
    func testATranscriptHoldingALaterSourceIsFoundInItsPackage() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.source = try Self.laterSource()
        let package = try makeSandboxDirectory("outside-later-source")
        let bytes = try TranscriptStore.encoded(transcript)
        try bytes.write(to: package.appendingPathComponent("transcript.json"))

        let lookup = TranscriptStore.read(from: package)

        XCTAssertEqual(lookup, .found(transcript))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""source":\#(Self.laterSourceJSON)"#))
        guard case .found(let found) = lookup else { return XCTFail("the transcript was not found") }
        XCTAssertEqual(try TranscriptStore.encoded(found), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["transcript.json"])
    }

    /// A transcript recognition made, which has no source, is written
    /// without one, key for key as before, and reads back the same; its
    /// note has no source either, and the record writes none.
    func testATranscriptWithoutASourceIsWrittenAsBefore() throws {
        let bytes = try TranscriptStore.encoded(TranscriptFixtures.twoFiles)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["app", "createdAt", "files", "locale", "model", "version"])
        let decoded = try TranscriptStore.decoded(bytes)
        XCTAssertEqual(decoded, TranscriptFixtures.twoFiles)
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.note.source)
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.note)) as? [String: Any])
        XCTAssertEqual(Set(note.keys), ["createdAt", "locale", "version"])
    }

    /// A transcript with a source reads back with it, and its note, which
    /// the book's record keeps, names the same source.
    func testATranscriptWithASourceReadsBackWithItAndItsNoteFollows() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.source = Self.lectureSource

        XCTAssertEqual(try TranscriptStore.decoded(try TranscriptStore.encoded(transcript)), transcript)
        XCTAssertEqual(
            transcript.note,
            TranscriptNote(
                version: Transcript.currentVersion,
                locale: "en-US",
                createdAt: TranscriptFixtures.date,
                source: Self.lectureSource
            )
        )
    }

    /// A file's name keeps no folder before it, so no path of the
    /// listener's is ever kept or shown, and a name of nothing but white
    /// space is no name.
    func testAFileNameKeepsNoFolder() {
        func name(_ given: String) -> String? {
            TranscriptSource(origin: .attached, format: .subRip, fileName: given).fileName
        }

        XCTAssertEqual(name("lecture one.srt"), "lecture one.srt")
        XCTAssertEqual(name("Talks/2026/lecture.srt"), "lecture.srt")
        XCTAssertEqual(name("/Volumes/Archive/lecture.srt"), "lecture.srt")
        XCTAssertNil(name(""))
        XCTAssertNil(name(" \t "))
        XCTAssertNil(name("/"))
        XCTAssertNil(TranscriptSource(origin: .attached, format: .subRip).fileName)
    }

    // MARK: - Fitting the Audio

    /// A transcript may end exactly the margin past the end of its audio,
    /// but not a millisecond more; the latest end among its sentences is
    /// the one measured, whichever sentence has it; no sentences fit any
    /// audio.
    func testATranscriptMayEndExactlyTheMarginPastItsAudio() {
        let margin = TimedTextLimits.pastTheEndMarginMilliseconds
        let lastCall = TranscriptFixtures.sentence("Last call for the ferry.", from: 2_000, to: 3_000 + margin)
        let tooLate = TranscriptFixtures.sentence("Last call for the ferry.", from: 2_000, to: 3_001 + margin)

        XCTAssertNoThrow(try OutsideTranscript.checkFits([lastCall], durationMilliseconds: 3_000))
        XCTAssertThrowsError(try OutsideTranscript.checkFits([tooLate], durationMilliseconds: 3_000)) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .runsPastTheEnd(transcriptEnd: 3_001 + margin, audioEnd: 3_000))
        }
        let longFirst = [
            TranscriptFixtures.sentence("The tide turns at noon.", from: 0, to: 9_000),
            TranscriptFixtures.sentence("Boats wait.", from: 1_000, to: 2_000),
        ]
        XCTAssertThrowsError(try OutsideTranscript.checkFits(longFirst, durationMilliseconds: 3_000)) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .runsPastTheEnd(transcriptEnd: 9_000, audioEnd: 3_000))
        }
        XCTAssertNoThrow(try OutsideTranscript.checkFits([], durationMilliseconds: 0))
    }

    /// An audio length that is not a length (below 0, as a damaged file may
    /// claim, down to the smallest number) is the audio's end at 0: a
    /// sentence is measured against that and never makes the subtraction
    /// overflow, which would stop TextMouth.
    func testALengthBelowZeroIsTheAudiosEndAtZero() {
        let early = TranscriptFixtures.sentence("Last call for the ferry.", from: 0, to: 4_000)
        let late = TranscriptFixtures.sentence("Last call for the ferry.", from: 0, to: 6_000)

        XCTAssertNoThrow(try OutsideTranscript.checkFits([early], durationMilliseconds: Int.min))
        XCTAssertNoThrow(try OutsideTranscript.checkFits([early], durationMilliseconds: -1))
        XCTAssertThrowsError(try OutsideTranscript.checkFits([late], durationMilliseconds: Int.min)) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .runsPastTheEnd(transcriptEnd: 6_000, audioEnd: Int.min))
        }
        XCTAssertNoThrow(try OutsideTranscript.checkFits([TranscriptFixtures.sentence("Done.", from: 0, to: Int.max)], durationMilliseconds: Int.max))
    }

    /// Each refusal says plainly why, as the screen shows it and VoiceOver
    /// speaks it: how far a transcript runs, in spoken time, against where
    /// the audio ends; and never the reason an unusable transcript's times
    /// gave the log.
    func testEachRefusalIsWordedForTheListener() {
        XCTAssertEqual(
            OutsideTranscriptError.runsPastTheEnd(transcriptEnd: 3_725_000, audioEnd: 3_600_000).localizedDescription,
            "The transcript runs to \(TimeFormatting.spoken(3_725)), past the end of the audio at "
                + "\(TimeFormatting.spoken(3_600)), so it was made for other audio."
        )
        XCTAssertEqual(OutsideTranscriptError.noText.localizedDescription, "The transcript holds no text to attach.")
        XCTAssertEqual(
            OutsideTranscriptError.alreadyTranscribed.localizedDescription,
            "The book has a transcript already, so TextMouth kept it."
        )
        XCTAssertEqual(
            OutsideTranscriptError.unusable("files[0].sentences[1].startMilliseconds is 0").localizedDescription,
            "The transcript's times don't fit together, so TextMouth can't use it."
        )
    }

    // MARK: - Cutting the Book's Timeline into Its Files

    /// A WebVTT file timed on the whole of a book of 120 hours (three files
    /// of 40) reads in full, cues past hour 100 included, and its
    /// sentences go to the files they were spoken in, each counted from its
    /// own file's start, so none is past the 100 hours a file may hold: the
    /// book's audio is no shorter than the file's last cue, so none is
    /// refused as running past the end. Cues past hour 100 were dropped
    /// when the readers stopped at 100 hours.
    func testACaptionFileTimedOnABookOfMoreThan100HoursIsReadAndCutIntoItsFiles() throws {
        let files = ["a1.wav", "a2.wav", "a3.wav"].map { Self.planFile($0, seconds: 144_000) }
        let captions = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        First file.

        50:00:00.000 --> 50:00:01.000
        Second file.

        110:00:00.000 --> 110:00:01.500
        Past the hundredth hour.
        """

        let document = try TimedTextReader.read(Data(captions.utf8), as: .webVTT)
        try OutsideTranscript.checkFits(document.sentences, durationMilliseconds: 3 * 144_000_000)
        let split = OutsideTranscript.split(document.sentences, across: files)

        XCTAssertEqual(document.skippedCueCount, 0, "a cue past hour 100 was passed over")
        XCTAssertEqual(split["a1.wav"]?.map(\.text), ["First file."])
        XCTAssertEqual(split["a2.wav"]?.map(\.text), ["Second file."])
        XCTAssertEqual(split["a3.wav"]?.map(\.text), ["Past the hundredth hour."])
        // 110 hours on the book is 30 hours into its third file.
        XCTAssertEqual(split["a3.wav"]?.map(\.startMilliseconds), [108_000_000])
        let longest = split.values.joined().map(\.endMilliseconds).max() ?? 0
        XCTAssertLessThanOrEqual(longest, Transcript.maximumMilliseconds, "a sentence is past a single file's limit")
    }

    /// One audio file of 101 hours, longer than the 100 a transcript times,
    /// takes a caption file's cues up to its hundredth hour: a cue that
    /// starts past it is left out, one that runs past it ends there, and
    /// what is kept makes a transcript that is trusted, so the attach is not
    /// refused whole. The cues past hour 100 were left out by the reader
    /// before the readers took times to 1,000 hours.
    func testAFileOfMoreThan100HoursKeepsTheCuesUpToItsHundredthHour() throws {
        let files = [Self.planFile("long.wav", seconds: 363_600)]
        let captions = """
        WEBVTT

        01:00:00.000 --> 01:00:05.000
        Early.

        99:59:50.000 --> 100:00:30.000
        Straddling.

        100:30:00.000 --> 100:30:05.000
        Past the hundredth hour.
        """
        let limit = Transcript.maximumMilliseconds

        let document = try TimedTextReader.read(Data(captions.utf8), as: .webVTT)
        let split = OutsideTranscript.split(document.sentences, across: files)

        XCTAssertEqual(document.cues.count, 3, "the reader should keep all three cues")
        let kept = try XCTUnwrap(split["long.wav"])
        XCTAssertEqual(kept.map(\.text), ["Early.", "Straddling."], "the cue past the hundredth hour was not left out, or another was")
        XCTAssertEqual(kept.map(\.endMilliseconds), [3_605_000, limit], "the straddling cue was not held at the hundredth hour")
        let transcript = TranscriptFixtures.transcript([(path: "long.wav", duration: 363_600_000, sentences: kept)])
        XCTAssertNil(transcript.validationFailure(), "what was kept is not a transcript TextMouth trusts")

        // The same for the cues of a track's own file found at import.
        let ownFile = document.sentences.compactMap(OutsideTranscript.withinTheLimitOfAFile)
        XCTAssertEqual(ownFile.map(\.text), ["Early.", "Straddling."])
    }

    /// On a book of a 3-second file and a 2-second file, a sentence at the
    /// start stays as it is; one starting in the first file and running on
    /// into the second stays in the first, its end held at the file's end
    /// and its words, no longer inside it, gone; one starting exactly where
    /// the second file starts opens it, its words moved with it; and one
    /// starting past the book's end is held at the second file's end.
    func testSentencesOnTheBooksTimelineGoToTheFilesTheyWereSpokenIn() throws {
        let files = [Self.planFile("01.wav", seconds: 3), Self.planFile("02.wav", seconds: 2)]
        let opening = TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 1_200)
        let crossing = TranscriptFixtures.sentence("The ferry docks late.", from: 2_500, to: 3_400)
        let atSecond = TranscriptFixtures.sentence("Ropes go taut.", from: 3_000, to: 4_000)
        let pastTheEnd = TranscriptFixtures.sentence("Lamps come on.", from: 5_200, to: 5_900)

        let split = OutsideTranscript.split([opening, crossing, atSecond, pastTheEnd], across: files)

        XCTAssertEqual(Set(split.keys), ["01.wav", "02.wav"])
        let first = try XCTUnwrap(split["01.wav"])
        let second = try XCTUnwrap(split["02.wav"])
        XCTAssertEqual(first.map(\.text), [opening.text, crossing.text])
        XCTAssertEqual(first.map(\.startMilliseconds), [0, 2_500])
        XCTAssertEqual(first.map(\.endMilliseconds), [1_200, 3_000])
        XCTAssertEqual(first.first?.words, opening.words)
        XCTAssertEqual(first.last?.words, [], "a word past the file's end was kept")
        XCTAssertEqual(second.map(\.text), [atSecond.text, pastTheEnd.text])
        XCTAssertEqual(second.map(\.startMilliseconds), [0, 2_000])
        XCTAssertEqual(second.map(\.endMilliseconds), [1_000, 2_000])
        let moved = try XCTUnwrap(second.first?.words)
        XCTAssertEqual(moved.map(\.startMilliseconds), atSecond.words.map { $0.startMilliseconds - 3_000 })
        XCTAssertEqual(moved.map(\.endMilliseconds), atSecond.words.map { $0.endMilliseconds - 3_000 })
        XCTAssertEqual(moved.map(\.characterOffset), atSecond.words.map(\.characterOffset))
        XCTAssertEqual(moved.map(\.confidence), atSecond.words.map(\.confidence))
        XCTAssertEqual(second.last?.words, [], "a word past the book's end was kept")
    }

    /// A file of no length takes no sentence: one between two others leaves
    /// a sentence starting where it lies to the file after it, one at the
    /// end leaves a sentence at the book's end to the file before it, and
    /// a book of no length at all takes none.
    func testAFileOfNoLengthTakesNoSentence() throws {
        let atBoundary = TranscriptFixtures.sentence("Ropes go taut.", from: 3_000, to: 3_600)

        let between = OutsideTranscript.split([atBoundary], across: [
            Self.planFile("01.wav", seconds: 3),
            Self.planFile("silence.wav", seconds: 0),
            Self.planFile("02.wav", seconds: 2),
        ])
        let atTheEnd = OutsideTranscript.split([atBoundary], across: [
            Self.planFile("01.wav", seconds: 3),
            Self.planFile("silence.wav", seconds: 0),
        ])

        XCTAssertEqual(Set(between.keys), ["02.wav"])
        XCTAssertEqual(between["02.wav"]?.map(\.startMilliseconds), [0])
        XCTAssertEqual(between["02.wav"]?.map(\.endMilliseconds), [600])
        XCTAssertEqual(Set(atTheEnd.keys), ["01.wav"])
        XCTAssertEqual(atTheEnd["01.wav"]?.map(\.startMilliseconds), [3_000])
        XCTAssertEqual(atTheEnd["01.wav"]?.map(\.endMilliseconds), [3_000])
        XCTAssertTrue(OutsideTranscript.split([atBoundary], across: [Self.planFile("silence.wav", seconds: 0)]).isEmpty)
    }

    /// Files of fractional length lie end to end as their lengths round to
    /// milliseconds (2.4996 seconds is 2,500, as the transcript records
    /// the file), so no drift builds up and a sentence starting a
    /// millisecond before a file opens stays in the file before it, its end
    /// held at that file's end.
    func testFilesOfFractionalLengthAreLaidEndToEndAsTheyAreRounded() throws {
        let files = [
            Self.planFile("01.wav", seconds: 2.4996),
            Self.planFile("02.wav", seconds: 1.0004),
            Self.planFile("03.wav", seconds: 1.5),
        ]

        let split = OutsideTranscript.split([
            TranscriptFixtures.sentence("Gulls circle the quay.", from: 2_000, to: 2_400),
            TranscriptFixtures.sentence("A rope is thrown.", from: 2_499, to: 2_600),
            TranscriptFixtures.sentence("Ropes go taut.", from: 2_500, to: 3_000),
            TranscriptFixtures.sentence("The ferry docks.", from: 3_499, to: 3_600),
            TranscriptFixtures.sentence("Lamps come on.", from: 3_500, to: 3_900),
        ], across: files)

        XCTAssertEqual(split["01.wav"]?.map(\.startMilliseconds), [2_000, 2_499])
        XCTAssertEqual(split["01.wav"]?.map(\.endMilliseconds), [2_400, 2_500])
        XCTAssertEqual(split["02.wav"]?.map(\.startMilliseconds), [0, 999])
        XCTAssertEqual(split["02.wav"]?.map(\.endMilliseconds), [500, 1_000])
        XCTAssertEqual(split["03.wav"]?.map(\.startMilliseconds), [0])
        XCTAssertEqual(split["03.wav"]?.map(\.endMilliseconds), [400])
    }

    /// A sentence that ends exactly where its file does keeps its words, as
    /// every one of them lies inside it; the sentences of one file keep the
    /// order they were given in, whatever files lie between.
    func testASentenceEndingWhereItsFileEndsKeepsItsWords() throws {
        let files = [Self.planFile("01.wav", seconds: 3), Self.planFile("02.wav", seconds: 2)]
        let closing = TranscriptFixtures.sentence("The ferry docks late.", from: 2_000, to: 3_000)
        let first = TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 900)
        let second = TranscriptFixtures.sentence("Ropes go taut.", from: 0, to: 900)

        let split = OutsideTranscript.split([first, second, closing], across: files)

        XCTAssertEqual(split["01.wav"]?.map(\.text), [first.text, second.text, closing.text])
        XCTAssertEqual(split["01.wav"]?.last, closing)
        XCTAssertNil(split["02.wav"])
    }

    // MARK: - Making the Transcript

    /// A transcript made from each file's sentences is made as recognition
    /// makes one: each of the book's files in order, fingerprinted as it is
    /// now and measured, with its sentences as given; sentences of a file
    /// the book does not have are passed over; it names no recognizer and
    /// no language, was made by this build, in whole seconds, and records
    /// where it came from.
    func testATranscriptFromOutsideIsMadeAsRecognitionMakesOne() throws {
        let (_, plan) = try makeBook("Outside Transcript")
        let opening = TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 1_200)
        let closing = TranscriptFixtures.sentence("Ropes go taut.", from: 400, to: 1_400)
        let fingerprints = try plan.files.map { try XCTUnwrap(FileFingerprint(of: $0.url, hasher: .md5)) }

        let transcript = try OutsideTranscript.transcript(
            sentencesByFile: [
                "01.wav": [opening],
                "02.wav": [closing],
                "Bonus/03.wav": [TranscriptFixtures.sentence("Nobody hears this.", from: 0, to: 900)],
            ],
            plan: plan,
            source: Self.lectureSource,
            now: Date(timeIntervalSince1970: 1_790_000_000.75)
        )

        XCTAssertEqual(transcript.files.map(\.path), ["01.wav", "02.wav"])
        XCTAssertEqual(transcript.files.map(\.durationMilliseconds), [3_000, 2_000])
        XCTAssertEqual(transcript.files.map(\.fingerprint), fingerprints)
        XCTAssertEqual(transcript.files.map(\.sentences), [[opening], [closing]])
        XCTAssertEqual(transcript.version, Transcript.currentVersion)
        XCTAssertEqual(transcript.locale, "und")
        XCTAssertEqual(transcript.model, TranscriptSpeechModel(
            engine: "none",
            assetStatus: "none",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        ))
        XCTAssertEqual(transcript.app, TranscriptAppBuild.current)
        XCTAssertEqual(transcript.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(transcript.source, Self.lectureSource)
        XCTAssertNil(transcript.editedAt)
        XCTAssertNil(transcript.cleanedUp)
        XCTAssertNil(transcript.validationFailure())
    }

    /// A file's own sentences are kept as the file timed them: one running
    /// on past its track's end by no more than the margin is stored so, its
    /// end after the track's (the transcript still passes validation, and
    /// its text and captions are made from it), while a sentence of the
    /// book's timeline is held inside the file it opens in.
    func testASentenceRunningPastItsTracksEndWithinTheMarginIsKeptAsGiven() throws {
        let (_, plan) = try makeBook("Outside Transcript Margin")
        let margin = TimedTextLimits.pastTheEndMarginMilliseconds
        let late = TranscriptFixtures.sentence("Ropes go taut.", from: 1_500, to: 2_000 + margin)

        let ownFile = try OutsideTranscript.transcript(
            sentencesByFile: ["02.wav": [late]], plan: plan, source: Self.lectureSource
        )
        let timeline = try OutsideTranscript.transcript(
            bookTimeline: [TranscriptFixtures.sentence("Ropes go taut.", from: 4_500, to: 5_000 + margin)],
            plan: plan,
            source: Self.podcastSource
        )

        XCTAssertEqual(ownFile.files.map(\.sentences), [[], [late]])
        XCTAssertNil(ownFile.validationFailure())
        XCTAssertEqual(timeline.files.map { $0.sentences.map(\.endMilliseconds) }, [[], [2_000]])
        XCTAssertNil(timeline.validationFailure())
    }

    /// A transcript timed on the book's timeline, as a podcast's transcript
    /// of the whole episode is, is cut into the book's files.
    func testATranscriptOfTheBooksTimelineIsCutIntoItsFiles() throws {
        let (_, plan) = try makeBook("Outside Transcript Timeline")

        let transcript = try OutsideTranscript.transcript(
            bookTimeline: [
                TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 1_200),
                TranscriptFixtures.sentence("Ropes go taut.", from: 3_400, to: 4_400),
            ],
            plan: plan,
            source: Self.podcastSource
        )

        XCTAssertEqual(transcript.files.map(\.path), ["01.wav", "02.wav"])
        XCTAssertEqual(transcript.files.map { $0.sentences.map(\.text) }, [["Gulls circle the quay."], ["Ropes go taut."]])
        XCTAssertEqual(transcript.files.map { $0.sentences.map(\.startMilliseconds) }, [[0], [400]])
        XCTAssertEqual(transcript.files.map { $0.sentences.map(\.endMilliseconds) }, [[1_200], [1_400]])
        XCTAssertEqual(transcript.source, Self.podcastSource)
    }

    /// No transcript is made without text for the book's files, from
    /// sentences running past the end of a file or of the book, from
    /// sentences out of order, or for a file that can no longer be read.
    func testATranscriptThatCannotBeUsedIsRefused() throws {
        let (_, plan) = try makeBook("Outside Transcript Refused")
        func refusal(_ make: () throws -> Transcript) -> Error? {
            do {
                _ = try make()
                return nil
            } catch {
                return error
            }
        }
        func made(_ sentencesByFile: [String: [TranscriptSentence]]) -> Error? {
            refusal { try OutsideTranscript.transcript(sentencesByFile: sentencesByFile, plan: plan, source: Self.lectureSource) }
        }
        func madeFromTimeline(_ sentences: [TranscriptSentence]) -> Error? {
            refusal { try OutsideTranscript.transcript(bookTimeline: sentences, plan: plan, source: Self.podcastSource) }
        }
        let elsewhere = TranscriptFixtures.sentence("Nobody hears this.", from: 0, to: 900)

        XCTAssertEqual(made([:]) as? OutsideTranscriptError, .noText)
        XCTAssertEqual(made(["Bonus/03.wav": [elsewhere]]) as? OutsideTranscriptError, .noText)
        XCTAssertEqual(madeFromTimeline([]) as? OutsideTranscriptError, .noText)
        XCTAssertEqual(
            made(["02.wav": [TranscriptFixtures.sentence("The bell rings late.", from: 1_000, to: 7_001)]]) as? OutsideTranscriptError,
            .runsPastTheEnd(transcriptEnd: 7_001, audioEnd: 2_000)
        )
        XCTAssertEqual(
            madeFromTimeline([TranscriptFixtures.sentence("The bell rings late.", from: 4_000, to: 10_001)]) as? OutsideTranscriptError,
            .runsPastTheEnd(transcriptEnd: 10_001, audioEnd: 5_000)
        )
        let outOfOrder = made(["01.wav": [
            TranscriptFixtures.sentence("Ropes go taut.", from: 1_000, to: 2_000),
            TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 900),
        ]])
        XCTAssertEqual(
            outOfOrder as? OutsideTranscriptError,
            .unusable("files[0].sentences[1].startMilliseconds is 0, before the previous sentence's 1000")
        )

        let secondTrack = try XCTUnwrap(plan.files.last)
        try FileManager.default.removeItem(at: secondTrack.url)
        XCTAssertEqual(
            made(["01.wav": [elsewhere]]) as? TranscriptionError,
            .unreadableFile(file: "02.wav", reason: TranscriptionError.unreadableAudioReason)
        )
    }

    /// A transcript from outside, installed, is the book's text, and the
    /// book's record notes where it came from.
    func testAnInstalledTranscriptFromOutsideIsTheBooksTextAndItsRecordNotesItsSource() throws {
        let (book, plan) = try makeBook("Outside Transcript Installed")
        let transcript = try OutsideTranscript.transcript(
            sentencesByFile: [
                "01.wav": [TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 1_200)],
                "02.wav": [TranscriptFixtures.sentence("Ropes go taut.", from: 400, to: 1_400)],
            ],
            plan: plan,
            source: Self.lectureSource
        )

        try TranscriptStore.install(transcript, for: book)

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.transcript?.source, Self.lectureSource)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(transcript))
        let index = try XCTUnwrap(record.contentIndex)
        let load = TranscriptTextLoader.load(for: book, audioIndex: index)
        XCTAssertEqual(load.text?.chapterText(0), "01\n\nGulls circle the quay.")
        XCTAssertEqual(load.text?.chapterText(1), "02\n\nRopes go taut.")
    }

    // MARK: - Keeping a Transcript the Book Has

    /// An install asked to keep the book's transcript installs one when the
    /// book has none; once it has one, it changes nothing, transcript.json,
    /// the text, and the record alike, and says the transcript was kept.
    /// An install not asked to keep it replaces it.
    func testAnInstallKeepingTheBooksTranscriptLeavesItAsItWas() throws {
        let (book, plan) = try makeBook("Outside Transcript Kept")
        let fetched = try OutsideTranscript.transcript(
            sentencesByFile: ["01.wav": [TranscriptFixtures.sentence("Gulls circle the quay.", from: 0, to: 1_200)]],
            plan: plan,
            source: Self.podcastSource
        )
        let attached = try OutsideTranscript.transcript(
            sentencesByFile: ["02.wav": [TranscriptFixtures.sentence("Ropes go taut.", from: 400, to: 1_400)]],
            plan: plan,
            source: Self.lectureSource
        )
        try TranscriptStore.install(fetched, for: book, keepingExisting: true)
        let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let textURL = MarkdownCacheService.cacheURL(for: book)
        let transcriptBytes = try Data(contentsOf: transcriptURL)
        let textBytes = try Data(contentsOf: textURL)

        XCTAssertThrowsError(try TranscriptStore.install(attached, for: book, keepingExisting: true)) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .alreadyTranscribed)
        }

        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcriptBytes)
        XCTAssertEqual(try Data(contentsOf: textURL), textBytes)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.transcript?.source, Self.podcastSource)

        try TranscriptStore.install(attached, for: book)

        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(attached))
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.transcript?.source, Self.lectureSource)
    }

    /// An install that gives way to an untouched podcast transcript (FMT25)
    /// looks at the transcript as it stands when the install runs: the
    /// podcast's own, untouched, is replaced; once the listener has edited it,
    /// as they might while a new download's audio was measured, it is kept,
    /// byte for byte, and the install says so; and any other transcript is
    /// kept as `keepingExisting` keeps it.
    func testAnInstallGivesWayOnlyToAPodcastTranscriptStillUntouched() throws {
        let (book, plan) = try makeBook("Outside Transcript Gives Way")
        func podcasts(_ text: String) throws -> Transcript {
            try OutsideTranscript.transcript(
                sentencesByFile: ["01.wav": [TranscriptFixtures.sentence(text, from: 0, to: 1_200)]],
                plan: plan,
                source: Self.podcastSource
            )
        }
        func installGivingWay(_ transcript: Transcript) throws {
            try TranscriptStore.install(
                transcript, for: book, keepingExisting: true, givingWayToAnUntouchedPodcastTranscript: true
            )
        }
        let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        try installGivingWay(try podcasts("Gulls circle the quay."))

        // Untouched: the newer podcast transcript takes its place.
        let newer = try podcasts("Ropes go taut.")
        try installGivingWay(newer)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(newer))

        // Edited since: kept, whatever the caller saw before.
        var edited = newer
        edited.editedAt = TranscriptFixtures.date
        try TranscriptStore.write(edited, into: book.tmbDirectory)
        let editedBytes = try Data(contentsOf: transcriptURL)
        XCTAssertThrowsError(try installGivingWay(try podcasts("Sails come down."))) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .alreadyTranscribed)
        }
        XCTAssertEqual(try Data(contentsOf: transcriptURL), editedBytes, "an edited podcast transcript was replaced")

        // Not the podcast's: kept too.
        let attached = try OutsideTranscript.transcript(
            sentencesByFile: ["02.wav": [TranscriptFixtures.sentence("Nets dry on the wall.", from: 400, to: 1_400)]],
            plan: plan,
            source: Self.lectureSource
        )
        try TranscriptStore.install(attached, for: book)
        XCTAssertThrowsError(try installGivingWay(try podcasts("Sails come down."))) {
            XCTAssertEqual($0 as? OutsideTranscriptError, .alreadyTranscribed)
        }
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(attached))
    }

    // MARK: - The Retranscribe Sheet's Line

    /// The line naming a transcript from outside says where it came from,
    /// exactly, for each origin, with and without a file's name, and for a
    /// format or an origin a later TextMouth wrote.
    func testTheLineNamingATranscriptFromOutsideSaysWhereItCameFrom() throws {
        let date = TranscriptFixtures.date
        let day = TranscriptionWording.day(date)
        func line(_ origin: TranscriptSource.Origin, _ format: TimedTextFormat, _ fileName: String? = nil) -> String {
            TranscriptionWording.outsideTranscript(TranscriptSource(origin: origin, format: format, fileName: fileName), on: date)
        }
        // A source as transcript.json holds it, for values a later
        // TextMouth wrote.
        func lineOfStored(_ json: String) throws -> String {
            TranscriptionWording.outsideTranscript(try JSONDecoder().decode(TranscriptSource.self, from: Data(json.utf8)), on: date)
        }

        XCTAssertEqual(
            line(.attached, .webVTT, "lecture.vtt"),
            "Attached from “lecture.vtt” on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(line(.attached, .webVTT), "Attached from a WebVTT file on \(day). Transcribing again replaces this transcript.")
        XCTAssertEqual(line(.attached, .subRip), "Attached from a SubRip file on \(day). Transcribing again replaces this transcript.")
        XCTAssertEqual(
            try lineOfStored(#"{"format":"ttml","origin":"attached"}"#),
            "Attached from a file on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            line(.imported, .subRip, "lecture.srt"),
            "Attached from “lecture.srt” when the book was imported, on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            line(.imported, .webVTT),
            "Attached from WebVTT files when the book was imported, on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            try lineOfStored(#"{"format":"ttml","origin":"imported"}"#),
            "Attached from files when the book was imported, on \(day). Transcribing again replaces this transcript."
        )
        // Files of two formats are named together, in the order read; a
        // list holding a format this TextMouth does not know names none.
        XCTAssertEqual(
            try lineOfStored(#"{"format":"webvtt","formats":["webvtt","srt"],"origin":"imported"}"#),
            "Attached from WebVTT and SubRip files when the book was imported, on \(day). "
                + "Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            try lineOfStored(#"{"format":"webvtt","formats":["webvtt","ttml"],"origin":"imported"}"#),
            "Attached from files when the book was imported, on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            line(.podcast, .podcastJSON),
            "The podcast's own transcript, downloaded with the episode on \(day). Transcribing again replaces this transcript."
        )
        XCTAssertEqual(line(.podcast, .webVTT, "episode.vtt"), line(.podcast, .podcastJSON))
        XCTAssertEqual(
            try lineOfStored(Self.laterSourceJSON),
            "Attached on \(day). Transcribing again replaces this transcript."
        )
    }

    /// The Transcribe Audio sheet of a book whose transcript came from a
    /// file says where it came from, in place of the language it was
    /// transcribed in, and offers Retranscribe.
    func testTheSheetSaysWhereTheBooksTranscriptCameFrom() async {
        var transcript = TranscriptFixtures.transcript(
            [(path: "01.mp3", duration: 1_000, sentences: [])],
            locale: OutsideTranscript.undeterminedLocale
        )
        transcript.source = Self.lectureSource
        let model = TranscriptionSheetModel(
            request: .book(TranscriptionSheetTests.audiobook("Harbour Captions")),
            library: nil,
            services: makeSheetServices(transcript: .found(transcript))
        )

        await model.load()

        let line = "Attached from “lecture.vtt” on \(TranscriptionWording.day(TranscriptFixtures.date)). "
            + "Transcribing again replaces this transcript."
        XCTAssertEqual(model.existingLine, line)
        XCTAssertEqual(model.noticeLines, [line])
        XCTAssertEqual(model.transcribeTitle, "Retranscribe")
    }

    // MARK: - No Offer to Transcribe

    /// With the offer to transcribe after an import on, an audiobook is
    /// offered exactly when this Mac can transcribe, until its package
    /// holds a transcript, as an import that found a timed-text file gives
    /// it one; then it is not.
    func testABookWithATranscriptIsNotOfferedTranscription() throws {
        preservePreferences([TranscriptionPreferences.offerAfterImport.key])
        TranscriptionPreferences.offerAfterImport.write(true, to: TextMouthRuntime.current.preferences)
        let (book, _) = try makeBook("Outside Transcript Offer")

        XCTAssertFalse(TranscriptStore.hasTranscript(of: book))
        XCTAssertEqual(
            TranscriptionOffers.offersTranscription(of: book),
            TranscriptionAvailability.systemSupport == .available
        )

        try TranscriptStore.write(TranscriptFixtures.twoFiles, into: book.tmbDirectory)

        XCTAssertTrue(TranscriptStore.hasTranscript(of: book))
        XCTAssertFalse(TranscriptionOffers.offersTranscription(of: book))
    }

    // MARK: - Helpers

    /// The source of a transcript attached from one WebVTT file.
    private static let lectureSource = TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt")

    /// The source of a podcast's own transcript, read from no file of a
    /// name worth keeping.
    private static let podcastSource = TranscriptSource(origin: .podcast, format: .podcastJSON)

    /// A source as a later TextMouth might write it: an origin and a format
    /// this one does not know, with the keys sorted.
    private static let laterSourceJSON = #"{"fileName":"evening.ttml","format":"ttml","origin":"radio"}"#

    /// `laterSourceJSON`, read.
    private static func laterSource() throws -> TranscriptSource {
        try JSONDecoder().decode(TranscriptSource.self, from: Data(laterSourceJSON.utf8))
    }

    /// `value` as JSON with its keys sorted, as transcript.json is written.
    private static func sortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A file of a transcription plan, `seconds` long, made by hand for a
    /// test that never reads it.
    private static func planFile(_ path: String, seconds: TimeInterval) -> TranscriptionPlan.File {
        TranscriptionPlan.File(path: path, url: URL(fileURLWithPath: "/nonexistent/\(path)"), duration: seconds)
    }

    /// A silent audiobook of two tracks, "01.wav" of 3 seconds and "02.wav"
    /// of 2, in a world of the test's own named after `label`, and the plan
    /// of its audio, as a transcription makes it.
    private func makeBook(_ label: String) throws -> (book: Book, plan: TranscriptionPlan) {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [3, 2])
        return (book, try TranscriptionPlan.make(for: book))
    }
}
