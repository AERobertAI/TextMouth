import os
import XCTest
@testable import TextMouth

/// An audiobook's media is checked before its sections are trusted (TODO
/// I04). Every file is real audio written by `AudioTestFixtures`, in a folder
/// of the test's own under the temporary directory.
final class AudioMediaValidationTests: XCTestCase {
    /// The audiobook folder this test parses, removed when the test ends.
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

    // MARK: - Valid Media Parses As Before

    /// A converted DAISY book's sections, two sharing one file and one
    /// playing a second file to its end, parse exactly as they always have:
    /// the same titles, headings, files, and sections, and ten placeholder
    /// characters per second of audio, with a section shorter than a second
    /// still given a second's worth.
    func testValidSectionsParseExactlyAsBefore() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        let sections = [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 0.5),
            AudioSegment(title: "Harbor Survey", file: "a.wav", startTime: 0.5, endTime: 2),
            AudioSegment(title: "Closing Notes", file: "b.wav", startTime: 0, endTime: 0)
        ]
        try writeManifest(title: "Harbor Soundings", author: "Odile Marchetti", sections: sections)

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.title, "Harbor Soundings")
        XCTAssertEqual(parsed.content.author, "Odile Marchetti")
        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Opening", "Harbor Survey", "Closing Notes"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 15, 10])
        XCTAssertEqual(
            parsed.content.chapters.map { $0.headings.map { "\($0.level) \($0.text) @\($0.chapterIndex):\($0.characterOffset)" } },
            [["1 Opening @0:0"], ["1 Harbor Survey @1:0"], ["1 Closing Notes @2:0"]]
        )
        XCTAssertEqual(parsed.filePaths, ["a.wav", "a.wav", "b.wav"].map { folder.appendingPathComponent($0).path })
        XCTAssertEqual(describe(parsed.segments), describe(sections))
    }

    /// A folder of tracks without sections still makes one heading per
    /// track, in Finder's order, titled by the manifest where it names the
    /// track and by the file's name otherwise.
    func testValidTracksParseExactlyAsBefore() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Disc 1/01.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Disc 1/02.wav"), duration: 2)
        try writeManifest(chapterTitles: ["Disc 1/02.wav": "Tide Tables"])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.chapters.map(\.title), ["01", "Tide Tables"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 20])
        XCTAssertEqual(
            parsed.filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            ["Disc 1/01.wav", "Disc 1/02.wav"].map { folder.appendingPathComponent($0).resolvingSymlinksInPath().path }
        )
        XCTAssertNil(parsed.segments)
    }

    /// A tracks list arranges a folder of tracks: its order and titles,
    /// and its group headings, each a level 1 heading at the start of the
    /// next track, at the same place as the track's own heading, which is
    /// level 2 after the first group heading. A track the list leaves out
    /// follows, with a level 1 heading of its own. The index an import
    /// saves keeps both headings of a place, in order, and is sound.
    func testTracksListArrangesOrderTitlesAndGroupHeadings() async throws {
        let names = [
            "where_is_everybody.wav", "one_for_the_angels.wav", "mr_denton_on_dooms_day.wav",
            "king_nine_will_not_return.wav", "the_lonely.wav"
        ]
        for name in names {
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(name), duration: 1)
        }
        let manifest = AudioManifestTests.exampleJSON.replacingOccurrences(of: ".ogg", with: ".wav")
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.title, "Radio Dramas")
        XCTAssertEqual(parsed.content.author, "Various")
        XCTAssertEqual(parsed.content.chapters.map(\.title), [
            "Where Is Everybody?", "One for the Angels", "mr_denton_on_dooms_day", "king_nine_will_not_return", "the_lonely"
        ])
        XCTAssertEqual(
            parsed.content.chapters.map { $0.headings.map { "\($0.level) \($0.text) @\($0.chapterIndex):\($0.characterOffset)" } },
            [
                ["1 Season One @0:0", "2 Where Is Everybody? @0:0"],
                ["2 One for the Angels @1:0"],
                ["2 mr_denton_on_dooms_day @2:0"],
                ["1 Season Two @3:0", "2 king_nine_will_not_return @3:0"],
                ["1 the_lonely @4:0"]
            ]
        )
        XCTAssertEqual(parsed.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }, [
            "where_is_everybody.wav", "one_for_the_angels.wav", "mr_denton_on_dooms_day.wav",
            "king_nine_will_not_return.wav", "the_lonely.wav"
        ])
        XCTAssertNil(parsed.segments)

        let index = BookContentIndex.build(from: parsed.content, format: .audio, audioFilePaths: parsed.filePaths, audioBaseURL: folder)
        XCTAssertNil(index.validationFailure(for: .audio, audioBaseURL: folder))
        XCTAssertEqual(
            index.allHeadings.map { "\($0.level) \($0.text)" },
            parsed.content.chapters.flatMap(\.headings).map { "\($0.level) \($0.text)" }
        )
    }

    /// A single file without chapter markers is one section, titled by its
    /// file name, as long as the file plays.
    func testValidSingleFileParsesExactlyAsBefore() async throws {
        let file = folder.appendingPathComponent("Ferry Timetables.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)

        let content = try await AudioBookParser.parse(url: file)

        XCTAssertEqual(content.title, "Ferry Timetables")
        XCTAssertEqual(content.author, "Unknown")
        XCTAssertEqual(content.chapters.map(\.title), ["Ferry Timetables"])
        XCTAssertEqual(content.chapters.map(\.text.count), [20])
    }

    /// A single file with chapter markers is one section per marker, in the
    /// markers' order, titled by them, and timed as they are, ten
    /// placeholder characters per second (TODO Q06 pins this before the
    /// markers are read through AVFoundation's asynchronous API).
    func testChapteredSingleFileParsesOneSectionPerMarker() async throws {
        let file = folder.appendingPathComponent("Harbor Lectures.m4a")
        try await AudioTestFixtures.writeChapteredAAC(to: file, duration: 3, chapters: [
            AudioTestFixtures.ChapterMarker(title: "Harbor Approach", start: 0, duration: 1),
            AudioTestFixtures.ChapterMarker(title: "Breakwater Survey", start: 1, duration: 2)
        ])

        let markers = await AudioPlaybackService.extractChapters(from: file)
        XCTAssertEqual(markers.map(\.title), ["Harbor Approach", "Breakwater Survey"])
        XCTAssertEqual(markers.map(\.startTime), [0, 1])
        XCTAssertEqual(markers.map(\.duration), [1, 2])

        let content = try await AudioBookParser.parse(url: file)
        XCTAssertEqual(content.title, "Harbor Lectures")
        XCTAssertEqual(content.chapters.map(\.title), ["Harbor Approach", "Breakwater Survey"])
        XCTAssertEqual(content.chapters.map(\.text.count), [10, 20])
    }

    // MARK: - Probing One File

    /// A valid file plays exactly as long as its samples last, whether
    /// stored as WAVE or encoded as AAC.
    func testProbeMeasuresValidFiles() async throws {
        let wave = folder.appendingPathComponent("two seconds.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let aac = folder.appendingPathComponent("one second.m4a")
        try AudioTestFixtures.writeAACSilence(to: aac, duration: 1)

        let waveDuration = try await AudioMediaProbe.duration(of: wave).get()
        let aacDuration = try await AudioMediaProbe.duration(of: aac).get()

        XCTAssertEqual(waveDuration, 2)
        XCTAssertEqual(aacDuration, 1, accuracy: 0.01)
    }

    /// A file whose audio track ends before the file does, as when an
    /// audiobook's cover art or chapter titles outlast its audio, is
    /// measured whole but checked over the samples that track holds: the
    /// file's last second, which the track never reaches, is no evidence
    /// that its audio breaks off.
    func testProbeChecksAnAudioTrackOverItsOwnSamples() async throws {
        let file = folder.appendingPathComponent("two tracks.mov")
        try await AudioTestFixtures.writeTwoAudioTracks(to: file, first: 1, second: 3)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .success(3))
    }

    // MARK: - A Decoding Check That Does Not Return

    /// A decoding check that waits for `gate` (up to twenty seconds, so no test can hold a thread for ever), counts
    /// each start in `started`, and then finds nothing wrong.
    private func heldCheck(
        gate: DispatchSemaphore,
        started: OSAllocatedUnfairLock<Int>
    ) -> AudioMediaProbe.DecodeCheck {
        { _ in
            started.withLock { (count: inout Int) in count += 1 }
            _ = gate.wait(timeout: .now() + 20)
            return nil
        }
    }

    /// A problem the check finds is the probe's answer, so the seam changes nothing for a check that returns.
    func testTheDecodingCheckThePassedInIsTheOneThatDecides() async throws {
        let wave = folder.appendingPathComponent("two seconds.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)

        let outcome = await AudioMediaProbe.duration(of: wave, decoding: { _ in .cannotDecode })

        XCTAssertEqual(outcome, .failure(.cannotDecode))
    }

    /// A decoding check that never returns (as `AVAssetReader` did not on a GitHub runner) is waited for only until
    /// the probe's deadline: the file then passes on its header's length, in well under the check's own wait.
    /// Without the deadline the probe answers only when the check does, here twenty seconds later.
    func testAHungDecodingCheckIsGivenUpOnAtItsDeadlineAndTheFilePassesOnItsHeader() async throws {
        let wave = folder.appendingPathComponent("held.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = OSAllocatedUnfairLock(initialState: 0)
        let began = Date()

        let outcome = await AudioMediaProbe.duration(
            of: wave, decoding: heldCheck(gate: gate, started: started), deadline: 0.3)

        XCTAssertEqual(outcome, .success(2))
        XCTAssertEqual(started.withLock { $0 }, 1, "the check should have been started")
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "the probe waited for the check, not for its deadline")
    }

    /// Decoding checks that wait hold dispatch threads and not the threads of Swift's concurrency pool, which has one
    /// for each core: more probes than cores all reach their check at once, and a task of the pool still runs.
    /// With the check run in the probe's own task, only as many probes as the pool has threads reach it.
    func testHeldDecodingChecksLeaveTheConcurrencyPoolFree() async throws {
        let wave = folder.appendingPathComponent("held many.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<count { gate.signal() } }
        let started = OSAllocatedUnfairLock(initialState: 0)
        let check = heldCheck(gate: gate, started: started)
        let probes = (0..<count).map { _ in
            Task.detached(priority: .utility) { await AudioMediaProbe.duration(of: wave, decoding: check, deadline: 30) }
        }

        for _ in 0..<200 where started.withLock({ $0 }) < count {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(started.withLock { $0 }, count,
                       "only \(started.withLock { $0 }) of \(count) checks started: the rest could not get a thread")
        let ran = OSAllocatedUnfairLock(initialState: false)
        Task.detached(priority: .utility) { ran.withLock { $0 = true } }
        for _ in 0..<100 where !ran.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ran.withLock { $0 }, "a task could not run on the concurrency pool while the checks were held")

        for _ in 0..<count { gate.signal() }
        for probe in probes {
            let outcome = await probe.value
            XCTAssertEqual(outcome, .success(2))
        }
    }

    /// A plain text file named like an MP3 cannot be opened as audio.
    func testProbeRefusesTextNamedAsAudio() async throws {
        let file = folder.appendingPathComponent("note.mp3")
        try AudioTestFixtures.writePlainText(to: file)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .failure(.cannotOpen))
    }

    /// A WAVE file cut off right after its header opens, but holds no audio.
    func testProbeRefusesWAVWhoseSamplesAreMissing() async throws {
        let file = folder.appendingPathComponent("cut off.wav")
        try AudioTestFixtures.writeWAVHeaderWithoutSamples(to: file)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .failure(.noAudio))
    }

    /// A WAVE file whose samples cannot be decoded cannot be opened.
    func testProbeRefusesWAVWhoseSamplesCannotBeDecoded() async throws {
        let file = folder.appendingPathComponent("garbled.wav")
        try AudioTestFixtures.writeWAVWithUndecodableSamples(to: file)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .failure(.cannotOpen))
    }

    /// An AAC file cut off before its first sample still opens with its
    /// full duration; decoding its opening fails.
    func testProbeRefusesAACCutOffBeforeItsAudio() async throws {
        let file = folder.appendingPathComponent("no audio data.m4a")
        try AudioTestFixtures.writeTruncatedAAC(to: file, keepingAudioFraction: 0)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .failure(.cannotDecode))
    }

    /// An AAC file cut off halfway through its audio, as an interrupted
    /// download leaves it, still opens with its full duration and decodes
    /// at its start; decoding its end fails.
    func testProbeRefusesAACThatBreaksOffPartway() async throws {
        let file = folder.appendingPathComponent("half downloaded.m4a")
        try AudioTestFixtures.writeTruncatedAAC(to: file, keepingAudioFraction: 0.5)

        let outcome = await AudioMediaProbe.duration(of: file)

        XCTAssertEqual(outcome, .failure(.endsEarly))
    }

    // MARK: - Lengths a Header Makes Up

    /// The probe believes a length only when it is a finite number of
    /// seconds above zero and at most a year, the longest length any of
    /// TextMouth's readers believes; for any other, such as the 1e18
    /// seconds an MPEG-4 movie header can claim over an audio track of
    /// two, it refuses the file as holding no audio that can be played.
    func testTheProbeBelievesALengthOfAtMostAYear() {
        XCTAssertTrue(AudioMediaProbe.isPlayableLength(2))
        XCTAssertTrue(AudioMediaProbe.isPlayableLength(OggHeaderReader.maximumDuration))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(OggHeaderReader.maximumDuration + 1))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(1e18))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(0))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(-2))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(.infinity))
        XCTAssertFalse(AudioMediaProbe.isPlayableLength(.nan))
    }

    /// A file whose length is measured as 1e18 seconds neither traps nor
    /// builds a placeholder longer than the content index accepts: the
    /// book parses as one section of exactly that many characters. (Before
    /// the bound, `Int(_:)` trapped on this length.)
    func testAnAbsurdLengthParsesToTheLongestPlaceholderTheIndexAccepts() async throws {
        let file = folder.appendingPathComponent("Harbor Soundings.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)
        let absurd = AudioMediaProber { _ in .success(1e18) }

        let content = try await AudioBookParser.parse(url: file, prober: absurd)

        XCTAssertEqual(content.chapters.map(\.title), ["Harbor Soundings"])
        XCTAssertEqual(content.chapters.map(\.text.utf16.count), [BookContentIndex.maximumCharacterCount])
    }

    /// A length that is not a finite number above zero gets a placeholder
    /// of one character, and an absurd one the longest the index accepts;
    /// none traps. (Before the bound, infinity, NaN, and 1e18 trapped.)
    func testNoLengthAndAnAbsurdLengthGetBoundedPlaceholders() {
        XCTAssertEqual(AudioBookParser.placeholderLength(for: .infinity), 1)
        XCTAssertEqual(AudioBookParser.placeholderLength(for: -.infinity), 1)
        XCTAssertEqual(AudioBookParser.placeholderLength(for: .nan), 1)
        XCTAssertEqual(AudioBookParser.placeholderLength(for: -5), 1)
        XCTAssertEqual(AudioBookParser.placeholderLength(for: 1e18), BookContentIndex.maximumCharacterCount)
    }

    /// A year, the longest length the probe believes, is past the index's
    /// limit at ten characters a second, so its placeholder is that limit,
    /// while a 200-hour book keeps its ten characters a second and a
    /// moment of audio its one character. This changes at the bound
    /// without trapping either way.
    func testAYearOfAudioGetsTheLongestPlaceholderAndRealLengthsKeepTheirs() {
        XCTAssertEqual(
            AudioBookParser.placeholderLength(for: OggHeaderReader.maximumDuration),
            BookContentIndex.maximumCharacterCount
        )
        XCTAssertEqual(AudioBookParser.placeholderLength(for: 200 * 3_600), 7_200_000)
        XCTAssertEqual(AudioBookParser.placeholderLength(for: 0.05), 1)
    }

    /// A length the library shows never traps, however a header states
    /// it: no number shows as 0:00, and an absurd one as a year; real
    /// lengths show as before. (Before the bound, NaN, infinity, and 1e19
    /// trapped.)
    func testALengthTheLibraryShowsNeverTraps() {
        XCTAssertEqual(AudioPlaybackService.durationString(.nan), "0:00")
        XCTAssertEqual(AudioPlaybackService.durationString(.infinity), "0:00")
        XCTAssertEqual(AudioPlaybackService.durationString(-.infinity), "0:00")
        XCTAssertEqual(AudioPlaybackService.durationString(1e19), "8760:00:00")
        XCTAssertEqual(AudioPlaybackService.durationString(3_661), "1:01:01")
        XCTAssertEqual(AudioPlaybackService.durationString(75), "1:15")
    }

    /// A negative length shows as 0:00, not as "0:-5". This changes at the
    /// bound without trapping either way.
    func testANegativeLengthShowsAsNoTime() {
        XCTAssertEqual(AudioPlaybackService.durationString(-5), "0:00")
    }

    // MARK: - Damaged Files Fail By Name

    /// Text named as a track fails the book, naming the file by its path in
    /// the book, in the sentence used for every damaged file.
    func testTextNamedAsATrackFailsNamingItsPathInTheBook() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Disc 1/01.wav"))
        try AudioTestFixtures.writePlainText(to: folder.appendingPathComponent("Disc 2/02.mp3"))

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "Disc 2/02.mp3", problem: .cannotOpen))
        XCTAssertEqual(
            error?.localizedDescription,
            "The file “Disc 2/02.mp3” in this audiobook is damaged or incomplete: it cannot be opened as audio. "
                + AudioMediaAdvice.damage
        )
    }

    /// One undecodable track among valid ones fails the book, naming it.
    func testFolderWithOneUndecodableTrackFailsNamingThatTrack() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"))
        try AudioTestFixtures.writeWAVWithUndecodableSamples(to: folder.appendingPathComponent("02.wav"))
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("03.wav"))

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "02.wav", problem: .cannotOpen))
    }

    /// A track cut off after its header fails, naming it.
    func testTrackWithoutSamplesFailsNamingIt() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"))
        try AudioTestFixtures.writeWAVHeaderWithoutSamples(to: folder.appendingPathComponent("02.wav"))

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "02.wav", problem: .noAudio))
    }

    /// A track whose download stopped partway fails at import, naming it,
    /// rather than opening and failing partway through playback.
    func testTruncatedAACTrackFailsNamingIt() async throws {
        try AudioTestFixtures.writeAACSilence(to: folder.appendingPathComponent("01.m4a"))
        try AudioTestFixtures.writeTruncatedAAC(to: folder.appendingPathComponent("02.m4a"), keepingAudioFraction: 0.5)

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "02.m4a", problem: .endsEarly))
        XCTAssertEqual(
            error?.localizedDescription,
            "The file “02.m4a” in this audiobook is damaged or incomplete: "
                + "its audio breaks off before the length the file declares. "
                + AudioMediaAdvice.damage
        )
    }

    /// With several damaged tracks, the one named is the first in playing
    /// order (here the manifest's order), though all are probed together.
    func testFirstDamagedTrackInPlayingOrderIsNamed() async throws {
        try AudioTestFixtures.writeWAVHeaderWithoutSamples(to: folder.appendingPathComponent("a.wav"))
        try AudioTestFixtures.writePlainText(to: folder.appendingPathComponent("b.mp3"))
        try writeManifest(order: ["b.mp3", "a.wav"])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "b.mp3", problem: .cannotOpen))
    }

    /// A section playing from a damaged file fails, naming that file.
    func testSectionPlayingFromADamagedFileFailsNamingTheFile() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeTruncatedAAC(to: folder.appendingPathComponent("b.m4a"), keepingAudioFraction: 0.5)
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Survey", file: "b.m4a", startTime: 0, endTime: 1)
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .unplayableFile(file: "b.m4a", problem: .endsEarly))
    }

    /// A single-file book that cannot be played fails, naming the file.
    func testSingleDamagedFileFailsNamingIt() async throws {
        let file = folder.appendingPathComponent("Lecture.mp3")
        try AudioTestFixtures.writePlainText(to: file)

        do {
            _ = try await AudioBookParser.parse(url: file)
            XCTFail("A text file parsed as audio")
        } catch {
            XCTAssertEqual(error as? AudioParseError, .unplayableFile(file: "Lecture.mp3", problem: .cannotOpen))
        }
    }

    /// Each problem is told in the sentence every damaged file gets: the
    /// file, what is wrong with it, and what to do.
    func testUnplayableFileMessagesSayWhatIsWrongAndWhatToDo() {
        let reasons: [(AudioMediaProblem, String)] = [
            (.cannotOpen, "it cannot be opened as audio"),
            (.noAudio, "it holds no audio that can be played"),
            (.cannotDecode, "its audio cannot be decoded"),
            (.endsEarly, "its audio breaks off before the length the file declares")
        ]
        for (problem, reason) in reasons {
            XCTAssertEqual(
                AudioParseError.unplayableFile(file: "Disc 2/03.mp3", problem: problem).errorDescription,
                "The file “Disc 2/03.mp3” in this audiobook is damaged or incomplete: \(reason). "
                    + AudioMediaAdvice.damage
            )
        }
    }

    // MARK: - Sections Fit Their Files

    /// A section that starts after its file ends fails, naming the heading,
    /// its start, the file, and how long the file really is.
    func testSectionStartingPastTheEndFailsNamingHeadingTimesAndLength() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Chapter 12", file: "a.wav", startTime: 5, endTime: 6)
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsPastEnd(
            section: AudioSectionName(title: "Chapter 12", number: 2), file: "a.wav", start: 5, fileDuration: 2
        ))
        XCTAssertEqual(
            error?.localizedDescription,
            "The heading “Chapter 12” starts 5 seconds into its file “a.wav”, which is only 2 seconds long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// A section starting exactly where its file ends would play nothing.
    func testSectionStartingExactlyAtTheEndFails() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Afterword", file: "a.wav", startTime: 2, endTime: 2.5)
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsPastEnd(
            section: AudioSectionName(title: "Afterword", number: 2), file: "a.wav", start: 2, fileDuration: 2
        ))
    }

    /// A section playing to the end of its file (end time 0) from a start
    /// past that end fails the same way, rather than as an unknown length.
    func testSectionPlayingToTheEndFromPastTheEndFails() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [AudioSegment(title: "Coda", file: "a.wav", startTime: 3, endTime: 0)])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsPastEnd(
            section: AudioSectionName(title: "Coda", number: 1), file: "a.wav", start: 3, fileDuration: 2
        ))
    }

    /// A section ending far past its file's end fails, naming the heading,
    /// its end, the file, and the file's length.
    func testSectionEndingFarPastTheEndFails() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [AudioSegment(title: "Survey", file: "a.wav", startTime: 0, endTime: 3.5)])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionEndsPastEnd(
            section: AudioSectionName(title: "Survey", number: 1), file: "a.wav", end: 3.5, fileDuration: 2
        ))
        XCTAssertEqual(
            error?.localizedDescription,
            "The heading “Survey” ends 3 seconds into its file “a.wav”, which is only 2 seconds long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// The tolerance is the boundary: an end just inside it is moved back
    /// to the file's end, and an end just beyond it is refused.
    func testToleranceDividesMovedBackEndsFromRefusedOnes() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        let limit = 2 + AudioBookParser.endTolerance(forFileLasting: 2)

        try writeManifest(sections: [AudioSegment(title: "Survey", file: "a.wav", startTime: 0, endTime: limit - 0.001)])
        let parsed = try await AudioBookParser.parseDirectory(url: folder)
        XCTAssertEqual(parsed.segments?.map(\.endTime), [2])

        try writeManifest(sections: [AudioSegment(title: "Survey", file: "a.wav", startTime: 0, endTime: limit + 0.001)])
        let error = await parseDirectoryError()
        XCTAssertEqual(error, .sectionEndsPastEnd(
            section: AudioSectionName(title: "Survey", number: 1), file: "a.wav", end: limit + 0.001, fileDuration: 2
        ))
    }

    /// Ends within the tolerance, as encoder padding leaves DAISY clip ends,
    /// are moved back to exactly their file's measured end: the sections
    /// the book plays end there and their headings last that long. The
    /// move is logged once per file, however many of its sections moved.
    func testEndsWithinTheToleranceAreMovedBackAndLoggedOncePerFile() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        let title = "Padded Clips \(UUID().uuidString)"
        try writeManifest(title: title, sections: [
            AudioSegment(title: "Survey", file: "a.wav", startTime: 0, endTime: 2.3),
            AudioSegment(title: "Soundings", file: "a.wav", startTime: 1.5, endTime: 2.4),
            AudioSegment(title: "Harbor", file: "b.wav", startTime: 0, endTime: 1.2)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(describe(parsed.segments), [
            "Survey | a.wav | 0.0–2.0",
            "Soundings | a.wav | 1.5–2.0",
            "Harbor | b.wav | 0.0–1.0"
        ])
        // Two seconds; half a second, given a second's worth; one second.
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [20, 10, 10])
        // Each log line starts with a timestamp; compare from the tag on.
        let tag = "\(AudioBookParser.clampLogTag): \(title): "
        let logged = debugLogLines(containing: tag).compactMap { line in
            line.range(of: tag).map { String(line[$0.lowerBound...]) }
        }
        XCTAssertEqual(logged, [
            tag + "a.wav: moved 2 sections' ends back to the file's measured end of 2.000 s, from up to 0.400 s past it",
            tag + "b.wav: moved 1 section's end back to the file's measured end of 1.000 s, from 0.200 s past it"
        ])
    }

    /// A book refused for one section records no moved ends for the others.
    func testRefusedBookLogsNoMovedEnds() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        let title = "Refused Clips \(UUID().uuidString)"
        try writeManifest(title: title, sections: [
            AudioSegment(title: "Survey", file: "a.wav", startTime: 0, endTime: 2.3),
            AudioSegment(title: "Beyond", file: "a.wav", startTime: 4, endTime: 5)
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsPastEnd(
            section: AudioSectionName(title: "Beyond", number: 2), file: "a.wav", start: 4, fileDuration: 2
        ))
        XCTAssertEqual(debugLogLines(containing: "\(AudioBookParser.clampLogTag): \(title): "), [])
    }

    /// An end time of 0 still means "play to the end of the file": the
    /// section keeps its 0, and its heading lasts from its start to the
    /// file's measured end, as the saved index records.
    func testSectionPlayingToTheEndLastsUntilTheFileEnds() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 0.5),
            AudioSegment(title: "Remainder", file: "a.wav", startTime: 0.5, endTime: 0)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.segments?.map(\.endTime), [0.5, 0])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 15])
        let index = BookContentIndex.build(
            from: parsed.content,
            format: .audio,
            audioFilePaths: parsed.filePaths,
            audioSegments: parsed.segments,
            audioBaseURL: folder
        )
        XCTAssertEqual(index.chapters.last?.audio?.duration ?? 0, 1.5, accuracy: 1e-9)
    }

    /// A section that starts before an earlier section of the same file
    /// fails, naming both headings and both starts.
    func testSectionStartingBeforeAnEarlierSectionInItsFileFails() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            AudioSegment(title: "Chapter 1", file: "a.wav", startTime: 1, endTime: 2),
            AudioSegment(title: "Chapter 2", file: "a.wav", startTime: 0, endTime: 1)
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsBeforeEarlierSection(
            section: AudioSectionName(title: "Chapter 2", number: 2),
            file: "a.wav",
            start: 0,
            earlierSection: AudioSectionName(title: "Chapter 1", number: 1),
            earlierStart: 1
        ))
        XCTAssertEqual(
            error?.localizedDescription,
            "The heading “Chapter 2” starts 0 seconds into its file “a.wav”, before the heading “Chapter 1”, "
                + "which comes earlier in the book and starts 1 second in. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// Sections may overlap: a later heading can start inside an earlier
    /// one, as in books the DAISY converter made, before a heading could
    /// play several clips, where navigation moves between files. Both keep
    /// their own ranges.
    func testOverlappingSectionsInOneFileAreAccepted() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            AudioSegment(title: "Part One", file: "a.wav", startTime: 0, endTime: 2),
            AudioSegment(title: "First Sounding", file: "a.wav", startTime: 0.5, endTime: 1.5)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [20, 10])
    }

    /// Order is kept within each file: sections may leave a file for
    /// another and come back to it further on, and may start together.
    func testSectionsMayLeaveAFileReturnToItAndStartTogether() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try writeManifest(sections: [
            AudioSegment(title: "Part One", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "First Sounding", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Interlude", file: "b.wav", startTime: 0, endTime: 0),
            AudioSegment(title: "Second Sounding", file: "a.wav", startTime: 1, endTime: 2)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Part One", "First Sounding", "Interlude", "Second Sounding"])
    }

    // MARK: - Sections of Several Clips

    /// A section whose clips play from three files lasts as long as its
    /// clips together. A middle clip that plays to its file's end is given
    /// that end, so every clip of the section has a known length, while a
    /// one-clip section keeps its 0. The section starts in its first clip's
    /// file.
    func testSectionOfSeveralClipsLastsAsLongAsItsClipsTogether() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("c.wav"), duration: 1.5)
        let survey = try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: [
            AudioClip(file: "a.wav", startTime: 0.5, endTime: 2),
            AudioClip(file: "b.wav", startTime: 0, endTime: 0),
            AudioClip(file: "c.wav", startTime: 0, endTime: 1.5)
        ]))
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 0.5),
            survey,
            AudioSegment(title: "Closing Notes", file: "c.wav", startTime: 0, endTime: 0)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        // Half a second, given a second's worth; 1.5 + 1 + 1.5 seconds; 1.5.
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 40, 15])
        XCTAssertEqual(describeClips(parsed.segments), [
            ["a.wav 0.0–0.5"],
            ["a.wav 0.5–2.0", "b.wav 0.0–1.0", "c.wav 0.0–1.5"],
            ["c.wav 0.0–0.0"]
        ])
        XCTAssertEqual(parsed.filePaths, ["a.wav", "a.wav", "c.wav"].map { folder.appendingPathComponent($0).path })
    }

    /// I04's clamp applies to every clip: a middle clip ending just past
    /// its file's end is moved back to exactly that end, and the move is
    /// logged for its file.
    func testMiddleClipEndingWithinTheToleranceIsMovedBack() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("c.wav"), duration: 1)
        let title = "Padded Middle Clip \(UUID().uuidString)"
        try writeManifest(title: title, sections: [try XCTUnwrap(AudioSegment(title: "Survey", clips: [
            AudioClip(file: "a.wav", startTime: 0, endTime: 2),
            AudioClip(file: "b.wav", startTime: 0, endTime: 1.25),
            AudioClip(file: "c.wav", startTime: 0, endTime: 1)
        ]))])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(describeClips(parsed.segments), [["a.wav 0.0–2.0", "b.wav 0.0–1.0", "c.wav 0.0–1.0"]])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [40])
        let tag = "\(AudioBookParser.clampLogTag): \(title): "
        let logged = debugLogLines(containing: tag).compactMap { line in
            line.range(of: tag).map { String(line[$0.lowerBound...]) }
        }
        XCTAssertEqual(logged, [
            tag + "b.wav: moved 1 section's end back to the file's measured end of 1.000 s, from 0.250 s past it"
        ])
    }

    /// A middle clip starting after its file ends fails, naming the heading
    /// and that clip's file, not the file the heading starts in.
    func testMiddleClipStartingPastItsFilesEndFailsNamingThatFile() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try writeManifest(sections: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
            try XCTUnwrap(AudioSegment(title: "Survey", clips: [
                AudioClip(file: "a.wav", startTime: 1, endTime: 2),
                AudioClip(file: "b.wav", startTime: 3, endTime: 3.5)
            ]))
        ])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionStartsPastEnd(
            section: AudioSectionName(title: "Survey", number: 2), file: "b.wav", start: 3, fileDuration: 1
        ))
    }

    /// A middle clip ending far past its file's end fails the same way.
    func testMiddleClipEndingFarPastItsFilesEndFails() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try writeManifest(sections: [try XCTUnwrap(AudioSegment(title: "Survey", clips: [
            AudioClip(file: "a.wav", startTime: 0, endTime: 2),
            AudioClip(file: "b.wav", startTime: 0, endTime: 5),
            AudioClip(file: "a.wav", startTime: 0, endTime: 1)
        ]))])

        let error = await parseDirectoryError()

        XCTAssertEqual(error, .sectionEndsPastEnd(
            section: AudioSectionName(title: "Survey", number: 1), file: "b.wav", end: 5, fileDuration: 1
        ))
    }

    /// A clip naming a file the book lacks, or with impossible times, is
    /// refused before any file is probed, wherever it lies in its section.
    func testMalformedLaterClipsAreRefusedBeforeAnyFileIsProbed() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"))
        let malformed = [
            AudioClip(file: "missing.wav", startTime: 0, endTime: 1),
            AudioClip(file: "../a.wav", startTime: 0, endTime: 1),
            AudioClip(file: "a.wav", startTime: -1, endTime: 0),
            AudioClip(file: "a.wav", startTime: 0.75, endTime: 0.5)
        ]
        for clip in malformed {
            try writeManifest(sections: [try XCTUnwrap(AudioSegment(title: "Survey", clips: [
                AudioClip(file: "a.wav", startTime: 0, endTime: 0.5),
                clip
            ]))])
            let recorder = ProbeRecorder()

            let error = await parseDirectoryError(prober: recorder.prober())

            XCTAssertEqual(error, .invalidSegment, clip.file)
            XCTAssertEqual(recorder.probedFiles, [], clip.file)
        }
    }

    /// Clips sharing a file probe it once: five clips in two files are two
    /// probes.
    func testFileSharedByClipsIsProbedOnce() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try writeManifest(sections: [
            try XCTUnwrap(AudioSegment(title: "One", clips: [
                AudioClip(file: "a.wav", startTime: 0, endTime: 0.5),
                AudioClip(file: "b.wav", startTime: 0, endTime: 0.5)
            ])),
            try XCTUnwrap(AudioSegment(title: "Two", clips: [
                AudioClip(file: "b.wav", startTime: 0.5, endTime: 1),
                AudioClip(file: "a.wav", startTime: 0.5, endTime: 1),
                AudioClip(file: "a.wav", startTime: 1.5, endTime: 2)
            ]))
        ])
        let recorder = ProbeRecorder()

        let parsed = try await AudioBookParser.parseDirectory(url: folder, prober: recorder.prober())

        XCTAssertEqual(recorder.probedFiles.sorted(), ["a.wav", "b.wav"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 15])
    }

    /// Only where sections start is kept in order within a file. A later
    /// clip of a section may go back in a file, as a note recorded at the
    /// end of a file interrupts the text before it.
    func testLaterClipsOfASectionMayGoBackInAFile() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try writeManifest(sections: [
            try XCTUnwrap(AudioSegment(title: "Chapter 1", clips: [
                AudioClip(file: "a.wav", startTime: 0, endTime: 0.5),
                AudioClip(file: "a.wav", startTime: 1.5, endTime: 2),
                AudioClip(file: "a.wav", startTime: 0.5, endTime: 1)
            ])),
            AudioSegment(title: "Chapter 2", file: "a.wav", startTime: 1, endTime: 1.5)
        ])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [15, 10])
    }

    /// Times are written as spoken words, which read the same on screen,
    /// aloud, and in braille: an hour into a ten-minute file.
    func testRangeMessagesSpeakTimesInWords() async throws {
        // Named like audio; the stand-in prober says it plays ten minutes.
        XCTAssertTrue(FileManager.default.createFile(atPath: folder.appendingPathComponent("03.wav").path, contents: nil))
        try writeManifest(sections: [
            AudioSegment(title: "Chapter 11", file: "03.wav", startTime: 0, endTime: 60),
            AudioSegment(title: "Chapter 12", file: "03.wav", startTime: 3_600, endTime: 3_700)
        ])

        let error = await parseDirectoryError(prober: ProbeRecorder().prober(answering: 600))

        XCTAssertEqual(
            error?.localizedDescription,
            "The heading “Chapter 12” starts 1 hour into its file “03.wav”, which is only 10 minutes long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// A heading without a title is named by its place among the headings.
    func testUntitledHeadingIsNamedByItsPlace() {
        let error = AudioParseError.sectionEndsPastEnd(
            section: AudioSectionName(title: " \n", number: 3), file: "Disc 1/03.mp3", end: 3_725, fileDuration: 3_600
        )

        XCTAssertEqual(
            error.errorDescription,
            "The untitled heading 3 ends 1 hour, 2 minutes, 5 seconds into its file “Disc 1/03.mp3”, "
                + "which is only 1 hour long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// User-facing text says "heading", never "chapter" (the headings
    /// vocabulary): no message says it unless a title does.
    func testMessagesNeverSayChapter() {
        let section = AudioSectionName(title: "Tide Tables", number: 2)
        let untitled = AudioSectionName(title: "", number: 1)
        let errors: [AudioParseError] = [
            .unplayableFile(file: "01.mp3", problem: .endsEarly),
            .sectionStartsPastEnd(section: section, file: "01.mp3", start: 700, fileDuration: 600),
            .sectionEndsPastEnd(section: section, file: "01.mp3", end: 700, fileDuration: 600),
            .sectionStartsBeforeEarlierSection(
                section: section, file: "01.mp3", start: 10, earlierSection: untitled, earlierStart: 20
            )
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").localizedCaseInsensitiveContains("chapter"), "\(error)")
        }
    }

    /// The tolerance is one second plus one percent of the file.
    func testToleranceIsOneSecondPlusOnePercentOfTheFile() {
        XCTAssertEqual(AudioBookParser.endTolerance(forFileLasting: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(AudioBookParser.endTolerance(forFileLasting: 600), 7, accuracy: 1e-9)
        XCTAssertEqual(AudioBookParser.endTolerance(forFileLasting: 3_600), 37, accuracy: 1e-9)
    }

    // MARK: - Each File Probed Once

    /// Sections sharing a file probe it once: four sections in two files
    /// are two probes, and the book parses as without the recorder.
    func testFileSharedBySectionsIsProbedOnce() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        try writeManifest(sections: [
            AudioSegment(title: "One", file: "a.wav", startTime: 0, endTime: 0.5),
            AudioSegment(title: "Two", file: "a.wav", startTime: 0.5, endTime: 1),
            AudioSegment(title: "Three", file: "a.wav", startTime: 1, endTime: 2),
            AudioSegment(title: "Four", file: "b.wav", startTime: 0, endTime: 0)
        ])
        let recorder = ProbeRecorder()

        let parsed = try await AudioBookParser.parseDirectory(url: folder, prober: recorder.prober())

        XCTAssertEqual(recorder.probedFiles.sorted(), ["a.wav", "b.wav"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 10, 10, 10])
    }

    /// Each track of a folder is probed exactly once.
    func testEachTrackIsProbedOnce() async throws {
        for track in ["01.wav", "02.wav", "03.wav"] {
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(track))
        }
        let recorder = ProbeRecorder()

        _ = try await AudioBookParser.parseDirectory(url: folder, prober: recorder.prober())

        XCTAssertEqual(recorder.probedFiles.sorted(), ["01.wav", "02.wav", "03.wav"])
    }

    /// A manifest section naming a file outside the book, or impossible
    /// times, is refused before any file is handed to AVFoundation.
    func testMalformedSectionsAreRefusedBeforeAnyFileIsProbed() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Track.wav"))
        let malformed = [
            AudioSegment(title: "Outside", file: "../Track.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Negative", file: "Track.wav", startTime: -1, endTime: 1),
            AudioSegment(title: "Reversed", file: "Track.wav", startTime: 0.75, endTime: 0.5)
        ]
        for section in malformed {
            // A valid section first, so its file would be probed if
            // checking stopped at the first bad section.
            try writeManifest(sections: [
                AudioSegment(title: "Valid", file: "Track.wav", startTime: 0, endTime: 0.5),
                section
            ])
            let recorder = ProbeRecorder()

            let error = await parseDirectoryError(prober: recorder.prober())

            XCTAssertEqual(error, .invalidSegment, section.title)
            XCTAssertEqual(recorder.probedFiles, [], section.title)
        }
    }

    /// Files are probed several at a time, and never more at once than
    /// `maximumConcurrentProbes`: every probe waits until that many are
    /// running, so all eight tracks parse only if they really run together,
    /// and a missing limit would let more than that many run.
    func testTracksAreProbedSeveralAtATimeUpToTheLimit() async throws {
        let tracks = (1...8).map { String(format: "%02d.wav", $0) }
        for track in tracks {
            // Named like audio; the recorder answers without opening them.
            XCTAssertTrue(FileManager.default.createFile(atPath: folder.appendingPathComponent(track).path, contents: nil))
        }
        let recorder = ProbeRecorder()
        let limit = AudioMediaProber.maximumConcurrentProbes

        let parsed = try await AudioBookParser.parseDirectory(
            url: folder,
            prober: recorder.prober(holdingUntilRunning: limit, answering: 1)
        )

        XCTAssertEqual(parsed.content.chapters.count, tracks.count)
        XCTAssertEqual(recorder.mostRunningAtOnce, limit)
        XCTAssertEqual(recorder.probedFiles.sorted(), tracks)
    }

    // MARK: - Helpers

    /// The error `parseDirectory` throws for this test's folder, probing
    /// with `prober`; nil, after recording a failure, when the folder
    /// parses or throws another kind of error.
    private func parseDirectoryError(
        prober: AudioMediaProber = .avFoundation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> AudioParseError? {
        do {
            _ = try await AudioBookParser.parseDirectory(url: folder, prober: prober)
            XCTFail("The folder parsed without an error", file: file, line: line)
            return nil
        } catch let error as AudioParseError {
            return error
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    /// Write this test's manifest.json: the book's title and author, the
    /// titles of whole-file tracks, their playing order, and the sections,
    /// as an import or the DAISY converter writes it.
    private func writeManifest(
        title: String? = nil,
        author: String? = nil,
        chapterTitles: [String: String]? = nil,
        order: [String]? = nil,
        sections: [AudioSegment]? = nil
    ) throws {
        let manifest = AudioManifest(
            title: title,
            author: author,
            chapters: chapterTitles,
            order: order,
            segments: sections
        )
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    /// Sections as "title | file | start–end" lines (of each section's
    /// first clip), which compare as a whole and read clearly in a failure
    /// message.
    private func describe(_ sections: [AudioSegment]?) -> [String] {
        (sections ?? []).map { "\($0.title) | \($0.file) | \($0.startTime)–\($0.endTime)" }
    }

    /// Each section's clips as "file start–end" lines, section by section,
    /// which compare as a whole and read clearly in a failure message.
    private func describeClips(_ sections: [AudioSegment]?) -> [[String]] {
        (sections ?? []).map { section in
            section.clips.map { "\($0.file) \($0.startTime)–\($0.endTime)" }
        }
    }
}

/// The sentences that end the media checks' messages, exactly as a listener
/// hears them. They are written out here, not taken from the app, so that
/// changing what the app says means changing these tests too.
enum AudioMediaAdvice {
    /// Ends the message about a damaged file (see `PackageDamage`).
    static let damage = "Get a fresh copy of the book, then import it again."
    /// Ends every message about a section that does not fit its file.
    static let mismatch = "The book's navigation does not match its audio; get a fresh copy and import it again."
}

/// Stands in for the app's prober: records each file it is asked to probe
/// and how many probes run at once, then answers as the app's prober would,
/// or with a fixed duration. Probes run on several threads at once, so
/// every stored property is read and written under the lock.
private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String] = []
    private var running = 0
    private var mostRunning = 0

    /// The name of every file probed so far, in the order the probes began.
    var probedFiles: [String] { locked { files } }

    /// The most probes that were ever running at the same time.
    var mostRunningAtOnce: Int { locked { mostRunning } }

    /// A prober that records each probe, holds it until `count` probes have
    /// run at once (giving up after two seconds, so a parse that never runs
    /// that many still ends), then answers with `duration` when given and
    /// otherwise as the app's prober does.
    func prober(holdingUntilRunning count: Int = 0, answering duration: TimeInterval? = nil) -> AudioMediaProber {
        AudioMediaProber { url in
            self.begin(url)
            defer { self.end() }
            let deadline = Date().addingTimeInterval(2)
            while self.mostRunningAtOnce < count, Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if let duration {
                return .success(duration)
            }
            return await AudioMediaProber.avFoundation.probe(url)
        }
    }

    /// Record that a probe of `url` began.
    private func begin(_ url: URL) {
        locked {
            files.append(url.lastPathComponent)
            running += 1
            mostRunning = max(mostRunning, running)
        }
    }

    /// Record that a probe ended.
    private func end() {
        locked { running -= 1 }
    }

    /// Run `body` holding the lock.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
