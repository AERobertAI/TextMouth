import XCTest
@testable import TextMouth

/// A speech export's chapter files joined into one (FMT43), starting with
/// the audio editor's timeline that joins them: the files played whole, one
/// after another, with a marker at the start of each titled file, a file of
/// no frames left out with its marker, and the chapter list a render writes
/// for them. No audio is needed: a timeline is a value.
final class SpeechExportEncoderTests: XCTestCase {

    /// Frames a second of the chapter files, as speech is rendered.
    private static let rate = 22_050.0

    /// The chapters most tests join: each one's title, and how long its file
    /// lasts, in seconds.
    private static let chapters: [(title: String, seconds: Double)] = [
        (title: "Harbour", seconds: 1.0),
        (title: "Market", seconds: 1.5),
        (title: "Evening", seconds: 0.5),
    ]

    /// The title of the book the chapters come from, which a render gives
    /// the sound before the first marker.
    private static let bookTitle = "The Ferry Timetable"

    // MARK: - Joining Files on the Timeline

    /// The three files are laid out one after another, each played whole
    /// from its first frame as processed sound by its name, with a marker at
    /// the start of each: at 0, at the first file's length, and at the first
    /// two files' lengths.
    func testJoiningLaysTheFilesOutOneAfterAnotherWithAMarkerAtEachStart() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: Self.joined(Self.chapters))

        XCTAssertEqual(timeline.sampleRate, Self.rate)
        XCTAssertEqual(timeline.segments, [
            AudioEditTimeline.Segment(source: .processed("0000.caf"), sourceStart: 0, length: 22_050),
            AudioEditTimeline.Segment(source: .processed("0001.caf"), sourceStart: 0, length: 33_075),
            AudioEditTimeline.Segment(source: .processed("0002.caf"), sourceStart: 0, length: 11_025),
        ])
        XCTAssertEqual(timeline.chapters, [
            AudioEditTimeline.Chapter(frame: 0, title: "Harbour"),
            AudioEditTimeline.Chapter(frame: 22_050, title: "Market"),
            AudioEditTimeline.Chapter(frame: 55_125, title: "Evening"),
        ])
        XCTAssertEqual(timeline.length, 66_150)
        XCTAssertEqual(timeline.duration, 3)
    }

    /// A file of no frames, or fewer, has no sound to mark: it is left out,
    /// and its marker with it, even when the file after it has no marker of
    /// its own to take that frame, or there is no file after it at all.
    func testJoiningLeavesOutAFileOfNoFramesWithItsMarker() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [
            (name: "0000.caf", frames: 0, title: "Opening"),
            (name: "0001.caf", frames: 22_050, title: nil),
            (name: "0002.caf", frames: 0, title: "Interval"),
            (name: "0003.caf", frames: -5, title: "Nowhere"),
            (name: "0004.caf", frames: 11_025, title: "Evening"),
            (name: "0005.caf", frames: 0, title: "Coda"),
        ])

        XCTAssertEqual(timeline.segments, [
            AudioEditTimeline.Segment(source: .processed("0001.caf"), sourceStart: 0, length: 22_050),
            AudioEditTimeline.Segment(source: .processed("0004.caf"), sourceStart: 0, length: 11_025),
        ])
        XCTAssertEqual(timeline.chapters, [AudioEditTimeline.Chapter(frame: 22_050, title: "Evening")])
        XCTAssertEqual(timeline.length, 33_075)
    }

    /// A file without a title has no marker: its sound belongs to the
    /// chapter before it, or, ahead of every marker, to the chapter a render
    /// names after the book.
    func testJoiningGivesAFileWithoutATitleNoMarker() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [
            (name: "0000.caf", frames: 11_025, title: nil),
            (name: "0001.caf", frames: 22_050, title: "Harbour"),
            (name: "0002.caf", frames: 33_075, title: nil),
            (name: "0003.caf", frames: 11_025, title: "Evening"),
        ])

        XCTAssertEqual(timeline.segments.map(\.source), ["0000.caf", "0001.caf", "0002.caf", "0003.caf"].map(AudioEditTimeline.Source.processed))
        XCTAssertEqual(timeline.chapters, [
            AudioEditTimeline.Chapter(frame: 11_025, title: "Harbour"),
            AudioEditTimeline.Chapter(frame: 66_150, title: "Evening"),
        ])
        XCTAssertEqual(
            AudioEditRenderer.chapterList(of: timeline, leadingTitle: Self.bookTitle).map(\.title),
            [Self.bookTitle, "Harbour", "Evening"]
        )
    }

    /// Joining no files gives no sound and no markers.
    func testJoiningNoFilesGivesNoSound() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [])

        XCTAssertEqual(timeline.segments, [])
        XCTAssertEqual(timeline.chapters, [])
        XCTAssertEqual(timeline.length, 0)
    }

    /// The chapter list a render writes for the joined files has a chapter
    /// for each titled file, the first at 0, each lasting as long as its
    /// file; the book's title names none, as no sound comes before the
    /// first marker.
    func testTheChapterListOfJoinedFilesHasAChapterForEachTitledFile() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: Self.joined(Self.chapters))

        XCTAssertEqual(AudioEditRenderer.chapterList(of: timeline, leadingTitle: Self.bookTitle), [
            AudioRenderChapter(start: 0, duration: 1, title: "Harbour"),
            AudioRenderChapter(start: 1, duration: 1.5, title: "Market"),
            AudioRenderChapter(start: 2.5, duration: 0.5, title: "Evening"),
        ])
    }

    // MARK: - Helpers

    /// The name of the file of the chapter at `index`, as the export's store
    /// names them: "0000.caf", "0001.caf", and on.
    private static func fileName(_ index: Int) -> String {
        String(format: "%04d.caf", index)
    }

    /// `chapters` as the timeline joins their files: each named for its
    /// place, as many frames long as its seconds hold, and titled.
    private static func joined(_ chapters: [(title: String, seconds: Double)]) -> [(name: String, frames: Int64, title: String?)] {
        chapters.enumerated().map { index, chapter in
            (name: fileName(index), frames: Int64((chapter.seconds * rate).rounded()), title: chapter.title)
        }
    }
}
