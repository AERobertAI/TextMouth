import XCTest
@testable import TextMouth

/// Unit tests of `DocumentDump`: how a dump renders as a golden, and how
/// `differences(golden:actual:)` names what changed. They build small
/// synthetic dumps; nothing is imported.
final class DocumentDumpTests: XCTestCase {

    // MARK: - Fixtures

    /// A dump of a small book with two headings and no audio.
    private func sampleDump() -> DocumentDump {
        DocumentDump(
            fileName: "alice.epub", format: "epub", title: "Alice", author: "Lewis Carroll",
            chapterCount: 12, wordCount: 26_500, textLength: 148_907, textChecksum: "0123456789abcdef",
            firstSample: "Alice was beginning", lastSample: "happy summer days.",
            headings: [
                .init(level: 1, text: "Down the Rabbit-Hole"),
                .init(level: 2, text: "The Pool of Tears"),
            ]
        )
    }

    /// A dump of a book with audio: two tracks and a duration.
    private func audioDump() -> DocumentDump {
        var dump = sampleDump()
        dump.fileName = "story.zip"
        dump.audioDuration = 125.456
        dump.tracks = [
            .init(title: "One", file: "audio/one.mp3", start: 0, end: 61.5),
            .init(title: "Two", file: "audio/two.mp3", start: 61.5, end: 125.456),
        ]
        return dump
    }

    /// The differences of `changed` from `original`, each rendered as a golden.
    private func differences(from original: DocumentDump, to changed: DocumentDump) -> [String] {
        DocumentDump.differences(golden: original.rendered(), actual: changed.rendered())
    }

    // MARK: - Rendering

    /// The golden starts with its header, ends with one newline, and holds
    /// the facts in a fixed order, one per line.
    func testRenderingHasAHeaderAFixedOrderAndAFinalNewline() {
        let lines = sampleDump().rendered().components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# TextMouth document golden, format 2")
        XCTAssertEqual(lines.last, "", "the text ends with a newline")
        XCTAssertEqual(Array(lines.dropFirst().prefix(9)), [
            "file: alice.epub", "format: epub", "title: Alice", "author: Lewis Carroll", "chapters: 12",
            "words: 26500", "text length: 148907", "text checksum: 0123456789abcdef", "first 300: Alice was beginning",
        ])
        XCTAssertTrue(lines.contains("last 300: happy summer days."))
        XCTAssertTrue(lines.contains("heading: 1 | Down the Rabbit-Hole"))
        XCTAssertTrue(lines.contains("heading: 2 | The Pool of Tears"))
    }

    /// Rendering is stable: the same dump gives the same text every time.
    func testRenderingIsStable() {
        XCTAssertEqual(sampleDump().rendered(), sampleDump().rendered())
        XCTAssertEqual(audioDump().rendered(), audioDump().rendered())
    }

    /// Audio books list their duration, rounded to 0.01 s, and each track as
    /// "title | file | start-end".
    func testAudioDurationAndTracksAreRendered() {
        let lines = audioDump().rendered().components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("audio duration: 125.46"))
        XCTAssertTrue(lines.contains("track: One | audio/one.mp3 | 0.00-61.50"))
        XCTAssertTrue(lines.contains("track: Two | audio/two.mp3 | 61.50-125.46"))
    }

    /// A report message and a macOS version appear only when the dump has them.
    func testOptionalLinesAppearOnlyWhenPresent() {
        let plain = sampleDump().rendered()
        XCTAssertFalse(plain.contains("report:"))
        XCTAssertFalse(plain.contains("macOS:"))
        XCTAssertFalse(plain.contains("audio duration:"))
        var dump = sampleDump()
        dump.reportMessage = "2 of 14 chapters could not be read."
        dump.macOSVersion = "26.3"
        let lines = dump.rendered().components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("report: 2 of 14 chapters could not be read."))
        XCTAssertTrue(lines.contains("macOS: 26.3"))
        XCTAssertEqual(DocumentDump.macOSMajorVersion(inGolden: dump.rendered()), 26)
        XCTAssertNil(DocumentDump.macOSMajorVersion(inGolden: plain))
    }

    /// Newlines, carriage returns, tabs, and backslashes in a sample or a
    /// heading are written escaped, so each fact stays on one line.
    func testNewlinesInSamplesAreEscaped() {
        var dump = sampleDump()
        dump.firstSample = "One\ntwo\r\nthree\tfour\\five"
        dump.headings = [.init(level: 3, text: "Line\nbreak")]
        let rendered = dump.rendered()
        XCTAssertTrue(rendered.contains("first 300: One\\ntwo\\r\\nthree\\tfour\\\\five\n"))
        XCTAssertTrue(rendered.contains("heading: 3 | Line\\nbreak\n"))
        // The header, 8 fixed lines, two samples, one heading, and the empty piece after the final newline.
        XCTAssertEqual(rendered.components(separatedBy: "\n").count, 1 + 8 + 2 + 1 + 1)
    }

    /// An empty value (an unknown author) leaves no trailing space, and
    /// still compares equal to itself.
    func testAnEmptyValueLeavesNoTrailingSpace() {
        var dump = sampleDump()
        dump.author = ""
        let rendered = dump.rendered()
        XCTAssertTrue(rendered.contains("\nauthor:\n"))
        XCTAssertEqual(DocumentDump.differences(golden: rendered, actual: rendered), [])
    }

    // MARK: - No Difference

    /// A dump compared with its own rendering has no difference, whatever
    /// it holds.
    func testARenderedDumpHasNoDifferenceFromItself() {
        for dump in [sampleDump(), audioDump()] {
            XCTAssertEqual(differences(from: dump, to: dump), [])
        }
        var odd = sampleDump()
        odd.title = "Title: with | odd \"characters\""
        odd.firstSample = "line one\nline two"
        odd.reportMessage = "1 of 3 chapters could not be read."
        odd.macOSVersion = "26.0"
        XCTAssertEqual(differences(from: odd, to: odd), [])
    }

    /// Two dumps equal in every field give the same rendering and no
    /// difference.
    func testDumpsEqualInEveryFieldHaveNoDifference() {
        XCTAssertEqual(sampleDump(), sampleDump())
        XCTAssertEqual(differences(from: sampleDump(), to: sampleDump()), [])
    }

    // MARK: - Each Field

    /// A changed title is named with both values.
    func testAChangedTitleIsNamed() {
        var changed = sampleDump()
        changed.title = "Alice in Wonderland"
        XCTAssertEqual(differences(from: sampleDump(), to: changed), ["title: golden is \"Alice\", now \"Alice in Wonderland\""])
    }

    /// Author, format, file name, checksum, and samples are each named by key.
    func testTheTextFieldsAreNamedByKey() {
        var changed = sampleDump()
        changed.author = "Anonymous"
        changed.format = "docx"
        changed.fileName = "alice.docx"
        changed.textChecksum = "fedcba9876543210"
        changed.firstSample = "Different start"
        changed.lastSample = "Different end"
        XCTAssertEqual(differences(from: sampleDump(), to: changed), [
            "file: golden is \"alice.epub\", now \"alice.docx\"",
            "format: golden is \"epub\", now \"docx\"",
            "author: golden is \"Lewis Carroll\", now \"Anonymous\"",
            "text checksum: golden is \"0123456789abcdef\", now \"fedcba9876543210\"",
            "first 300: golden is \"Alice was beginning\", now \"Different start\"",
            "last 300: golden is \"happy summer days.\", now \"Different end\"",
        ])
    }

    /// A count says how many more or fewer.
    func testChangedCountsSayHowManyMoreOrFewer() {
        var fewer = sampleDump()
        fewer.textLength = 148_900
        fewer.wordCount = 26_501
        fewer.chapterCount = 12
        XCTAssertEqual(differences(from: sampleDump(), to: fewer), [
            "words: golden 26500, now 26501 (1 more)",
            "text length: golden 148907, now 148900 (7 fewer)",
        ])
    }

    /// A report, a duration, and a macOS version are named by key too.
    func testReportDurationAndMacOSAreNamed() {
        var original = audioDump()
        original.macOSVersion = "26.3"
        var changed = original
        changed.reportMessage = "1 of 2 chapters could not be read."
        changed.audioDuration = 130
        changed.macOSVersion = "27.0"
        XCTAssertEqual(differences(from: original, to: changed), [
            "macOS: golden is \"26.3\", now \"27.0\"",
            "report: golden has none, now \"1 of 2 chapters could not be read.\"",
            "audio duration: golden is \"125.46\", now \"130.00\"",
        ])
        XCTAssertEqual(differences(from: changed, to: original), [
            "macOS: golden is \"27.0\", now \"26.3\"",
            "report: golden is \"1 of 2 chapters could not be read.\", now there is none",
            "audio duration: golden is \"130.00\", now \"125.46\"",
        ])
    }

    /// A key the golden lacks is named, and so is one only the golden has.
    func testAMissingKeyInTheGoldenIsNamed() {
        let golden = sampleDump().rendered().replacingOccurrences(of: "author: Lewis Carroll\n", with: "")
        XCTAssertEqual(
            DocumentDump.differences(golden: golden, actual: sampleDump().rendered()),
            ["author: golden has none, now \"Lewis Carroll\""]
        )
    }

    /// A golden written by another format is named before anything else.
    func testAnotherGoldenFormatIsNamed() {
        let golden = sampleDump().rendered().replacingOccurrences(of: "format 2", with: "format 1")
        XCTAssertEqual(
            DocumentDump.differences(golden: golden, actual: sampleDump().rendered()).first,
            "golden header is \"# TextMouth document golden, format 1\", now \"# TextMouth document golden, format 2\""
        )
    }

    // MARK: - Pages (PG01)

    /// Pages are written after the headings and before the tracks, each as
    /// "page: LABEL | CHAPTER:OFFSET | OPENING" with label and opening escaped.
    func testPagesAreRenderedAfterTheHeadings() {
        var dump = audioDump()
        dump.pages = [
            .init(label: "1", chapterIndex: 0, characterOffset: 0, opening: "Alice was beginning"),
            .init(label: "A\t2", chapterIndex: 1, characterOffset: 42, opening: "line one\nline two"),
        ]
        let lines = dump.rendered().components(separatedBy: "\n")
        guard let first = lines.firstIndex(of: "heading: 2 | The Pool of Tears") else {
            return XCTFail("the last heading is missing")
        }
        XCTAssertEqual(Array(lines[first...]), [
            "heading: 2 | The Pool of Tears",
            "page: 1 | 0:0 | Alice was beginning",
            "page: A\\t2 | 1:42 | line one\\nline two",
            "track: One | audio/one.mp3 | 0.00-61.50",
            "track: Two | audio/two.mp3 | 61.50-125.46",
            "",
        ])
    }

    /// A moved page and a page only one side has are named as headings are.
    func testChangedPagesAreNamed() {
        var original = sampleDump()
        original.pages = [.init(label: "1", chapterIndex: 0, characterOffset: 0, opening: "Alice was beginning")]
        var changed = original
        changed.pages = [
            .init(label: "1", chapterIndex: 0, characterOffset: 6, opening: "was beginning"),
            .init(label: "2", chapterIndex: 0, characterOffset: 20, opening: "to get very tired"),
        ]
        XCTAssertEqual(differences(from: original, to: changed), [
            "pages: golden has 1, now 2",
            "page 1: golden \"1 | 0:0 | Alice was beginning\", now \"1 | 0:6 | was beginning\"",
            "page 2 only now: \"2 | 0:20 | to get very tired\"",
        ])
    }

    // MARK: - Headings and Tracks

    /// A heading whose level changed is named by number with both values.
    func testAChangedHeadingNamesTheHeading() {
        var changed = sampleDump()
        changed.headings[0].level = 2
        XCTAssertEqual(differences(from: sampleDump(), to: changed), [
            "heading 1: golden \"1 | Down the Rabbit-Hole\", now \"2 | Down the Rabbit-Hole\"",
        ])
    }

    /// A heading that disappeared or appeared is named with the counts.
    func testHeadingsOnlyInOneSideAreNamed() {
        var fewer = sampleDump()
        fewer.headings.removeLast()
        XCTAssertEqual(differences(from: sampleDump(), to: fewer), [
            "headings: golden has 2, now 1",
            "heading 2 only in golden: \"2 | The Pool of Tears\"",
        ])
        XCTAssertEqual(differences(from: fewer, to: sampleDump()), [
            "headings: golden has 1, now 2",
            "heading 2 only now: \"2 | The Pool of Tears\"",
        ])
    }

    /// A long list of heading differences is cut at 10 and the rest counted.
    func testALongHeadingDifferenceListIsCutAtTenAndCounted() {
        var original = sampleDump()
        original.headings = (1...25).map { .init(level: 1, text: "Heading \($0)") }
        var changed = original
        changed.headings = (1...25).map { .init(level: 2, text: "Heading \($0)") }
        let found = differences(from: original, to: changed)
        XCTAssertEqual(found.count, 11)
        XCTAssertEqual(found.first, "heading 1: golden \"1 | Heading 1\", now \"2 | Heading 1\"")
        XCTAssertEqual(found[9], "heading 10: golden \"1 | Heading 10\", now \"2 | Heading 10\"")
        XCTAssertEqual(found.last, "and 15 more heading differences")
    }

    /// Exactly ten differences are all named, with no "more" sentence.
    func testTenHeadingDifferencesAreAllNamed() {
        var original = sampleDump()
        original.headings = (1...10).map { .init(level: 1, text: "H\($0)") }
        var changed = original
        changed.headings = (1...10).map { .init(level: 3, text: "H\($0)") }
        let found = differences(from: original, to: changed)
        XCTAssertEqual(found.count, 10)
        XCTAssertFalse(found.contains { $0.hasPrefix("and ") })
    }

    /// A changed track is named by number; a duration change too.
    func testChangedTracksAreNamed() {
        var changed = audioDump()
        changed.tracks[1].end = 130
        changed.tracks.append(.init(title: "Three", file: "audio/three.mp3", start: 0, end: 10))
        XCTAssertEqual(differences(from: audioDump(), to: changed), [
            "tracks: golden has 2, now 3",
            "track 2: golden \"Two | audio/two.mp3 | 61.50-125.46\", now \"Two | audio/two.mp3 | 61.50-130.00\"",
            "track 3 only now: \"Three | audio/three.mp3 | 0.00-10.00\"",
        ])
    }

    /// Lines are compared by key: a line that appears does not shift the
    /// others into false differences.
    func testAnAddedLineDoesNotShiftTheOthers() {
        var changed = sampleDump()
        changed.reportMessage = "1 of 3 chapters could not be read."
        XCTAssertEqual(differences(from: sampleDump(), to: changed), [
            "report: golden has none, now \"1 of 3 chapters could not be read.\"",
        ])
    }

    /// Several differences are all listed, the scalars first.
    func testSeveralDifferencesAreAllListed() {
        var changed = sampleDump()
        changed.title = "B"
        changed.headings = []
        let found = differences(from: sampleDump(), to: changed)
        XCTAssertEqual(found.first, "title: golden is \"Alice\", now \"B\"")
        XCTAssertTrue(found.contains("headings: golden has 2, now 0"))
        XCTAssertTrue(found.contains("heading 1 only in golden: \"1 | Down the Rabbit-Hole\""))
    }
}
