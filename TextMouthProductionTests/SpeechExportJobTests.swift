import AVFoundation
import IOKit.pwr_mgt
import os
import XCTest
@testable import TextMouth

/// The speech export job (FMT43), from a book's text cache to one spoken
/// audio file: a whole book's M4B, M4A, and MP3, each with a chapter for the
/// text before the first heading and one for each heading; a range of
/// headings with a skipped one left out; the progress told, and how often;
/// Stop, and an export going on from the chapters a stopped one kept, in
/// another format too, but never at another pitch; each refusal before
/// anything is spoken; a chapter the speech engine refuses; and the debug
/// log's one line for each way an export ends.
///
/// Nothing here speaks aloud, uses a Personal Voice, or keeps the Mac awake:
/// a fake synthesizer writes a quiet tone in memory, a fake lookup knows the
/// voices, a fake power assertion records what is asked of it, and every
/// file is written in a sandbox of the test's own and read back, never
/// played.
final class SpeechExportJobTests: XCTestCase {

    // MARK: - A Whole Book

    /// A whole book becomes an M4B with a chapter for the text before its
    /// first heading, under the book's title, then one for each heading, in
    /// order, each starting where the chapter before it and its half second
    /// of silence end, and tagged with the request's title and author. Every
    /// chapter is spoken once, in the request's voice, at its speed and
    /// pitch. The progress starts at no chapter done, tells each chapter's
    /// end at its share of the speech, never goes back, reaches the encode at
    /// 1, and ends with no chapter kept; the Mac is kept awake once and let go
    /// once; the kept chapters are let go; and the log has one line, for a
    /// finished export.
    func testAWholeBookBecomesAnM4BWithAChapterForEachHeading() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        let progress = RecordedProgress()
        let destination = sandbox.destination(.m4b)

        let lines = try await speechExportLogLines {
            try await export(Self.request(), in: sandbox, to: destination, context: context(sandbox, synthesizer: fake) {
                progress.add($0)
            })
        }

        // The file.
        try await assertWholeBook(in: destination, spokenBy: fake)
        let fileTags = try await tags(of: destination)
        XCTAssertEqual(fileTags.title, Self.titleTag)
        XCTAssertEqual(fileTags.artist, Self.author)

        // What was spoken, and how.
        let written = fake.written
        XCTAssertEqual(written.map(Self.chapterIndex(of:)), [0, 1, 2, 3])
        XCTAssertEqual(Set(written.map(\.voiceIdentifier)), [TestVoices.ordinary])
        XCTAssertEqual(Set(written.map(\.rate)), [SpeechService.rateForWPM(Self.wordsPerMinute)])
        XCTAssertEqual(Set(written.map(\.pitchMultiplier)), [Float(SpeechService.clampedPitch(Self.pitch))])

        // The progress: every chapter's end at its share, speaking before
        // encoding, and neither going back.
        let told = progress.values
        XCTAssertEqual(told.last, SpeechExportProgress.ended(kept: 0, total: 4))
        let values = Array(told.dropLast())
        XCTAssertEqual(values.first, SpeechExportProgress.speaking(done: 0, total: 4, fraction: 0))
        XCTAssertEqual(values.last, SpeechExportProgress.encoding(chapters: 4, fraction: 1))
        let speakingCount = values.prefix { $0.whileSpeaking != nil }.count
        let speaking = values.prefix(speakingCount).compactMap(\.whileSpeaking)
        let encoding = values.dropFirst(speakingCount).compactMap(\.whileEncoding)
        XCTAssertEqual(encoding.count, values.count - speakingCount, "speaking was told after the encode began: \(values)")
        XCTAssertTrue(speaking.allSatisfy { $0.total == 4 }, "\(values)")
        XCTAssertEqual(speaking.map(\.fraction), speaking.map(\.fraction).sorted(), "the speaking progress went back")
        XCTAssertTrue(encoding.allSatisfy { $0.chapters == 4 }, "\(values)")
        XCTAssertEqual(encoding.map(\.fraction), encoding.map(\.fraction).sorted(), "the encoding progress went back")
        XCTAssertEqual(encoding.first?.fraction, 0)
        let lengths = try exportSections(of: Self.request(), in: sandbox).map(\.utf16Length)
        let allUnits = Double(lengths.reduce(0, +))
        for done in 0...4 {
            let share = Double(lengths.prefix(done).reduce(0, +)) / allUnits
            XCTAssertTrue(
                speaking.contains { $0.done == done && abs($0.fraction - share) < 1e-12 },
                "no progress at \(done) chapters done, \(share) spoken: \(values)"
            )
        }

        XCTAssertEqual(sandbox.power.entries, [Self.holdEntry, Self.releaseEntry])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.storeRoot.path), "the kept chapters were not let go")
        XCTAssertEqual(lines, ["SPEECH_EXPORT: finished after 4 of 4 chapters (0 kept from an earlier export) in # s"])
    }

    /// An M4A and an MP3 have the same chapters as the M4B: the book's title,
    /// then each heading, each starting where the one before it and its gap
    /// end.
    func testAnM4AAndAnMP3HaveTheSameChapters() async throws {
        for format in [SpeechExportFormat.m4a, .mp3] {
            let sandbox = try makeSandbox()
            let fake = Self.makeFake()
            let destination = sandbox.destination(format)

            try await export(Self.request(format: format), in: sandbox, to: destination, context: context(sandbox, synthesizer: fake))

            try await assertWholeBook(in: destination, spokenBy: fake, "\(format)")
        }
    }

    /// A range from a heading to the book's end speaks only its headings'
    /// sections, leaving out a skipped heading's section as the reader does:
    /// the file's chapters are the headings left, with no chapter under the
    /// book's title.
    func testARangeSpeaksOnlyItsHeadingsAndLeavesOutASkippedOne() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        let destination = sandbox.destination()
        let harbour = try headingID("Harbour", in: sandbox)
        let tides = try headingID("Tides", in: sandbox)
        let request = Self.request(range: SpeechExportRange(fromHeadingID: harbour, throughHeadingID: nil), skipped: [tides])

        try await export(request, in: sandbox, to: destination, context: context(sandbox, synthesizer: fake))

        XCTAssertEqual(fake.written.map(Self.chapterIndex(of:)), [1, 3])
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), ["Harbour", "Market"])
    }

    // MARK: - Progress

    /// The renderer tells the frames written for every buffer, but the
    /// export tells its listener at most once every `progressInterval`,
    /// besides its start, each chapter's end, the encode's start and end, and
    /// its own end: a voice that delivers hundreds of buffers is told in a
    /// handful of reports.
    func testProgressIsToldAtMostOnceEveryInterval() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake(pieceFrameCount: 8)
        let progress = RecordedProgress()
        let started = ContinuousClock.now

        try await export(Self.request(), in: sandbox, to: sandbox.destination(), context: context(sandbox, synthesizer: fake) {
            progress.add($0)
        })

        let seconds: Double = started.duration(to: ContinuousClock.now) / .seconds(1)
        let buffers = fake.written.reduce(0) { $0 + ($1.text.utf16.count * Self.framesPerUnit + 7) / 8 }
        XCTAssertGreaterThan(buffers, 500, "too few buffers for the test to tell anything")
        // Eight reports come at once: the start, the four chapters' ends, the
        // encode's start and end, and the export's end. Every other report
        // waited out the interval after the one before it.
        let most = 8 + Int(seconds / SpeechExportJob.progressInterval) + 1
        XCTAssertLessThanOrEqual(progress.values.count, most, "\(progress.values.count) reports in \(seconds) s")
    }

    /// While a chapter is spoken, its progress moves through its share as its
    /// buffers come: by the part its frames so far are of its estimate, its
    /// words' time at the request's speed at 22,050 frames a second, but
    /// never past 0.99 of its share before the chapter ends, and never the
    /// same twice running. A voice that pauses, for longer than the progress
    /// interval, before each of the second chapter's buffers after its first
    /// has each of those buffers told.
    func testTheProgressMovesThroughAChapterWhileItIsSpoken() async throws {
        let sandbox = try makeSandbox()
        let request = Self.request()
        let sections = try exportSections(of: request, in: sandbox)
        guard sections.count == 4 else {
            return XCTFail("The book has \(sections.count) chapters, not 4")
        }
        let opening = sections[0]
        let harbour = sections[1]
        let cancellation = BookExportCancellation()
        let stopPhrase = Self.stopPhrase
        // Two thousand frames a unit make the second chapter's speech outrun
        // its estimate by its third buffer.
        let fake = FakeSpeechBufferSynthesizer(
            framesPerUnit: 2_000,
            pieceFrameCount: Self.pacedPieceFrames,
            beforeWrite: { utterance in
                if utterance.text.contains(stopPhrase) {
                    cancellation.cancel()
                }
            }
        )
        let voice = PausingSynthesizer(fake: fake, phrase: Self.pacedPhrase, pause: SpeechExportJob.progressInterval + 0.05)
        let progress = RecordedProgress()

        let error = await failure(
            exporting: request,
            in: sandbox,
            to: sandbox.destination(),
            context: context(sandbox, synthesizer: voice) { progress.add($0) },
            cancellation: cancellation
        )
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")

        // The second chapter's progress after each of its buffers.
        let allUnits = Double(sections.reduce(0) { $0 + $1.utf16Length })
        let unitsBefore = Double(opening.utf16Length)
        let estimate = SpeechExportSpace.seconds(wordCount: harbour.wordCount, wordsPerMinute: Self.wordsPerMinute) * Self.sampleRate
        let frames = try XCTUnwrap(fake.written.first { $0.text.contains(Self.pacedPhrase) }).text.utf16.count * 2_000
        let afterEachBuffer = stride(from: Self.pacedPieceFrames, to: frames + Self.pacedPieceFrames, by: Self.pacedPieceFrames)
            .map { written in
                (unitsBefore + Double(harbour.utf16Length) * min(0.99, Double(min(written, frames)) / estimate)) / allUnits
            }
        guard afterEachBuffer.count >= 3 else {
            return XCTFail("The second chapter took \(afterEachBuffer.count) buffers, not three or more")
        }
        let secondBuffer = afterEachBuffer[1]
        let thirdBuffer = afterEachBuffer[2]
        let capped = (unitsBefore + Double(harbour.utf16Length) * 0.99) / allUnits
        let told = progress.values.compactMap(\.whileSpeaking)
            .filter { $0.done == 1 && $0.fraction > unitsBefore / allUnits }
            .map(\.fraction)

        XCTAssertTrue(
            told.allSatisfy { value in afterEachBuffer.contains { abs($0 - value) < 1e-9 } },
            "\(told) are not all among \(afterEachBuffer)"
        )
        // The second and third buffers each came after a pause longer than
        // the interval, so both were told; the third outran the estimate, so
        // it told 0.99 of the chapter's share, and the last, equal, was not
        // told again.
        XCTAssertEqual(thirdBuffer, capped, accuracy: 1e-12, "the third buffer did not outrun the estimate")
        XCTAssertTrue(told.contains { abs($0 - secondBuffer) < 1e-9 }, "the second buffer was not told: \(told)")
        XCTAssertEqual(told.filter { abs($0 - capped) < 1e-9 }.count, 1, "0.99 of the share was not told once: \(told)")
        XCTAssertEqual(told, told.sorted(), "the progress went back")
        XCTAssertLessThan(told.last ?? 1, Double(opening.utf16Length + harbour.utf16Length) / allUnits)
    }

    // MARK: - Stop, and Going On

    /// Stop pressed as the third chapter begins ends the export with
    /// `CancellationError`: nothing is left at the destination, the two
    /// chapters finished are kept, and the Mac is let go. The same export
    /// asked again goes on from them: it speaks only the chapters after
    /// them, starts its progress at their share, and makes the whole file
    /// with every chapter. Each run writes its own log line, and tells how
    /// many chapters it left kept.
    func testAStoppedExportKeepsItsChaptersAndTheNextGoesOnFromThem() async throws {
        let sandbox = try makeSandbox()
        let destination = sandbox.destination()

        let stoppedProgress = RecordedProgress()
        let stoppedLines = try await speechExportLogLines {
            let stop = await stopAtTheThirdChapter(Self.request(), in: sandbox, to: destination, progress: stoppedProgress)
            XCTAssertTrue(stop is CancellationError, "\(String(describing: stop))")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a stopped export left a file")
        XCTAssertEqual(try keptChapterNames(in: sandbox), ["0001.caf", "0002.caf"])
        XCTAssertEqual(stoppedProgress.values.last, SpeechExportProgress.ended(kept: 2, total: 4))
        XCTAssertEqual(sandbox.power.entries, [Self.holdEntry, Self.releaseEntry])
        XCTAssertEqual(stoppedLines, ["SPEECH_EXPORT: stopped after 2 of 4 chapters (0 kept from an earlier export) in # s"])

        let fake = Self.makeFake()
        let progress = RecordedProgress()
        let finishedLines = try await speechExportLogLines {
            try await export(Self.request(), in: sandbox, to: destination, context: context(sandbox, synthesizer: fake) {
                progress.add($0)
            })
        }

        XCTAssertEqual(fake.written.map(Self.chapterIndex(of:)), [2, 3])
        let lengths = try exportSections(of: Self.request(), in: sandbox).map(\.utf16Length)
        let keptShare = Double(lengths.prefix(2).reduce(0, +)) / Double(lengths.reduce(0, +))
        let first = try XCTUnwrap(progress.values.first?.whileSpeaking, "\(progress.values)")
        XCTAssertEqual(first.done, 2)
        XCTAssertEqual(first.total, 4)
        XCTAssertEqual(first.fraction, keptShare, accuracy: 1e-12)
        XCTAssertEqual(progress.values.last, SpeechExportProgress.ended(kept: 0, total: 4))
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles)
        XCTAssertEqual(sandbox.power.entries, [Self.holdEntry, Self.releaseEntry, Self.holdEntry, Self.releaseEntry])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.storeRoot.path), "the kept chapters were not let go")
        XCTAssertEqual(finishedLines, ["SPEECH_EXPORT: finished after 4 of 4 chapters (2 kept from an earlier export) in # s"])
    }

    /// An export stopped partway goes on in another format: the MP3 asked
    /// for next speaks only the chapters after the two kept, and has every
    /// chapter.
    func testAnotherFormatGoesOnFromTheKeptChapters() async throws {
        let sandbox = try makeSandbox()
        let stop = await stopAtTheThirdChapter(Self.request(format: .m4b), in: sandbox, to: sandbox.destination(.m4b))
        XCTAssertTrue(stop is CancellationError, "\(String(describing: stop))")
        let fake = Self.makeFake()
        let destination = sandbox.destination(.mp3)

        try await export(Self.request(format: .mp3), in: sandbox, to: destination, context: context(sandbox, synthesizer: fake))

        XCTAssertEqual(fake.written.map(Self.chapterIndex(of:)), [2, 3])
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.destination(.m4b).path))
    }

    /// The same range at another pitch sounds different, so it speaks every
    /// chapter again: the chapters a stopped export kept at the first pitch
    /// are gone before the second speaks a word, and its file has every
    /// chapter, each spoken at its own pitch.
    func testAnotherPitchSpeaksEveryChapterAgain() async throws {
        let sandbox = try makeSandbox()
        let stop = await stopAtTheThirdChapter(Self.request(pitch: 1), in: sandbox, to: sandbox.destination())
        XCTAssertTrue(stop is CancellationError, "\(String(describing: stop))")
        let oldFolder = try XCTUnwrap(try storeFolders(in: sandbox).first, "the stopped export kept nothing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldFolder.path).sorted(), ["0001.caf", "0002.caf"])

        // Whether the old chapters were still there as each utterance began.
        let oldChaptersSeen = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let oldPath = oldFolder.path
        let fake = Self.makeFake(beforeWrite: { _ in
            let seen = FileManager.default.fileExists(atPath: oldPath)
            oldChaptersSeen.withLock { $0.append(seen) }
        })
        let destination = sandbox.destination()

        try await export(Self.request(pitch: 1.25), in: sandbox, to: destination, context: context(sandbox, synthesizer: fake))

        XCTAssertEqual(fake.written.map(Self.chapterIndex(of:)), [0, 1, 2, 3])
        XCTAssertEqual(oldChaptersSeen.withLock { $0 }, [false, false, false, false])
        XCTAssertEqual(Set(fake.written.map(\.pitchMultiplier)), [Float(SpeechService.clampedPitch(1.25))])
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles)
    }

    /// Stop pressed as the encode begins leaves every chapter kept, and says
    /// so, and nothing at the destination. The export asked again speaks
    /// nothing, starts its progress with every chapter done, and only encodes
    /// them into the whole file.
    func testAnExportStoppedWhileEncodingGoesOnWithoutSpeakingAgain() async throws {
        let sandbox = try makeSandbox()
        let destination = sandbox.destination()
        let cancellation = BookExportCancellation()
        let first = Self.makeFake()
        let firstProgress = RecordedProgress()

        let stop = await failure(
            exporting: Self.request(),
            in: sandbox,
            to: destination,
            context: context(sandbox, synthesizer: first) { progress in
                firstProgress.add(progress)
                if progress.whileEncoding != nil {
                    cancellation.cancel()
                }
            },
            cancellation: cancellation
        )

        XCTAssertTrue(stop is CancellationError, "\(String(describing: stop))")
        XCTAssertEqual(first.written.map(Self.chapterIndex(of:)), [0, 1, 2, 3])
        XCTAssertEqual(try keptChapterNames(in: sandbox), ["0001.caf", "0002.caf", "0003.caf", "0004.caf"])
        XCTAssertEqual(firstProgress.values.last, SpeechExportProgress.ended(kept: 4, total: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a stopped encode left a file")

        let second = Self.makeFake()
        let progress = RecordedProgress()
        try await export(Self.request(), in: sandbox, to: destination, context: context(sandbox, synthesizer: second) {
            progress.add($0)
        })

        XCTAssertEqual(second.written, [])
        XCTAssertEqual(progress.values.first, SpeechExportProgress.speaking(done: 4, total: 4, fraction: 1))
        XCTAssertEqual(progress.values.last, SpeechExportProgress.ended(kept: 0, total: 4))
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles)
    }

    /// The kept chapters wait for the file to reach its place: the delivery
    /// runs once the file is whole, with every chapter still kept and the Mac
    /// still held. A delivery that fails is the export's failure, and leaves
    /// every chapter kept, as the export says; the export asked again speaks
    /// nothing, and once its delivery has worked lets the chapters go.
    func testTheKeptChaptersWaitForTheFileToReachItsPlace() async throws {
        let sandbox = try makeSandbox()
        let destination = sandbox.destination()
        let delivered = sandbox.exports.appendingPathComponent("Delivered.m4b", isDirectory: false)
        let storeRoot = sandbox.storeRoot
        let power = sandbox.power
        let first = Self.makeFake()
        let firstProgress = RecordedProgress()

        let failed = await failure(
            exporting: Self.request(),
            in: sandbox,
            to: destination,
            context: context(sandbox, synthesizer: first) { firstProgress.add($0) },
            deliver: {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "the file was not whole yet")
                throw CocoaError(.fileWriteFileExists)
            }
        )

        XCTAssertEqual((failed as? CocoaError)?.code, .fileWriteFileExists, "\(String(describing: failed))")
        XCTAssertEqual(try keptChapterNames(in: sandbox), ["0001.caf", "0002.caf", "0003.caf", "0004.caf"])
        XCTAssertEqual(firstProgress.values.last, SpeechExportProgress.ended(kept: 4, total: 4))
        XCTAssertEqual(sandbox.power.entries, [Self.holdEntry, Self.releaseEntry])

        let second = Self.makeFake()
        // What the delivery found, for the test to read once the export ends.
        let foundOnDelivery = OSAllocatedUnfairLock<(chapters: Bool, powerEntries: Int)?>(initialState: nil)
        try await export(
            Self.request(),
            in: sandbox,
            to: destination,
            context: context(sandbox, synthesizer: second),
            deliver: {
                let found = (chapters: FileManager.default.fileExists(atPath: storeRoot.path), powerEntries: power.entries.count)
                foundOnDelivery.withLock { $0 = found }
                try FileManager.default.moveItem(at: destination, to: delivered)
            }
        )

        XCTAssertEqual(second.written, [], "the second export spoke")
        let found = try XCTUnwrap(foundOnDelivery.withLock { $0 }, "the delivery never ran")
        XCTAssertTrue(found.chapters, "the kept chapters went before the file reached its place")
        XCTAssertEqual(found.powerEntries, 3, "the Mac was let go before the file reached its place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.path), "the kept chapters were not let go")
        let chapters = await AudioPlaybackService.extractChapters(from: delivered)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles)
    }

    /// An export whose Stop was pressed before it began reads the book but
    /// holds nothing: it throws `CancellationError` before its store is
    /// opened, speaking nothing and never keeping the Mac awake; it says it
    /// kept nothing; and its log line counts the chapters it would have had.
    func testAnExportStoppedBeforeItBeginsHoldsNothing() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let progress = RecordedProgress()

        var error: Error?
        let lines = try await speechExportLogLines {
            error = await failure(
                exporting: Self.request(),
                in: sandbox,
                to: sandbox.destination(),
                context: context(sandbox, synthesizer: fake) { progress.add($0) },
                cancellation: cancellation
            )
        }

        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertEqual(progress.values, [.ended(kept: 0, total: 4)])
        XCTAssertEqual(fake.written, [])
        XCTAssertEqual(sandbox.power.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.storeRoot.path), "the store was opened")
        XCTAssertEqual(lines, ["SPEECH_EXPORT: stopped after 0 of 4 chapters (0 kept from an earlier export) in # s"])
    }

    // MARK: - Refusals

    /// A Personal Voice, which macOS never speaks into a file, is refused by
    /// its name; a request naming no voice, or a voice not installed, is
    /// refused as having none. Nothing is spoken, the Mac is never kept
    /// awake, no store is opened, no file is written, and each refusal's log
    /// line has no chapter done.
    func testAVoiceThatCannotSpeakIntoAFileIsRefusedBeforeAnythingIsSpoken() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        let refusals: [(voice: String?, expected: SpeechExportError)] = [
            (TestVoices.personal, .personalVoice(name: "Test Personal")),
            (nil, .noVoice),
            ("com.textmouth.tests.speech-export.not-installed", .noVoice),
        ]

        for (voice, expected) in refusals {
            var error: Error?
            let lines = try await speechExportLogLines {
                error = await failure(
                    exporting: Self.request(voice: voice),
                    in: sandbox,
                    to: sandbox.destination(),
                    context: context(sandbox, synthesizer: fake)
                )
            }

            XCTAssertEqual(error as? SpeechExportError, expected)
            XCTAssertEqual(
                lines,
                ["SPEECH_EXPORT: failed after 0 of 4 chapters (0 kept from an earlier export) in # s"],
                "\(expected)"
            )
        }
        XCTAssertEqual(fake.written, [])
        XCTAssertEqual(sandbox.power.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.storeRoot.path), "the store was opened")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.destination().path), "a refused export left a file")
    }

    /// Too little room is refused before anything is spoken: with a byte
    /// less free than the export needs, its speech and its file together on
    /// one disk, besides the room TextMouth keeps free, it throws
    /// `notEnoughSpace` with that need. With exactly enough, it gets past the
    /// check and begins to speak.
    func testTooLittleRoomIsRefusedBeforeAnythingIsSpoken() async throws {
        let sandbox = try makeSandbox()
        let request = Self.request()
        let words = try exportSections(of: request, in: sandbox).reduce(0) { $0 + $1.wordCount }
        let seconds = SpeechExportSpace.seconds(wordCount: words, wordsPerMinute: Self.wordsPerMinute)
        let need = SpeechExportSpace.bytes(forSeconds: seconds, at: SpeechExportSpace.speechBytesPerSecond)
            + SpeechExportSpace.bytes(forSeconds: seconds, at: SpeechExportSpace.fileBytesPerSecond)
        let enough = need + ArchiveLimits.standard.freeSpaceReserve
        let tooLittleRoom = Self.makeFake()

        let refusal = await failure(
            exporting: request,
            in: sandbox,
            to: sandbox.destination(),
            context: context(sandbox, synthesizer: tooLittleRoom, freeSpace: enough - 1)
        )

        XCTAssertEqual(refusal as? SpeechExportError, .notEnoughSpace(needed: need))
        XCTAssertEqual(tooLittleRoom.written, [])
        XCTAssertEqual(sandbox.power.entries, [])

        // Stop is pressed at the first utterance: enough to show the check
        // was passed, without speaking the whole book.
        let cancellation = BookExportCancellation()
        let roomEnough = Self.makeFake(beforeWrite: { _ in cancellation.cancel() })
        let stop = await failure(
            exporting: request,
            in: sandbox,
            to: sandbox.destination(),
            context: context(sandbox, synthesizer: roomEnough, freeSpace: enough),
            cancellation: cancellation
        )

        XCTAssertTrue(stop is CancellationError, "\(String(describing: stop))")
        XCTAssertEqual(roomEnough.written.count, 1, "the export with room enough did not begin to speak")
    }

    /// While another export holds the store, an export is refused as busy
    /// before it reads anything: nothing is spoken, the Mac is never kept
    /// awake, and its log line counts no chapters at all.
    func testAnExportWhileAnotherRunsIsRefusedAsBusy() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        guard SpeechExportStore.claim() else {
            return XCTFail("The store was already claimed")
        }
        defer { SpeechExportStore.release() }

        var error: Error?
        let lines = try await speechExportLogLines {
            error = await failure(
                exporting: Self.request(),
                in: sandbox,
                to: sandbox.destination(),
                context: context(sandbox, synthesizer: fake)
            )
        }

        XCTAssertEqual(error as? SpeechExportError, .busy)
        XCTAssertEqual(fake.written, [])
        XCTAssertEqual(sandbox.power.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.storeRoot.path), "the store was opened")
        XCTAssertEqual(lines, ["SPEECH_EXPORT: failed after 0 of 0 chapters (0 kept from an earlier export) in # s"])
    }

    /// A range that ends before it begins, or holds only a skipped heading,
    /// has nothing to speak; a range naming a heading the book no longer
    /// has, at either end, says the headings changed. Nothing is spoken, and
    /// the Mac is never kept awake.
    func testARangeWithNothingToSpeakOrAHeadingGoneIsRefused() async throws {
        let sandbox = try makeSandbox()
        let fake = Self.makeFake()
        let harbour = try headingID("Harbour", in: sandbox)
        let tides = try headingID("Tides", in: sandbox)
        let market = try headingID("Market", in: sandbox)
        let refusals: [(request: SpeechExportRequest, expected: SpeechExportError)] = [
            (Self.request(range: SpeechExportRange(fromHeadingID: market, throughHeadingID: harbour)), .nothingToSpeak),
            (Self.request(range: SpeechExportRange(fromHeadingID: tides, throughHeadingID: tides), skipped: [tides]), .nothingToSpeak),
            (Self.request(range: SpeechExportRange(fromHeadingID: "0-0-1-Customs House", throughHeadingID: nil)), .headingsChanged),
            (Self.request(range: SpeechExportRange(fromHeadingID: harbour, throughHeadingID: "1-0-1-Customs House")), .headingsChanged),
        ]

        for (request, expected) in refusals {
            let error = await failure(exporting: request, in: sandbox, to: sandbox.destination(), context: context(sandbox, synthesizer: fake))

            XCTAssertEqual(error as? SpeechExportError, expected, "\(request.range)")
        }
        XCTAssertEqual(fake.written, [])
        XCTAssertEqual(sandbox.power.entries, [])
    }

    /// A chapter whose text the speech engine refuses, guarded as every
    /// render begins and again with every bracket silent, fails the export
    /// with `refused`, naming the chapter: the two chapters before it are
    /// kept, as the export says, nothing is left at the destination, the Mac
    /// is let go, and the log's line counts the two chapters done.
    func testAChapterTheSpeechEngineRefusesFailsTheExportKeepingTheChaptersBeforeIt() async throws {
        let sandbox = try makeSandbox()
        let refusedPhrase = Self.stopPhrase
        let fake = Self.makeFake(refuses: { $0.text.contains(refusedPhrase) })
        let progress = RecordedProgress()

        var error: Error?
        let lines = try await speechExportLogLines {
            error = await failure(
                exporting: Self.request(),
                in: sandbox,
                to: sandbox.destination(),
                context: context(sandbox, synthesizer: fake) { progress.add($0) }
            )
        }

        XCTAssertEqual(error as? SpeechRenderFailure, .refused("Tides"))
        XCTAssertEqual(progress.values.last, SpeechExportProgress.ended(kept: 2, total: 4))
        XCTAssertEqual(fake.written.map(Self.chapterIndex(of:)), [0, 1, 2, 2], "the refused text was not tried twice")
        XCTAssertEqual(try keptChapterNames(in: sandbox), ["0001.caf", "0002.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.destination().path), "a failed export left a file")
        XCTAssertEqual(sandbox.power.entries, [Self.holdEntry, Self.releaseEntry])
        XCTAssertEqual(lines, ["SPEECH_EXPORT: failed after 2 of 4 chapters (0 kept from an earlier export) in # s"])
    }

    // MARK: - The Book

    /// The book's title, which names the chapter of its text before its
    /// first heading.
    private static let bookTitle = "The Quayside Almanac"

    /// The exported file's title tag.
    private static let titleTag = "The Quayside Almanac, Spoken"

    /// The exported file's artist tag.
    private static let author = "Ottilie Varga"

    /// The book's ID.
    private static let bookID = UUID()

    /// A phrase only the second chapter of the whole book's file holds.
    private static let pacedPhrase = "forty passengers"

    /// A phrase only the third chapter of the whole book's file holds,
    /// where the tests press Stop.
    private static let stopPhrase = "tide turned"

    /// The book's text cache, its content.md: text before its first heading,
    /// then a level-1 and a level-2 heading in its first chapter, and a
    /// level-1 heading in its second.
    private static let markdown = """
    <!-- chapter: Crossings -->
    Notes kept by the ticket office at the north slip.

    # Harbour

    The ferry left the slip at noon with forty passengers aboard.

    ## Tides

    The tide turned twice before the evening sailing was called.

    <!-- chapter: Trade -->
    # Market

    Stalls along the quay sold eels, rope, and salt by the barrel.
    """

    /// The titles of the whole book's chapters, in order: the book's title
    /// for its text before the first heading, then each heading.
    private static let chapterTitles = [bookTitle, "Harbour", "Tides", "Market"]

    /// A phrase only each of the whole book's chapters holds, in order, by
    /// which a test tells which chapter an utterance is from.
    private static let chapterPhrases = ["ticket office", pacedPhrase, stopPhrase, "eels"]

    /// The index of the whole book's chapter `utterance` is from, by the
    /// phrase only that chapter holds; -1 when it holds none.
    private static func chapterIndex(of utterance: SpeechExportUtterance) -> Int {
        chapterPhrases.firstIndex { utterance.text.contains($0) } ?? -1
    }

    // MARK: - The Requests

    /// The speed the tests' exports speak at, in words per minute.
    private static let wordsPerMinute = 180.0

    /// The pitch the tests' exports speak at unless a test says otherwise:
    /// not the voice's own, so that a test can tell it reached the voice.
    private static let pitch = 1.1

    /// Settings that prepare speech as the text is written: runs of a symbol
    /// read as written, no pauses, and no substitutions.
    private static let preparation = SpeechPreparationSettings(
        repeatedSymbolRule: RepeatedSymbolRule(
            style: .repeatEach,
            threshold: SettingsPolicy.repeatedSymbolThreshold.defaultValue,
            symbols: SettingsPolicy.repeatedSymbolSet.defaultValue
        ),
        punctuationPauseLevel: 0,
        substitutions: .none
    )

    /// A request to export `range` of the book, the whole book by default,
    /// in `format`, spoken by the voice `voice` at the tests' speed and at
    /// `pitch`, with the headings `skipped` skipped.
    private static func request(
        format: SpeechExportFormat = .m4b,
        range: SpeechExportRange = .wholeBook,
        voice: String? = TestVoices.ordinary,
        pitch: Double = SpeechExportJobTests.pitch,
        skipped: Set<String> = []
    ) -> SpeechExportRequest {
        SpeechExportRequest(
            bookID: bookID,
            bookTitle: bookTitle,
            fileTitle: bookTitle,
            titleTag: titleTag,
            author: author,
            format: format,
            range: range,
            voice: SpeechExportVoiceSettings(voiceIdentifier: voice, wordsPerMinute: wordsPerMinute, pitch: pitch),
            skippedHeadingIDs: skipped,
            preparation: preparation
        )
    }

    /// The book as the reader reads it, as the job reads it.
    private func content(in sandbox: Sandbox) throws -> DocumentContent {
        try BookExportService.readingContent(fromMarkdown: Data(Self.markdown.utf8), at: sandbox.source, title: Self.bookTitle)
    }

    /// The chapters an export of `request` speaks, read as the job reads
    /// them: what a test expects of their lengths and words.
    private func exportSections(of request: SpeechExportRequest, in sandbox: Sandbox) throws -> [SpeechExportSection] {
        try SpeechExportText.sections(
            of: content(in: sandbox),
            range: request.range,
            skippedHeadingIDs: request.skippedHeadingIDs,
            settings: request.preparation,
            bookTitle: request.bookTitle
        )
    }

    /// The ID of the book's heading whose text is `text`.
    private func headingID(_ text: String, in sandbox: Sandbox) throws -> String {
        try XCTUnwrap(content(in: sandbox).allHeadings.first { $0.text == text }?.id, "No heading \(text)")
    }

    // MARK: - The Fakes

    /// Frames of the fake's tone for each UTF-16 unit of an utterance.
    private static let framesPerUnit = 40

    /// The fake's frames a second.
    private static let sampleRate = 22_050.0

    /// Frames in each buffer the paced test's voice writes.
    private static let pacedPieceFrames = 40_000

    /// What the fake power assertion records as an export holds it.
    private static let holdEntry = "hold TextMouth is exporting a book as spoken audio"

    /// What the fake power assertion records as an export lets it go.
    private static let releaseEntry = "release 7"

    /// A fake synthesizer writing `framesPerUnit` frames of tone for each
    /// UTF-16 unit, at `sampleRate`, in buffers of `pieceFrameCount` frames.
    private static func makeFake(
        pieceFrameCount: Int = 2_205,
        refuses: @escaping @Sendable (SpeechExportUtterance) -> Bool = { _ in false },
        beforeWrite: @escaping @Sendable (SpeechExportUtterance) -> Void = { _ in }
    ) -> FakeSpeechBufferSynthesizer {
        FakeSpeechBufferSynthesizer(
            framesPerUnit: framesPerUnit,
            pieceFrameCount: pieceFrameCount,
            refuses: refuses,
            beforeWrite: beforeWrite
        )
    }

    // MARK: - Running Exports

    /// Where one test's exports keep their chapters and write their files,
    /// and the fake power assertion they hold.
    private struct Sandbox {
        /// The store's root, which the first export to open the store makes.
        let storeRoot: URL
        /// The folder the files are exported to.
        let exports: URL
        /// Where the book's text cache is said to be read from: never read,
        /// as its bytes are handed over.
        let source: URL
        /// The fake power assertion every export of the test holds.
        let power: RecordedPower

        /// Where the export in `format` goes.
        func destination(_ format: SpeechExportFormat = .m4b) -> URL {
            exports.appendingPathComponent("\(SpeechExportJobTests.bookTitle).\(format.fileExtension)", isDirectory: false)
        }
    }

    /// A new sandbox of the test's own, removed when the test ends: an empty
    /// folder for the exported files, a place for the store's root, and a
    /// fresh fake power assertion.
    private func makeSandbox() throws -> Sandbox {
        let folder = try makeSandboxDirectory("SpeechExportJob")
        let exports = folder.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        return Sandbox(
            storeRoot: folder.appendingPathComponent("Speech Export", isDirectory: true),
            exports: exports,
            source: folder.appendingPathComponent("content.md", isDirectory: false),
            power: RecordedPower()
        )
    }

    /// The context an export in `sandbox` runs with: `synthesizer`, the fake
    /// voice lookup, the sandbox's fake power assertion, `freeSpace` bytes
    /// free (100 GB unless given), one disk for everything, and the
    /// sandbox's store root; its progress goes to `progress`.
    private func context(
        _ sandbox: Sandbox,
        synthesizer: any SpeechBufferSynthesizing,
        freeSpace: Int64 = 100_000_000_000,
        progress: @escaping @Sendable (SpeechExportProgress) -> Void = { _ in }
    ) -> SpeechExportContext {
        SpeechExportContext(
            environment: SpeechExportEnvironment(
                synthesizer: synthesizer,
                voiceInfo: { TestVoices.info($0) },
                power: sandbox.power.assertion,
                freeSpace: { _ in freeSpace },
                sameVolume: { _, _ in true },
                storeRoot: sandbox.storeRoot
            ),
            progress: progress
        )
    }

    /// Runs `request` to `destination` as the Export job runner does: on a
    /// background queue, which the run blocks, while the test waits without
    /// blocking a thread; the book's text cache is handed over as bytes said
    /// to be read from the sandbox's source.
    private func export(
        _ request: SpeechExportRequest,
        in sandbox: Sandbox,
        to destination: URL,
        context: SpeechExportContext,
        cancellation: BookExportCancellation = BookExportCancellation(),
        deliver: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        let markdown = Data(Self.markdown.utf8)
        let source = sandbox.source
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try SpeechExportJob.run(
                        request,
                        markdown: markdown,
                        source: source,
                        to: destination,
                        context: context,
                        cancellation: cancellation,
                        deliver: deliver
                    )
                })
            }
        }
    }

    /// What `export` throws for `request`, or nil when it makes its file.
    private func failure(
        exporting request: SpeechExportRequest,
        in sandbox: Sandbox,
        to destination: URL,
        context: SpeechExportContext,
        cancellation: BookExportCancellation = BookExportCancellation(),
        deliver: @escaping @Sendable () throws -> Void = {}
    ) async -> Error? {
        do {
            try await export(request, in: sandbox, to: destination, context: context, cancellation: cancellation, deliver: deliver)
            return nil
        } catch {
            return error
        }
    }

    /// Runs `request` with a fake that presses Stop as the third chapter's
    /// text is handed to it, once the first two chapters are spoken and
    /// kept, and gives what the run threw; `progress` hears what it told.
    private func stopAtTheThirdChapter(
        _ request: SpeechExportRequest,
        in sandbox: Sandbox,
        to destination: URL,
        progress: RecordedProgress? = nil
    ) async -> Error? {
        let cancellation = BookExportCancellation()
        let stopPhrase = Self.stopPhrase
        let fake = Self.makeFake(beforeWrite: { utterance in
            if utterance.text.contains(stopPhrase) {
                cancellation.cancel()
            }
        })
        return await failure(
            exporting: request,
            in: sandbox,
            to: destination,
            context: context(sandbox, synthesizer: fake) { progress?.add($0) },
            cancellation: cancellation
        )
    }

    // MARK: - Reading What an Export Left

    /// The folders under the store's root, each one export's kept chapters;
    /// none once the root is gone.
    private func storeFolders(in sandbox: Sandbox) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: sandbox.storeRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: sandbox.storeRoot, includingPropertiesForKeys: nil)
    }

    /// The names of the files kept in the store's one export folder, sorted.
    /// The test fails when the root holds other than one folder.
    private func keptChapterNames(in sandbox: Sandbox, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let folders = try storeFolders(in: sandbox)
        XCTAssertEqual(folders.count, 1, "\(folders.map(\.lastPathComponent))", file: file, line: line)
        let folder = try XCTUnwrap(folders.first, "nothing was kept", file: file, line: line)
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The tag that begins a speech export's line in the debug log.
    private static let logTag = "SPEECH_EXPORT: "

    /// The speech export lines the debug log gains while `body` runs, each
    /// from its tag on, with its seconds, which vary, written "#".
    private func speechExportLogLines(during body: () async throws -> Void) async throws -> [String] {
        try TextMouthPaths.ensureDirectoryStructure()
        let before = Set(debugLogLines(containing: Self.logTag))
        try await body()
        return debugLogLines(containing: Self.logTag)
            .filter { !before.contains($0) }
            .compactMap { line in
                line.range(of: Self.logTag).map { tag in
                    String(line[tag.lowerBound...])
                        .replacingOccurrences(of: #"in [0-9]+\.[0-9] s$"#, with: "in # s", options: .regularExpression)
                }
            }
    }

    /// Checks that the file at `url` holds the whole book as `fake` spoke
    /// it: a chapter for the text before the first heading, under the book's
    /// title, then one for each heading, in order, each starting where the
    /// chapter before it and its gap end, and the file as long as all of
    /// them.
    private func assertWholeBook(
        in url: URL,
        spokenBy fake: FakeSpeechBufferSynthesizer,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let chapters = await AudioPlaybackService.extractChapters(from: url)
        XCTAssertEqual(chapters.map(\.title), Self.chapterTitles, message, file: file, line: line)
        let timing = Self.timing(of: fake.written)
        XCTAssertEqual(chapters.count, timing.starts.count, message, file: file, line: line)
        for (chapter, start) in zip(chapters, timing.starts) {
            XCTAssertEqual(chapter.startTime, start, accuracy: 0.05, "\(message) \(chapter.title)", file: file, line: line)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, timing.length, accuracy: 0.1, message, file: file, line: line)
    }

    /// When each of the whole book's chapters starts in its file, in
    /// seconds, and how long the file lasts, when `utterances` are every
    /// utterance the fake wrote it from: each chapter lasts as long as its
    /// utterances' tone, `framesPerUnit` frames for each UTF-16 unit at
    /// `sampleRate`, and every chapter but the last has the gap after it.
    private static func timing(of utterances: [SpeechExportUtterance]) -> (starts: [TimeInterval], length: TimeInterval) {
        var speech = Array(repeating: 0.0, count: chapterPhrases.count)
        for utterance in utterances {
            let index = chapterIndex(of: utterance)
            if speech.indices.contains(index) {
                speech[index] += Double(utterance.text.utf16.count * framesPerUnit) / sampleRate
            }
        }
        var starts: [TimeInterval] = []
        var length = 0.0
        for (index, seconds) in speech.enumerated() {
            starts.append(length)
            length += seconds + (index < speech.count - 1 ? SpeechExportJob.chapterGap : 0)
        }
        return (starts, length)
    }

    /// The title and artist tags of the file at `url`.
    private func tags(of url: URL) async throws -> (title: String?, artist: String?) {
        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        let title = try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            .first?.load(.stringValue)
        let artist = try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
            .first?.load(.stringValue)
        return (title, artist)
    }
}

// MARK: - Test Doubles

/// The voices the tests' exports know, through a fake lookup: no real voice
/// is ever looked up, and none is a real Personal Voice.
private enum TestVoices {
    /// A voice that speaks into files, named "Test Voice".
    static let ordinary = "com.textmouth.tests.speech-export.voice"
    /// A Personal Voice, named "Test Personal".
    static let personal = "com.textmouth.tests.speech-export.personal-voice"

    /// What the fake lookup knows of the voice with `identifier`: nil for
    /// one it does not know, as for a voice not installed.
    static func info(_ identifier: String) -> SpeechExportVoiceInfo? {
        switch identifier {
        case ordinary:
            return SpeechExportVoiceInfo(identifier: identifier, name: "Test Voice", isPersonalVoice: false)
        case personal:
            return SpeechExportVoiceInfo(identifier: identifier, name: "Test Personal", isPersonalVoice: true)
        default:
            return nil
        }
    }
}

/// A fake power assertion that records each hold and release, and holds
/// nothing.
private final class RecordedPower: Sendable {
    /// Every hold and release asked for, in order.
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// What was asked so far: "hold <reason>" for each hold, and
    /// "release <ID>" for each release.
    var entries: [String] {
        log.withLock { $0 }
    }

    /// The assertion an export holds through this record: each hold gives
    /// the ID 7.
    var assertion: SpeechExportPower {
        SpeechExportPower(
            hold: { reason in
                self.log.withLock { $0.append("hold \(reason)") }
                return 7
            },
            release: { id in
                self.log.withLock { $0.append("release \(id)") }
            }
        )
    }
}

/// The progress an export told, handed from its threads to the test.
private final class RecordedProgress: Sendable {
    /// The progress told, behind a lock.
    private let told = OSAllocatedUnfairLock<[SpeechExportProgress]>(initialState: [])

    /// Everything told, in order.
    var values: [SpeechExportProgress] {
        told.withLock { $0 }
    }

    /// Keeps `progress`.
    func add(_ progress: SpeechExportProgress) {
        told.withLock { $0.append(progress) }
    }
}

/// A synthesizer that hands on the fake's buffers, pausing before each but
/// the first of an utterance holding `phrase`, so that the time between two
/// of them passes the export's progress interval, as a real voice's does in
/// a long chapter.
private struct PausingSynthesizer: SpeechBufferSynthesizing {
    /// What makes the buffers and records the utterances.
    let fake: FakeSpeechBufferSynthesizer
    /// The phrase of the utterances whose buffers are paused between.
    let phrase: String
    /// How long each pause lasts, in seconds.
    let pause: TimeInterval

    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd {
        guard utterance.text.contains(phrase) else {
            return try fake.write(utterance, cancellation: cancellation, onBuffer: onBuffer)
        }
        // The fake hands its buffers on one after another on this thread.
        var buffersHandedOn = 0
        return try fake.write(utterance, cancellation: cancellation) { buffer in
            if buffersHandedOn > 0 {
                Thread.sleep(forTimeInterval: pause)
            }
            buffersHandedOn += 1
            try onBuffer(buffer)
        }
    }
}

private extension SpeechExportProgress {
    /// The chapters done, of how many, and the fraction of the speech
    /// spoken, while the chapters are spoken; nil while the file is encoded.
    var whileSpeaking: (done: Int, total: Int, fraction: Double)? {
        guard case let .speaking(done, total, fraction) = self else { return nil }
        return (done, total, fraction)
    }

    /// The chapters encoded, and the fraction of the way, while the file is
    /// encoded; nil while the chapters are spoken.
    var whileEncoding: (chapters: Int, fraction: Double)? {
        guard case let .encoding(chapters, fraction) = self else { return nil }
        return (chapters, fraction)
    }
}
