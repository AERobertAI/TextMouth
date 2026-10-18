import XCTest
@testable import TextMouth

/// Tests for `TextutilConverter` (FMT13): textutil run as a watched child,
/// its failures and refusals, and its sizing. Real textutil reads copies of
/// the format samples; stand-in children (`sleep`, `false`, small scripts)
/// with tight limits stand in for the hangs and failures.
final class TextutilConverterTests: XCTestCase {
    /// The folder textutil writes its hidden output in; every conversion
    /// must leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("TextutilWork")
    }

    // MARK: - Helpers

    /// The HTML of the sample at `path`, copied to a sandbox folder (as
    /// `name` when given) and read as `format` with the real textutil. The
    /// working folder must be empty afterwards.
    private func html(ofSample path: String, named name: String? = nil, as format: TextutilInputFormat) throws -> String {
        let copy = try copyOfFormatSample(path, named: name)
        let html = try TextutilConverter.html(of: copy, as: format, workingIn: work)
        assertWorkFolderEmpty()
        return html
    }

    /// Asserts that the working folder holds nothing, hidden files included.
    private func assertWorkFolderEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"]
        XCTAssertEqual(names, [], file: file, line: line)
    }

    /// Limits that keep a test short: the watchdog looks every 0.1 second.
    private func limits(seconds: TimeInterval = 5, stalled: TimeInterval = 5) -> WatchedProcess.Limits {
        WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30, maximumStalledSeconds: stalled, pollInterval: 0.1
        )
    }

    /// A stand-in tool whose child is `executable` with `arguments`; with
    /// `passingOutput` the output's path follows them, so a shell script
    /// reads it as `$0`.
    private func tool(
        _ executable: String,
        _ arguments: [String],
        passingOutput: Bool = false,
        limits: WatchedProcess.Limits? = nil
    ) -> TextutilConverter.Tool {
        let limits = limits ?? self.limits()
        return TextutilConverter.Tool(
            command: { _, _, output in
                (URL(fileURLWithPath: executable), passingOutput ? arguments + [output.path] : arguments)
            },
            limits: { _ in limits },
            residentMemory: { _ in nil }
        )
    }

    /// A file named `name`, holding `bytes`, in a new sandbox folder.
    private func file(_ name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("TextutilSource").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A three-byte file named `name`: non-empty, and within every limit
    /// these tests bind.
    private func tinyFile(_ name: String) throws -> URL {
        try file(name, holding: Data(repeating: 65, count: 3))
    }

    // MARK: - The Real textutil

    func testRTFReadsAsHTMLWithItsAuthor() throws {
        let html = try html(ofSample: "rtf/headings.rtf", as: .rtf)
        XCTAssertTrue(html.contains("Harbour Notes"))
        XCTAssertTrue(html.contains("<meta name=\"Author\" content=\"A. Sample\">"))
    }

    func testRTFDReadsItsTextAndWritesNoAttachment() throws {
        let html = try html(ofSample: "rtfd/with-image.rtfd", named: "with-image.rtfd", as: .rtfd)
        XCTAssertTrue(html.contains("After the picture"))
        // -nostore: no attachment is written, here or anywhere beside the output
        // (the helper has already asserted the working folder is empty).
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("Attachment.png").path))
    }

    func testWordDocumentReads() throws {
        XCTAssertTrue(try html(ofSample: "doc/headings.doc", as: .doc).contains("Harbour Notes"))
    }

    func testWordTemplatesReadAsDocuments() throws {
        // A template reads as a .doc, whatever its extension.
        XCTAssertFalse(try html(ofSample: "dot/headings-synthetic.dot", as: .doc).isEmpty)
        XCTAssertTrue(try html(ofSample: "dot/libreoffice-tdf120761_zOrder.dot", as: .doc).contains("Blah blah blah"))
    }

    func testOpenDocumentTextAndTemplateRead() throws {
        for path in ["odt/handwritten.odt", "ott/handwritten.ott"] {
            XCTAssertTrue(try html(ofSample: path, as: .odt).contains("<title>Harbour Notes</title>"), path)
        }
    }

    func testWordML2003Reads() throws {
        XCTAssertTrue(try html(ofSample: "wordml/headings.wordml", as: .wordml).contains("Harbour Notes"))
    }

    // MARK: - Refusals

    func testARichTextFileReadAsAWordDocumentIsUnreadable() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        XCTAssertThrowsError(try TextutilConverter.html(of: copy, as: .doc, workingIn: work)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.doc))
            XCTAssertEqual(
                $0.localizedDescription,
                "This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file."
            )
        }
        assertWorkFolderEmpty()
    }

    func testEveryFormatsSentenceIsPinned() {
        let tail = " It may be damaged, or another kind of file."
        let expected: [TextutilInputFormat: String] = [
            .rtf: "This file could not be read as a rich text document.",
            .rtfd: "This file could not be read as a rich text document with attachments.",
            .doc: "This file could not be read as a Word 97-2003 document.",
            .odt: "This file could not be read as an OpenDocument text document.",
            .wordml: "This file could not be read as a Word 2003 XML document.",
        ]
        // A new format must be given its sentence here.
        XCTAssertEqual(Set(expected.keys), Set(TextutilInputFormat.allCases))
        for (format, sentence) in expected {
            XCTAssertEqual(TextutilConverter.Failure.unreadable(format).errorDescription, sentence + tail)
        }
    }

    func testTheStoppedSentenceIsPinned() {
        XCTAssertEqual(
            TextutilConverter.Failure.stopped(reason: "it ran longer than 31 seconds").errorDescription,
            "TextMouth stopped reading this document because it ran longer than 31 seconds."
        )
    }

    func testTheFormatNamesAreTextutilsOwn() {
        XCTAssertEqual(TextutilInputFormat.allCases.map(\.rawValue), ["rtf", "rtfd", "doc", "odt", "wordml"])
    }

    // MARK: - Size Limits

    func testAnEmptyFileThrowsAndRunsNothing() throws {
        let source = try file("empty.rtf", holding: Data())
        // A stand-in that would leave a marker if it ran.
        let marker = work.appendingPathComponent("marker")
        let spy = tool("/usr/bin/touch", [marker.path])
        XCTAssertThrowsError(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: spy)) {
            XCTAssertEqual($0.localizedDescription, "This file has no text to read.")
            guard case FileImportError.noTextToRead = $0 else { return XCTFail("Expected noTextToRead, got \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testASourcePastTheLimitThrowsAndRunsNothing() throws {
        let source = try file("big.rtf", holding: Data(repeating: 65, count: 5))
        let marker = work.appendingPathComponent("marker")
        let spy = tool("/usr/bin/touch", [marker.path])
        try DocumentByteLimit.$current.withValue(4) {
            XCTAssertThrowsError(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: spy)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 4))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAnOutputPastTheLimitThrowsAndLeavesNothing() throws {
        let source = try tinyFile("small.rtf")
        // Ten bytes of output from a three-byte source, against a limit of eight.
        let writer = tool("/bin/sh", ["-c", "printf 0123456789 > \"$0\""], passingOutput: true)
        try DocumentByteLimit.$current.withValue(8) {
            XCTAssertThrowsError(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: writer)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 8))
            }
        }
        assertWorkFolderEmpty()
    }

    // MARK: - The Child

    func testAHungChildIsStoppedAndLeavesNothing() throws {
        let source = try tinyFile("hang.rtf")
        let hung = tool("/bin/sleep", ["60"], limits: limits(seconds: 1, stalled: 5))
        // Other tests' children may be running: the count must return to what it was.
        let childrenBefore = WatchedProcess.runningChildCount
        XCTAssertThrowsError(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: hung)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .stopped(reason: "it ran longer than 1 second"))
        }
        assertWorkFolderEmpty()
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
    }

    func testAFailingChildIsUnreadable() throws {
        let source = try tinyFile("bad.odt")
        XCTAssertThrowsError(
            try TextutilConverter.html(of: source, as: .odt, workingIn: work, using: tool("/usr/bin/false", []))
        ) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.odt))
        }
        assertWorkFolderEmpty()
    }

    func testAChildThatExitsZeroWritingNothingIsUnreadable() throws {
        let source = try tinyFile("silent.doc")
        XCTAssertThrowsError(
            try TextutilConverter.html(of: source, as: .doc, workingIn: work, using: tool("/usr/bin/true", []))
        ) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.doc))
        }
        assertWorkFolderEmpty()
    }

    func testAChildThatCannotStartIsUnreadable() throws {
        let source = try tinyFile("nostart.rtf")
        XCTAssertThrowsError(
            try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: tool("/nonexistent/textutil", []))
        ) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.rtf))
        }
        assertWorkFolderEmpty()
    }

    func testAChildThatWritesHTMLReturnsItExactly() throws {
        let source = try tinyFile("fine.rtf")
        let writer = tool("/bin/sh", ["-c", "printf '<p>ok</p>' > \"$0\""], passingOutput: true)
        XCTAssertEqual(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: writer), "<p>ok</p>")
        assertWorkFolderEmpty()
    }

    func testInvalidBytesInTheOutputBecomeReplacementCharacters() throws {
        let source = try tinyFile("odd.rtf")
        let writer = tool("/bin/sh", ["-c", "printf 'a\\377b' > \"$0\""], passingOutput: true)
        XCTAssertEqual(try TextutilConverter.html(of: source, as: .rtf, workingIn: work, using: writer), "a\u{FFFD}b")
        assertWorkFolderEmpty()
    }

    // MARK: - Arguments and Limits

    func testTheArgumentsArePinned() {
        let arguments = TextutilConverter.arguments(
            input: URL(fileURLWithPath: "/in/-dash.doc"),
            format: .doc,
            output: URL(fileURLWithPath: "/out/.x.textutil.html")
        )
        XCTAssertEqual(arguments, [
            "-convert", "html", "-noload", "-nostore", "-format", "doc", "-encoding", "UTF-8",
            "-output", "/out/.x.textutil.html", "--", "/in/-dash.doc",
        ])
    }

    func testTheLimitsGrowWithTheDocument() {
        let empty = TextutilConverter.limits(forBytes: 0)
        XCTAssertEqual(empty.maximumSeconds, 30)
        XCTAssertEqual(empty.maximumStalledSeconds, 30)
        XCTAssertEqual(empty.maximumResidentBytes, 1_073_741_824)
        XCTAssertEqual(empty.effectiveMaximumCPUSeconds, 120)
        let large = TextutilConverter.limits(forBytes: 3_300_000)
        XCTAssertEqual(large.maximumSeconds, 33.3, accuracy: 0.0001)
        XCTAssertEqual(large.maximumStalledSeconds, large.maximumSeconds)
        XCTAssertEqual(large.maximumResidentBytes, 1_073_741_824)
    }

    // MARK: - Sizing

    func testAFilesSizeIsItsLength() throws {
        XCTAssertEqual(try TextutilConverter.documentSize(of: file("a.rtf", holding: Data(repeating: 1, count: 7))), 7)
    }

    func testAFoldersSizeIsTheSumOfItsFilesAndNeverFollowsALink() throws {
        let folder = try copyOfFormatSample("rtfd/with-image.rtfd")
        // The package's two files, as the file system sizes them.
        var sum: Int64 = 0
        for name in ["TXT.rtf", "Attachment.png"] {
            let path = folder.appendingPathComponent(name).path
            sum += Int64(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int))
        }
        XCTAssertGreaterThan(sum, 0)
        XCTAssertEqual(try TextutilConverter.documentSize(of: folder), sum)

        // A link to a large file outside the folder adds nothing.
        let outside = try file("large.bin", holding: Data(repeating: 0, count: 1_000_000))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(try TextutilConverter.documentSize(of: folder), sum)
    }
}
