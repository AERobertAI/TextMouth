import XCTest
@testable import TextMouth

/// The metadata file TextMouth gives ffmpeg with an MP3's chapters (FR04),
/// should the LAME built into TextMouth be unavailable: the characters
/// ffmpeg's reader treats as markup each escaped with a backslash, and every
/// line break in a title, a line feed, a carriage return, or the pair
/// Windows writes, as one escaped line feed, so a title stays whole on its
/// own line; its times in whole milliseconds. Lines are split and values
/// unescaped as ffmpeg's own reader does it (libavformat/ffmetadec.c). No
/// ffmpeg is run.
final class FFmpegMetadataTests: XCTestCase {

    // MARK: - Escaping

    /// "=", ";", "#", and the backslash are each escaped with a backslash,
    /// a backslash with a combining accent after it (one Character in Swift)
    /// included, and a line feed is written as an escaped line feed.
    func testMarkupIsEscapedWithABackslash() {
        let cases = [
            ("Locks=Weirs", "Locks\\=Weirs"),
            ("Locks;Weirs", "Locks\\;Weirs"),
            ("Lock #4", "Lock \\#4"),
            ("Canal\\Basin", "Canal\\\\Basin"),
            ("Canal\\\u{301}", "Canal\\\\\u{301}"),
            ("Locks\nWeirs", "Locks\\\nWeirs"),
        ]
        for (title, written) in cases {
            XCTAssertEqual(FFmpeg.escapeMetadata(title), written, title)
        }
    }

    /// A Windows line break (CR LF, one Character in Swift) and an old Mac
    /// one (a lone CR), at each of which ffmpeg's reader ends a line, are
    /// each written as one escaped line feed, as ffmpeg reads a line break
    /// within a value.
    func testEveryLineBreakIsWrittenAsOneEscapedLineFeed() {
        XCTAssertEqual(FFmpeg.escapeMetadata("a\r\nb"), "a\\\nb")
        XCTAssertEqual(FFmpeg.escapeMetadata("a\rb"), "a\\\nb")
        XCTAssertEqual(FFmpeg.escapeMetadata("a\r\n\r\nb"), "a\\\n\\\nb", "two Windows line breaks are two breaks")
        XCTAssertEqual(FFmpeg.escapeMetadata("a\n\rb"), "a\\\n\\\nb", "a line feed, then a carriage return, is two breaks")
        XCTAssertEqual(FFmpeg.escapeMetadata("Locks\r\n"), "Locks\\\n")
    }

    /// Everything else is written as it is: emoji, other scripts, and the
    /// empty string.
    func testEverythingElseIsWrittenAsItIs() {
        for title in ["Tide ☕️", "👩🏽‍🔧 at the 🇳🇱 lock", "Шлюзы и плотины", "運河の水門", "قناة السويس", ""] {
            XCTAssertEqual(FFmpeg.escapeMetadata(title), title, title)
        }
    }

    // MARK: - The Metadata File

    /// A chapter whose title holds a line break of any kind keeps it within
    /// its own title= line: as ffmpeg reads the file, there is exactly one
    /// title line for each chapter and 1 + 6 × chapters lines in all, and
    /// each title reads back whole, with one line feed for each break.
    func testATitleWithALineBreakStaysOnItsOwnLine() {
        let chapters = [
            AudioRenderChapter(start: 0, duration: 1, title: "Locks\r\nWeirs"),
            AudioRenderChapter(start: 1, duration: 1, title: "Tide\rMill"),
            AudioRenderChapter(start: 2, duration: 1, title: "Sluice\nGate"),
        ]

        let lines = Self.linesAsFFmpegReadsThem(FFmpeg.ffmetadata(chapters: chapters))

        XCTAssertEqual(lines.count, 1 + 6 * chapters.count, "\(lines)")
        let titles = lines.filter { $0.hasPrefix("title=") }.map { Self.unescapedAsFFmpegDoes(String($0.dropFirst("title=".count))) }
        XCTAssertEqual(titles, ["Locks\nWeirs", "Tide\nMill", "Sluice\nGate"])
    }

    /// Times are whole milliseconds, rounded to the nearest, a half away
    /// from zero: a chapter from 0.0004 s to 1.0005 s starts at 0 and ends
    /// at 1001 (0.0004 + 1.0001 is the very Double 1.0005 is, and times
    /// 1,000 exactly 1000.5); a chapter of no length starts and ends at once.
    func testTimesAreRoundedToWholeMilliseconds() {
        let chapters = [
            AudioRenderChapter(start: 0.000_4, duration: 1.000_1, title: "Locks"),
            AudioRenderChapter(start: 2, duration: 0, title: "Weirs"),
        ]

        XCTAssertEqual(FFmpeg.ffmetadata(chapters: chapters), """
            ;FFMETADATA1

            [CHAPTER]
            TIMEBASE=1/1000
            START=0
            END=1001
            title=Locks

            [CHAPTER]
            TIMEBASE=1/1000
            START=2000
            END=2000
            title=Weirs

            """)
    }

    /// With no chapters, the file is its header line alone.
    func testNoChaptersGiveTheHeaderAlone() {
        XCTAssertEqual(FFmpeg.ffmetadata(chapters: []), ";FFMETADATA1\n")
    }

    // MARK: - Helpers

    /// `text` split into lines as ffmpeg's ffmetadata reader splits it
    /// (read_line_to_bprint_escaped in libavformat/ffmetadec.c): a line ends
    /// at a line feed, a carriage return, a carriage return with the line
    /// feed after it, or a NUL, unless the character just before it in the
    /// line is a backslash. A line keeps its backslashes, which
    /// `unescapedAsFFmpegDoes(_:)` removes.
    private static func linesAsFFmpegReadsThem(_ text: String) -> [String] {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        // The character before this one in the line: a backslash there
        // keeps a line end in the line.
        var previous: Unicode.Scalar?
        // Whether the last line ended at a carriage return, whose line feed,
        // when one comes next, is part of the same line end.
        var endedAtReturn = false
        for scalar in text.unicodeScalars {
            if endedAtReturn && scalar == "\n" {
                endedAtReturn = false
                continue
            }
            endedAtReturn = false
            if (scalar == "\n" || scalar == "\r" || scalar == "\0") && previous != "\\" {
                lines.append(String(line))
                line = String.UnicodeScalarView()
                previous = nil
                endedAtReturn = scalar == "\r"
            } else {
                line.append(scalar)
                previous = scalar
            }
        }
        if !line.isEmpty {
            lines.append(String(line))
        }
        return lines
    }

    /// A value as ffmpeg's reader unescapes it (unescape in
    /// libavformat/ffmetadec.c): each backslash dropped, and the character
    /// after it kept, whatever it is.
    private static func unescapedAsFFmpegDoes(_ value: String) -> String {
        var unescaped = String.UnicodeScalarView()
        var escaping = false
        for scalar in value.unicodeScalars {
            if scalar == "\\" && !escaping {
                escaping = true
            } else {
                unescaped.append(scalar)
                escaping = false
            }
        }
        return String(unescaped)
    }
}
