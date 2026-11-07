import XCTest
@testable import TextMouth

/// Regression coverage for the production audiobook layout resolver.
final class AudioLayoutTests: XCTestCase {
    /// DAISY segments carry both segment timing and per-chapter file paths.
    /// Timing must win so playback seeks to clip starts and stops at clip ends.
    func testSegmentedLayoutTakesPrecedenceOverChapterFiles() {
        let layout = ReaderViewModel.AudioLayout.determine(
            hasChapterFiles: true,
            hasSegments: true,
            chapterCount: 3
        )

        XCTAssertEqual(layout, .segmented)
    }

    /// Ordinary ZIP audiobooks still use one file per chapter when no segment
    /// timing metadata is present.
    func testChapterFilesResolveToMultiFileLayoutWithoutSegments() {
        let layout = ReaderViewModel.AudioLayout.determine(
            hasChapterFiles: true,
            hasSegments: false,
            chapterCount: 3
        )

        XCTAssertEqual(layout, .multiFile)
    }

    /// A single source file with embedded chapter metadata uses cumulative
    /// chapter offsets instead of the multi-file coordinate system.
    func testMultipleChaptersInOneFileResolveCorrectly() {
        let layout = ReaderViewModel.AudioLayout.determine(
            hasChapterFiles: false,
            hasSegments: false,
            chapterCount: 2
        )

        XCTAssertEqual(layout, .chaptersInOneFile)
    }

    // MARK: - Clip Ends

    /// The chapters' lengths in one file of chapters: 2.0, 3.0, and 4.5
    /// seconds of audio, ten characters standing for a second.
    private static let chapterLengths = [20, 30, 45]

    /// In one file of chapters, every chapter but the last stops where the
    /// next one starts, and the last plays on to the file's own end: the
    /// chapters' summed lengths drop each chapter's fraction of a tenth of
    /// a second, so a clip end at the last one's summed end finished the
    /// book before its file did, its last seconds unplayed.
    func testOnlyTheLastChapterOfAChapteredFilePlaysToTheFilesEnd() {
        let layout = ReaderViewModel.AudioLayout.chaptersInOneFile
        let lengths = Self.chapterLengths

        XCTAssertEqual(layout.clipEnd(ofChapter: 0, chapterUTF16Lengths: lengths), 2.0)
        XCTAssertEqual(layout.clipEnd(ofChapter: 1, chapterUTF16Lengths: lengths), 5.0)
        XCTAssertNil(layout.clipEnd(ofChapter: 2, chapterUTF16Lengths: lengths), "The last chapter stops short of its file's end")
        // Each chapter but the last ends exactly where the next one starts.
        for chapter in 0..<(lengths.count - 1) {
            XCTAssertEqual(
                layout.clipEnd(ofChapter: chapter, chapterUTF16Lengths: lengths),
                layout.chapterStartTime(chapterIndex: chapter + 1, chapterUTF16Lengths: lengths),
                "Chapter \(chapter) does not end where the next one starts"
            )
        }
        // A chapter the book does not have stops nowhere.
        XCTAssertNil(layout.clipEnd(ofChapter: -1, chapterUTF16Lengths: lengths))
        XCTAssertNil(layout.clipEnd(ofChapter: 3, chapterUTF16Lengths: lengths))
    }

    /// Every other layout plays each chapter to its file's own end: a file
    /// per chapter, a DAISY chapter without a segment, which plays its file
    /// whole, and one file of one chapter.
    func testNoOtherLayoutHasAClipEnd() {
        for layout: ReaderViewModel.AudioLayout in [.multiFile, .segmented, .singleFile] {
            for chapter in Self.chapterLengths.indices {
                XCTAssertNil(
                    layout.clipEnd(ofChapter: chapter, chapterUTF16Lengths: Self.chapterLengths),
                    "\(layout): chapter \(chapter) stops short of its file's end"
                )
            }
        }
    }
}
