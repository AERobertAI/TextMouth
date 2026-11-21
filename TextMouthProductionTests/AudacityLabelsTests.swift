import XCTest
@testable import TextMouth

/// Audacity's label files, read and written (FMT06, `AudacityLabels`): both
/// samples, the lenient reading of what files in the wild hold, telling a
/// label file from another text file, and the text written, which reads
/// back as written. Nothing is played or imported.
final class AudacityLabelsTests: XCTestCase {
    // MARK: - The Samples

    /// labels.txt gives its four labels: two points, a region, and a region
    /// with no text, with its accent.
    func testTheLabelsSampleGivesItsFourLabels() throws {
        let labels = try XCTUnwrap(AudacityLabels.labels(inFileAt: CueSheetTests.sample("audacity-labels/labels.txt")))
        XCTAssertEqual(labels, [
            AudacityLabels.Label(start: 0, end: 0, text: "Point at the start"),
            AudacityLabels.Label(start: 1, end: 2, text: "Region: second tone, café"),
            AudacityLabels.Label(start: 2.5, end: 2.5, text: "Point inside the third tone"),
            AudacityLabels.Label(start: 3, end: 4, text: ""),
        ])
        XCTAssertEqual(labels.map(\.isPoint), [true, false, true, false])
    }

    /// labels-spectral.txt's backslash lines, spectral selections, are
    /// passed over, and its two labels are read.
    func testTheSpectralSampleSkipsItsSelections() throws {
        let labels = try XCTUnwrap(AudacityLabels.labels(inFileAt: CueSheetTests.sample("audacity-labels/labels-spectral.txt")))
        XCTAssertEqual(labels, [
            AudacityLabels.Label(start: 0.5, end: 0.5, text: "Point with frequency"),
            AudacityLabels.Label(start: 1, end: 3, text: "Region, high only"),
        ])
    }

    // MARK: - Lenient Reading

    /// A comma before the fraction, CR or CRLF line ends, a byte-order mark,
    /// blank lines, a tab inside the text, and an end before the start (a
    /// point) are all read.
    func testWhatFilesInTheWildHoldIsRead() {
        let text = "\u{FEFF}1,500000\t2,000000\tComma decimals\r\n\r\n3\t3\tWhole seconds\r"
            + "4.25\t4.0\tEnd before start\n5\t6\tText\twith a tab\n7\t7\n"
        XCTAssertEqual(AudacityLabels.parse(text), [
            AudacityLabels.Label(start: 1.5, end: 2, text: "Comma decimals"),
            AudacityLabels.Label(start: 3, end: 3, text: "Whole seconds"),
            AudacityLabels.Label(start: 4.25, end: 4.25, text: "End before start"),
            AudacityLabels.Label(start: 5, end: 6, text: "Text\twith a tab"),
            AudacityLabels.Label(start: 7, end: 7, text: ""),
        ])
        XCTAssertTrue(AudacityLabels.isLabelFile(text))
    }

    /// A text file of anything else is no label file: a song's lyrics, a
    /// table with words where times belong, signed or spelled-out numbers,
    /// and an empty file.
    func testOtherTextIsNoLabelFile() {
        let others = [
            "Verse one\nVerse two\n", "1\t2\tthree\nfour\tfive\tsix\n", "-1\t2\tNegative\n", "+1\t2\tSigned\n",
            "1e3\t2e3\tExponent\n", "nan\tinf\tNot numbers\n", "1.2.3\t4\tTwo points\n", "", "\n\n",
            "\\\t440\t880\n",
        ]
        for text in others {
            XCTAssertFalse(AudacityLabels.isLabelFile(text), text.debugDescription)
        }
        // A file of labels with one other line is not one either.
        XCTAssertFalse(AudacityLabels.isLabelFile("0\t0\tStart\nnot a label\n"))
    }

    /// A text file that is no label file reads as none, and so does one
    /// past the size limit.
    func testAFileThatIsNoLabelFileReadsAsNone() throws {
        let folder = try makeSandboxDirectory("labels-none")
        let lyrics = folder.appendingPathComponent("lyrics.txt")
        try Data("Row, row, row your boat\n".utf8).write(to: lyrics)
        XCTAssertNil(AudacityLabels.labels(inFileAt: lyrics))
        let large = folder.appendingPathComponent("large.txt")
        try Data(String(repeating: "0\t0\tx\n", count: AudacityLabels.maximumByteCount / 6 + 1).utf8).write(to: large)
        XCTAssertNil(AudacityLabels.labels(inFileAt: large))
    }

    // MARK: - Writing

    /// The text written is Audacity's: six decimals with a point, whatever
    /// the region, the end never before the start, and the text on one line
    /// with its tabs as spaces; it reads back as written.
    func testTheTextWrittenIsAudacitysAndReadsBack() {
        let labels = [
            AudacityLabels.Label(start: 0, end: 0, text: "Opening"),
            AudacityLabels.Label(start: 61.25, end: 62.5, text: "Two\nlines\tand a tab"),
            AudacityLabels.Label(start: 3_600.000_001, end: 3_600.000_001, text: "An hour"),
        ]

        let text = AudacityLabels.text(of: labels)

        XCTAssertEqual(text, "0.000000\t0.000000\tOpening\n61.250000\t62.500000\tTwo lines and a tab\n3600.000001\t3600.000001\tAn hour\n")
        XCTAssertEqual(AudacityLabels.parse(text).map(\.text), ["Opening", "Two lines and a tab", "An hour"])
        XCTAssertEqual(AudacityLabels.parse(text).map(\.start), [0, 61.25, 3_600.000_001])
        XCTAssertEqual(AudacityLabels.time(-1), "0.000000")
        XCTAssertEqual(AudacityLabels.time(.nan), "0.000000")
    }
}
