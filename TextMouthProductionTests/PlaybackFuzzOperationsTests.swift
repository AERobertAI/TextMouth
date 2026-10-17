import XCTest
@testable import TextMouth

/// The playback fuzzer's generator (`PlaybackFuzzOperations`): a seed names
/// one sequence, always the same, and every operation it makes is one a
/// reader of the stated book can be given.
final class PlaybackFuzzOperationsTests: XCTestCase {
    /// A bounded draw is the plain remainder of SplitMix64's published
    /// numbers for seed 0 (0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4,
    /// 0x06C45D188009454F), so a seed in a failure report names the same
    /// sequence on any Mac and in any Swift release.
    func testABoundedDrawIsTheRemainderOfThePublishedNumbers() {
        var generator = SplitMix64(seed: 0)
        XCTAssertEqual([generator.below(1_000), generator.below(1_000), generator.below(1_000)], [535, 700, 679])
    }

    /// A bounded draw stays inside its bound, and a bound with nothing to
    /// draw from gives 0 rather than trapping on a remainder by zero.
    func testABoundedDrawStaysInsideItsBound() {
        var generator = SplitMix64(seed: 99)
        for _ in 0..<1_000 {
            let drawn = generator.below(7)
            XCTAssertTrue((0..<7).contains(drawn), "\(drawn) is outside 0..<7")
        }
        XCTAssertEqual(generator.below(0), 0)
        XCTAssertEqual(generator.below(-3), 0)
    }

    /// The same seed, length, kinds, and shape give the same sequence.
    func testASeedGivesTheSameSequenceEveryTime() {
        for seed: UInt64 in [0, 1, 17, 20_261_017, .max] {
            XCTAssertEqual(
                PlaybackOperation.sequence(seed: seed, length: 50),
                PlaybackOperation.sequence(seed: seed, length: 50),
                "seed \(seed) gave two sequences"
            )
        }
    }

    /// Different seeds give different sequences (a collision among a few
    /// seeds of fifty operations each would mean the seed is ignored).
    func testDifferentSeedsGiveDifferentSequences() {
        let sequences = (0..<10).map { PlaybackOperation.sequence(seed: UInt64($0), length: 50) }
        for (index, sequence) in sequences.enumerated() {
            for other in sequences[(index + 1)...] {
                XCTAssertNotEqual(sequence, other, "Two seeds gave the same sequence")
            }
        }
    }

    /// A sequence has the length asked for, an empty one when none or
    /// nothing to draw from is asked for.
    func testASequenceHasTheLengthAskedFor() {
        for length in [0, 1, 30, 200] {
            XCTAssertEqual(PlaybackOperation.sequence(seed: 5, length: length).count, length)
        }
        XCTAssertEqual(PlaybackOperation.sequence(seed: 5, length: -4), [])
        XCTAssertEqual(PlaybackOperation.sequence(seed: 5, length: 10, kinds: []), [])
    }

    /// Every seek lands in a chapter the book has, before the end of its
    /// text, whatever the book's shape: even chapters of one unit and a
    /// book with no chapters at all, where the only place is 0.
    func testEverySeekIsInsideTheBook() {
        let shapes = [
            PlaybackBookShape.sample,
            PlaybackBookShape(chapterLengths: [1]),
            PlaybackBookShape(chapterLengths: [1, 1_000_000, 3]),
            PlaybackBookShape(chapterLengths: [0, 7]),
            PlaybackBookShape(chapterLengths: []),
        ]
        for shape in shapes {
            var seeks = 0
            for seed in UInt64(0)..<40 {
                for case .seek(let chapter, let offset) in PlaybackOperation.sequence(
                    seed: seed, length: 60, kinds: [.seek], shape: shape
                ) {
                    seeks += 1
                    if shape.chapterLengths.isEmpty {
                        XCTAssertEqual(chapter, 0)
                        XCTAssertEqual(offset, 0)
                    } else {
                        XCTAssertTrue(shape.chapterLengths.indices.contains(chapter), "ch\(chapter) of \(shape)")
                        XCTAssertTrue(
                            (0..<max(1, shape.chapterLengths[chapter])).contains(offset),
                            "ch\(chapter)@\(offset) of \(shape)"
                        )
                    }
                }
            }
            XCTAssertEqual(seeks, 40 * 60, "A sequence of only seeks held something else")
        }
    }

    /// A sequence uses only the kinds it is given, and the default kinds
    /// between them reach every kind of operation.
    func testASequenceUsesOnlyTheKindsItIsGiven() {
        let pauses = PlaybackOperation.sequence(seed: 3, length: 20, kinds: [.pause])
        XCTAssertEqual(pauses, Array(repeating: .pause, count: 20))

        let described = Set(
            (0..<20).flatMap { PlaybackOperation.sequence(seed: UInt64($0), length: 100) }
                .map { $0.description.split(separator: " ").first.map(String.init) ?? "" }
        )
        for word in ["play", "pause", "toggle", "stop", "skip", "seek", "next", "previous", "voice", "faster",
                     "slower", "run", "route", "media", "invalidate", "sleep"] {
            XCTAssertTrue(described.contains(word), "No operation began with \"\(word)\"")
        }
    }

    /// Run times and sleep timers come from short fixed sets: a run is
    /// never long, and a timer never short enough to expire in a test.
    func testRunsAreShortAndTimersAreLong() {
        let operations = (0..<20).flatMap { PlaybackOperation.sequence(seed: UInt64($0), length: 100) }
        for case .run(let milliseconds) in operations {
            XCTAssertTrue([50, 100, 150, 200].contains(milliseconds), "run \(milliseconds)")
        }
        for case .sleepTimerSet(let minutes) in operations {
            XCTAssertTrue([30, 60, 90].contains(minutes), "sleep \(minutes)")
        }
    }

    /// The text of each operation is pinned, since a failure report is
    /// read, and rerun, from it.
    func testDescriptionsAreStableText() {
        let described: [(PlaybackOperation, String)] = [
            (.play, "play"), (.pause, "pause"), (.toggle, "toggle"), (.stop, "stop"),
            (.skipForward, "skip forward"), (.skipBackward, "skip back"),
            (.seek(chapter: 1, offset: 120), "seek ch1@120"),
            (.nextHeading, "next heading"), (.previousHeading, "previous heading"),
            (.changeVoice(choice: 2), "voice 2"), (.changeSpeed(faster: true), "faster"),
            (.changeSpeed(faster: false), "slower"), (.run(milliseconds: 100), "run 0.10"),
            (.routeLost, "route lost"), (.routeBack, "route back"),
            (.mediaPause, "media pause"), (.mediaPlay, "media play"),
            (.invalidateRenders, "invalidate renders"),
            (.sleepTimerSet(minutes: 60), "sleep 60"), (.sleepTimerCancel, "sleep cancel"),
        ]
        for (operation, text) in described {
            XCTAssertEqual(operation.description, text)
        }
        XCTAssertEqual(
            PlaybackOperation.describe(seed: 17, [.play, .run(milliseconds: 150), .seek(chapter: 1, offset: 120)]),
            "seed=17 [play, run 0.15, seek ch1@120]"
        )
        XCTAssertEqual(PlaybackOperation.describe(seed: 4, []), "seed=4 []")
    }
}
