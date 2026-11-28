import XCTest
@testable import TextMouth

/// Reading a timed-text file through `TimedTextReader` (FMT23, FMT25): each
/// format reaches its own reader, and a file read from disk is refused when
/// it is larger than the limit, before any of it is parsed. The samples are
/// copied into a folder of the test's own before they are read.
final class TimedTextFileReadingTests: XCTestCase {

    /// Each format's sample, read from its copy, gives the same document its
    /// own reader gives for the same bytes.
    func testEachFormatReachesItsOwnReader() throws {
        let samples: [(path: String, format: TimedTextFormat)] = [
            ("vtt/tone4.vtt", .webVTT),
            ("srt/tone4.srt", .subRip),
            ("podcast-transcript-json/transcript.json", .podcastJSON),
        ]
        for sample in samples {
            let url = try copyOfFormatSample(sample.path)
            let bytes = try Data(contentsOf: url)
            let direct: TimedTextDocument
            switch sample.format {
            case .webVTT: direct = try WebVTTReader.read(bytes)
            case .subRip: direct = try SubRipReader.read(bytes)
            case .podcastJSON: direct = try PodcastTranscriptReader.read(bytes)
            }

            let read = try TimedTextReader.read(fileAt: url, as: sample.format)

            XCTAssertEqual(read, direct, sample.path)
            XCTAssertEqual(read.format, sample.format, sample.path)
            XCTAssertEqual(read.cues.count, 4, sample.path)
            XCTAssertEqual(try TimedTextReader.read(bytes, as: sample.format), direct, sample.path)
        }
    }

    /// A file of exactly the limit is read; one byte more is refused as too
    /// large, naming the limit, before it is parsed.
    func testAFileLargerThanTheLimitIsRefused() throws {
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let size = try Data(contentsOf: url).count

        XCTAssertEqual(try TimedTextReader.read(fileAt: url, as: .webVTT, byteLimit: size).cues.count, 4)
        XCTAssertThrowsError(try TimedTextReader.read(fileAt: url, as: .webVTT, byteLimit: size - 1)) { error in
            XCTAssertEqual(error as? TimedTextError, .tooLarge(byteLimit: size - 1))
        }
    }

    /// The default limit is the one for files on this Mac, 20 MB.
    func testTheDefaultLimitIsTheLocalFilesLimit() {
        XCTAssertEqual(TimedTextLimits.localFileBytes, 20 * 1_048_576)
    }

    /// A file that is not there, or a folder, is refused with the system's
    /// own error, never taken for an empty transcript.
    func testAMissingFileOrAFolderIsRefused() throws {
        let folder = try makeSandboxDirectory("Timed Text Missing")
        let missing = folder.appendingPathComponent("absent.vtt")

        XCTAssertThrowsError(try TimedTextReader.read(fileAt: missing, as: .webVTT)) { error in
            XCTAssertNil(error as? TimedTextError, "a missing file is not a timed-text refusal: \(error)")
        }
        XCTAssertThrowsError(try TimedTextReader.read(fileAt: folder, as: .webVTT))
    }

    /// A file read as the wrong format is refused by that format's reader:
    /// a SubRip file is no WebVTT file.
    func testAFileReadAsTheWrongFormatIsRefused() throws {
        let url = try copyOfFormatSample("srt/tone4.srt")

        XCTAssertThrowsError(try TimedTextReader.read(fileAt: url, as: .webVTT)) { error in
            XCTAssertEqual(error as? TimedTextError, .notTimedText(.webVTT))
        }
    }
}
