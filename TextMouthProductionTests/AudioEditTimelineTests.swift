import XCTest
@testable import TextMouth

/// The edit timeline (FR04): how each edit rearranges the stretches of sound,
/// to the sample, how times round to samples, which edits are refused and
/// with what sentence, and how chapter markers follow the sound through
/// cuts, trims, moves, insertions, punch-ins, and filters. Pure values: no
/// audio is read or written.
final class AudioEditTimelineTests: XCTestCase {

    // MARK: - Stretches of Sound

    /// A cut closes up the audio: what followed it plays right after what
    /// came before it.
    func testACutClosesUpTheAudio() throws {
        var timeline = makeTimeline()
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 5, end: 7)))
        XCTAssertEqual(stretches(of: timeline), ["base 0-5", "base 7-30"])
        XCTAssertEqual(timeline.duration, 28)
    }

    /// Trimming the start and the end keeps the middle; each trim's time is
    /// a time on the audio as the trim before it left it.
    func testTrimsKeepTheMiddle() throws {
        var timeline = makeTimeline()
        try timeline.applyRearranging(.trimStart(to: 2))
        try timeline.applyRearranging(.trimEnd(at: 18))
        XCTAssertEqual(stretches(of: timeline), ["base 2-20"])
    }

    /// A move takes the range out and puts it back at a time on the audio
    /// before the move, earlier or later.
    func testAMoveTakesTheRangeElsewhere() throws {
        var earlier = makeTimeline()
        try earlier.applyRearranging(.move(AudioTimeRange(start: 10, end: 12), to: 2))
        XCTAssertEqual(stretches(of: earlier), ["base 0-2", "base 10-12", "base 2-10", "base 12-30"])

        var later = makeTimeline()
        try later.applyRearranging(.move(AudioTimeRange(start: 2, end: 4), to: 10))
        XCTAssertEqual(stretches(of: later), ["base 0-2", "base 4-10", "base 2-4", "base 10-30"])
        XCTAssertEqual(later.duration, 30)
    }

    /// Inserted silence is a stretch of its own.
    func testSilenceIsInsertedAsItsOwnStretch() throws {
        var timeline = makeTimeline()
        try timeline.applyRearranging(.insertSilence(at: 3, duration: 1))
        XCTAssertEqual(stretches(of: timeline), ["base 0-3", "silence 1", "base 3-30"])
        XCTAssertEqual(timeline.duration, 31)
    }

    /// A punch-in replaces the range with the stretch of its take it uses,
    /// which may be longer or shorter than the range.
    func testAPunchInReplacesTheRangeWithItsTake() throws {
        var timeline = makeTimeline()
        let take = AudioEditTake(file: "audioEdits/takes/A.caf", range: AudioTimeRange(start: 0.5, end: 3.5))
        try timeline.applyRearranging(.replace(AudioTimeRange(start: 4, end: 6), with: take))
        XCTAssertEqual(stretches(of: timeline), ["base 0-4", "take 0.5-3.5", "base 6-30"])
        XCTAssertEqual(timeline.duration, 31)
    }

    /// Stretches that continue one another in their source are joined again,
    /// so moving sound back where it was leaves one stretch.
    func testNeighbouringStretchesOfOneSourceAreJoined() throws {
        var timeline = makeTimeline()
        try timeline.applyRearranging(.move(AudioTimeRange(start: 10, end: 12), to: 2))
        try timeline.applyRearranging(.move(AudioTimeRange(start: 2, end: 4), to: 12))
        XCTAssertEqual(stretches(of: timeline), ["base 0-30"])
        try timeline.applyRearranging(.insertSilence(at: 5, duration: 1))
        try timeline.applyRearranging(.insertSilence(at: 6, duration: 2))
        XCTAssertEqual(stretches(of: timeline), ["base 0-5", "silence 3", "base 5-30"])
    }

    /// Every time rounds to the nearest sample of the audio's own rate, so an
    /// edit lands on the same sample however often the list is applied.
    func testTimesRoundToTheNearestSample() throws {
        var timeline = AudioEditTimeline(sampleRate: 8_000, baseFrames: 80_000)
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 1.000_06, end: 2.000_04)))
        XCTAssertEqual(timeline.segments.map(\.length), [8_000, 64_000])
        XCTAssertEqual(timeline.segments.last?.sourceStart, 16_000)
        XCTAssertEqual(timeline.frame(at: 1.000_07), 8_001)
    }

    /// The stretches still from the audio the edits start from, and the
    /// sound as it was, are told apart: what decides whether samples can be
    /// copied as they are stored.
    func testOnlyRearrangedBaseSoundIsToldApart() throws {
        var timeline = makeTimeline()
        XCTAssertTrue(timeline.isUnchangedBase(baseFrames: 3_000))
        try timeline.applyRearranging(.setChapter(at: 10, title: "Locks"))
        XCTAssertTrue(timeline.isUnchangedBase(baseFrames: 3_000), "a marker leaves the sound as it was")
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
        XCTAssertFalse(timeline.isUnchangedBase(baseFrames: 3_000))
        XCTAssertTrue(timeline.isOnlyBase)
        try timeline.applyRearranging(.insertSilence(at: 1, duration: 1))
        XCTAssertFalse(timeline.isOnlyBase)
    }

    // MARK: - Refusals

    /// An edit that doesn't fit the audio is refused with a sentence saying
    /// why, and changes nothing.
    func testEditsThatDontFitAreRefusedWithAReason() async throws {
        let timeline = makeTimeline(chapters: [(10, "Weir")])
        let refusals: [(AudioEdit, String)] = [
            (.cut(AudioTimeRange(start: 20, end: 31)), "The range ends after the end of the audio, at 30 seconds."),
            (.cut(AudioTimeRange(start: 7, end: 5)), "The range has to start before it ends."),
            (.cut(AudioTimeRange(start: 0, end: 30)), "A cut can't remove all of the audio."),
            (.trimStart(to: 0), "Trimming to the very start removes nothing."),
            (.trimStart(to: 30), "A trim can't remove all of the audio."),
            (.trimEnd(at: 30), "Trimming at the very end removes nothing."),
            (.move(AudioTimeRange(start: 2, end: 6), to: 4), "The place to move to is inside the range being moved."),
            (.move(AudioTimeRange(start: 2, end: 6), to: 6), "The audio is already at that place."),
            (.insertSilence(at: 31, duration: 1), "That time is after the end of the audio, at 30 seconds."),
            (.insertSilence(at: 3, duration: 0), "Silence has to last longer than no time at all."),
            (.setChapter(at: 30, title: "End"), "A chapter marker can't be at the very end of the audio."),
            (.setChapter(at: 3, title: "  "), "A chapter marker needs a title."),
            (.removeChapter(at: 12), "There's no chapter marker at 12 seconds."),
            (.gain(decibels: 120, range: nil), "A volume change must be between -96 and +96 dB."),
        ]
        for (edit, reason) in refusals {
            var copy = timeline
            do {
                try await copy.apply(edit, processor: nil)
                XCTFail("\(edit) was applied")
            } catch {
                XCTAssertEqual(error as? AudioEditError, .invalidEdit(reason), "\(edit)")
            }
            XCTAssertEqual(copy, timeline, "\(edit) changed the timeline")
        }
        var filtered = timeline
        do {
            try await filtered.apply(.filter(chain: "volume=2", range: nil), processor: nil)
            XCTFail("a filter was applied without a processor")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .processingUnavailable)
        }
    }

    // MARK: - Chapter Markers

    /// Markers after a cut move back by its length; those before it stay.
    func testChaptersAfterACutMoveBack() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (20, "Weir"), (40, "Locks")])
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 10, end: 15)))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "15 Weir", "35 Locks"])
    }

    /// Markers inside a cut move to where it was, and the last of them wins:
    /// the sound there now is what followed it.
    func testAChapterInsideACutMovesToTheCutWhereTheLastOneWins() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (10, "Weir"), (12, "Mill"), (30, "Locks")])
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 8, end: 15)))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "8 Mill", "23 Locks"])
    }

    /// A cut across a chapter's end shortens the chapter, and the next one
    /// starts where the cut was.
    func testACutAcrossAChapterShortensIt() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (10, "Weir"), (20, "Locks")])
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 15, end: 25)))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "10 Weir", "15 Locks"])
    }

    /// Trimming the end drops the markers it leaves with no sound.
    func testChaptersAtTheEndAreDropped() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (40, "Weir"), (50, "Locks")])
        try timeline.applyRearranging(.trimEnd(at: 40))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry"])
    }

    /// Trimming the start puts the chapter holding the new start at 0.
    func testTrimmingTheStartKeepsTheChapterThatHoldsIt() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (5, "Weir"), (20, "Locks")])
        try timeline.applyRearranging(.trimStart(to: 8))
        XCTAssertEqual(markers(of: timeline), ["0 Weir", "12 Locks"])
    }

    /// A marker where sound is inserted stays, so the inserted sound belongs
    /// to its chapter; the markers after it move on.
    func testAChapterAtAnInsertionPointKeepsTheInsertedSound() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (10, "Weir"), (20, "Locks")])
        try timeline.applyRearranging(.insertSilence(at: 10, duration: 2))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "10 Weir", "22 Locks"])
    }

    /// Markers inside moved sound travel with it.
    func testMovedChaptersTravelWithTheirSound() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (11, "Weir"), (40, "Locks")])
        try timeline.applyRearranging(.move(AudioTimeRange(start: 10, end: 12), to: 30))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "29 Weir", "40 Locks"])
    }

    /// Moved sound that brings its own marker at its start takes the place,
    /// and the marker there follows its own sound.
    func testMovedSoundWithItsOwnStartingChapterTakesThePlace() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (40, "Locks")])
        try timeline.applyRearranging(.move(AudioTimeRange(start: 40, end: 45), to: 0))
        XCTAssertEqual(markers(of: timeline), ["0 Locks", "5 Ferry"])
    }

    /// Moved sound without a marker of its own joins the chapter at the
    /// place it goes to.
    func testMovedSoundWithoutAChapterJoinsTheChapterAtThePlace() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (40, "Locks")])
        try timeline.applyRearranging(.move(AudioTimeRange(start: 42, end: 45), to: 0))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "43 Locks"])
    }

    /// A punch-in keeps the marker at its start, and those after it move by
    /// the change in length.
    func testAPunchInMovesTheChaptersAfterIt() throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (4, "Weir"), (10, "Locks")])
        let take = AudioEditTake(file: "audioEdits/takes/A.caf", range: AudioTimeRange(start: 0, end: 5))
        try timeline.applyRearranging(.replace(AudioTimeRange(start: 4, end: 6), with: take))
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "4 Weir", "13 Locks"])
    }

    /// A processed range keeps its markers at the same proportion of the
    /// processed sound, and those after it move by the change in length.
    func testAProcessedRangeKeepsItsChaptersInProportion() async throws {
        var timeline = makeTimeline(seconds: 60, chapters: [(0, "Ferry"), (10, "Weir"), (20, "Locks"), (40, "Mill")])
        try await timeline.apply(.filter(chain: "atempo=2", range: AudioTimeRange(start: 0, end: 20)), processor: HalvingProcessor())
        XCTAssertEqual(markers(of: timeline), ["0 Ferry", "5 Weir", "10 Locks", "30 Mill"])
        XCTAssertEqual(stretches(of: timeline), ["processed 0-10", "base 20-60"])
    }

    /// A marker is set with a title, renamed by setting it again, and removed.
    func testChapterMarkersAreSetRenamedAndRemoved() throws {
        var timeline = makeTimeline(seconds: 60)
        try timeline.applyRearranging(.setChapter(at: 30, title: " Part Two "))
        XCTAssertEqual(markers(of: timeline), ["30 Part Two"])
        try timeline.applyRearranging(.setChapter(at: 30, title: "The Crossing"))
        try timeline.applyRearranging(.setChapter(at: 0, title: "Part One"))
        XCTAssertEqual(markers(of: timeline), ["0 Part One", "30 The Crossing"])
        try timeline.applyRearranging(.removeChapter(at: 30))
        XCTAssertEqual(markers(of: timeline), ["0 Part One"])
        XCTAssertEqual(timeline.chapterTimes.map(\.start), [0])
    }

    // MARK: - Helpers

    /// A timeline of `seconds` seconds of base sound at 100 frames a second,
    /// which keeps the arithmetic readable, with markers at whole seconds.
    private func makeTimeline(seconds: Int = 30, chapters: [(Int, String)] = []) -> AudioEditTimeline {
        AudioEditTimeline(
            sampleRate: 100,
            baseFrames: Int64(seconds * 100),
            chapters: chapters.map { AudioEditTimeline.Chapter(frame: Int64($0.0 * 100), title: $0.1) }
        )
    }

    /// The timeline's stretches in words: "base 7-30" (seconds of its
    /// source), "silence 1" (seconds long), "take 0.5-3.5", "processed 0-10".
    private func stretches(of timeline: AudioEditTimeline) -> [String] {
        timeline.segments.map { segment in
            let start = seconds(segment.sourceStart, timeline)
            let end = seconds(segment.sourceStart + segment.length, timeline)
            switch segment.source {
            case .base: return "base \(start)-\(end)"
            case .take: return "take \(start)-\(end)"
            case .processed: return "processed \(start)-\(end)"
            case .silence: return "silence \(seconds(segment.length, timeline))"
            }
        }
    }

    /// The markers in words: "15 Weir".
    private func markers(of timeline: AudioEditTimeline) -> [String] {
        timeline.chapters.map { "\(seconds($0.frame, timeline)) \($0.title)" }
    }

    /// `frames` as seconds, without a trailing ".0" for whole ones.
    private func seconds(_ frames: Int64, _ timeline: AudioEditTimeline) -> String {
        let value = timeline.seconds(at: frames)
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A processor that stands for a filter halving its stretch's length, as
/// atempo=2 does, without rendering anything.
private struct HalvingProcessor: AudioEditProcessing {
    func process(_ stretch: AudioEditTimeline, chain: String) async throws -> AudioEditTimeline.Segment {
        AudioEditTimeline.Segment(source: .processed("halved.caf"), sourceStart: 0, length: stretch.length / 2)
    }
}
