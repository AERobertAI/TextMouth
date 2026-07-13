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
}
