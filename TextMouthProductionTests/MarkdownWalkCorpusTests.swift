import XCTest
@testable import TextMouth

/// Every Markdown text of a corpus is read, and exported, exactly as it was
/// on November 15, 2026.
///
/// Every text book passes through two walks of a Markdown tree: the reader's
/// (`MarkdownDocParser`), which makes the reading text, the headings, and the
/// pages, and the exporter's (`ExportDocumentWalker`), which makes the
/// document every export writer reads. The records here were made while both
/// walked swift-markdown's tree, just before they were moved to cmark's
/// own tree, so this test is the proof that the move changed nothing a
/// listener hears, sees in a heading list, or finds in an exported file. It
/// stays as the check for any later change to either walk, or to cmark.
///
/// - **The corpus** (`TestData/markdown-corpus`).
///   - `inputs/`: the content.md the importers wrote that day for every
///     book and format sample of TestData that holds text (`<golden
///     name>.content`), and TestData's Markdown file as it is. They are
///     inputs kept as they were, not expectations: a later change to an
///     importer does not touch them.
///   - A long generated document, eight damaged cuttings of each document
///     (`MarkdownWalkCorpusKit.cuttings`), and 3,000 generated mixes of
///     Markdown pieces (`mixes`).
///   - The named cases (`namedCases`): tables, marker comments, breaks,
///     nesting, code, links, entities, emphasis, headings' labels, deep trees.
/// - **What is recorded** (`MarkdownWalkCorpusKit.record`): the reader's whole
///   result (text, title, each heading's level, offset, label, and id, each
///   page's label and offset) for the whole text and for each chapter with
///   markers read and unread; the export walk's whole document for a writer of
///   the words alone and for one of the book's structure; for documents and
///   named cases, what the HTML, RTF, Markdown, and EPUB writers write and
///   the blocks braille is translated from; and for named cases the reader's
///   result under shallow limits on the tree's depth.
/// - **Where.** `manifest.tsv` holds one line for each document, cutting, and
///   mix: its name, a digest of its Markdown, and a digest of its record.
///   `generated.records` holds the named cases' records in full, so a
///   difference there is shown in words.
///
/// If a change to what a walk reads is meant, record again with
/// `TEXTMOUTH_RECORD_MARKDOWN_CORPUS=1` on a run of this class and review the
/// diff of `generated.records`. `TEXTMOUTH_RECORD_MARKDOWN_INPUTS=1` as well
/// imports TestData again and replaces `inputs/`; leave it out unless the
/// corpus itself is to change.
final class MarkdownWalkCorpusTests: XCTestCase {

    // MARK: - Where the Corpus Lives

    /// Whether this run records the corpus instead of comparing with it.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["TEXTMOUTH_RECORD_MARKDOWN_CORPUS"] == "1"
    }

    /// Whether a recording run also imports TestData and replaces the inputs.
    static var isRecordingInputs: Bool {
        ProcessInfo.processInfo.environment["TEXTMOUTH_RECORD_MARKDOWN_INPUTS"] == "1"
    }

    /// `TestData/markdown-corpus` of this checkout, beside the tests' folder.
    static var corpusFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData", isDirectory: true)
            .appendingPathComponent("markdown-corpus", isDirectory: true)
    }

    /// The folder of the documents' Markdown.
    static var inputsFolder: URL { corpusFolder.appendingPathComponent("inputs", isDirectory: true) }
    /// The digests of every document, cutting, and mix.
    static var manifestURL: URL { corpusFolder.appendingPathComponent("manifest.tsv") }
    /// The named cases' records, in full.
    static var recordsURL: URL { corpusFolder.appendingPathComponent("generated.records") }

    /// The extension of an input file. git ignores `*.md` and `*.txt`.
    static let inputExtension = "content"

    /// The size of the long generated document, in bytes.
    static let longDocumentBytes = 1_000_000

    /// The fewest documents `inputs/` may hold: a folder with most of its
    /// files gone cannot pass for a proof.
    static let fewestDocuments = 80

    // MARK: - The Cases

    /// The documents of `inputs/`, in the order of their names (compared by
    /// bytes, so no locale changes it), and the long generated document.
    static func documents() throws -> [MarkdownCorpusCase] {
        let names = try FileManager.default.contentsOfDirectory(atPath: inputsFolder.path)
            .filter { ($0 as NSString).pathExtension == inputExtension }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var documents = try names.map { name in
            let data = try Data(contentsOf: inputsFolder.appendingPathComponent(name))
            // Read as the cache is read: invalid UTF-8 is not a text.
            let markdown = try MarkdownCacheService.cacheText(from: data, at: inputsFolder.appendingPathComponent(name))
            return MarkdownCorpusCase(name: "doc:" + (name as NSString).deletingPathExtension, markdown: markdown)
        }
        documents.append(MarkdownCorpusCase(
            name: "doc:long generated document",
            markdown: MarkdownWalkCorpusKit.longDocument(bytes: longDocumentBytes)
        ))
        return documents
    }

    /// The damaged cuttings of every document, and the mixes.
    static func cuttingsAndMixes() throws -> [MarkdownCorpusCase] {
        try documents().flatMap { MarkdownWalkCorpusKit.cuttings(of: $0.markdown, key: $0.name) }
            + MarkdownWalkCorpusKit.mixes()
    }

    // MARK: - The Manifest

    /// One line of the manifest: the digests of a case's Markdown and of its record.
    struct Recorded: Equatable {
        let input: String
        let record: String
    }

    /// The manifest's lines by case name; empty when there is no manifest.
    static func manifest() -> [String: Recorded] {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return [:] }
        var recorded: [String: Recorded] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 3 {
                recorded[String(fields[0])] = Recorded(input: String(fields[1]), record: String(fields[2]))
            }
        }
        return recorded
    }

    /// The manifest line of `corpusCase`, read with `detail`.
    private func manifestLine(_ corpusCase: MarkdownCorpusCase, detail: MarkdownWalkCorpusKit.Detail, scratch: URL?) -> Recorded {
        Recorded(
            input: MarkdownWalkCorpusKit.digest(corpusCase.markdown),
            record: MarkdownWalkCorpusKit.digest(
                MarkdownWalkCorpusKit.record(of: corpusCase.markdown, detail: detail, scratch: scratch)
            )
        )
    }

    /// Compares each of `cases` with its line of the manifest, and fails once,
    /// naming the cases that differ (the first few, with their Markdown when
    /// it is short enough to read) and those the manifest lacks.
    private func compare(_ cases: [MarkdownCorpusCase], detail: MarkdownWalkCorpusKit.Detail, scratch: URL? = nil) {
        let recorded = Self.manifest()
        var missing: [String] = []
        var changedInputs: [String] = []
        var different: [MarkdownCorpusCase] = []
        for corpusCase in cases {
            guard let expected = recorded[corpusCase.name] else {
                missing.append(corpusCase.name)
                continue
            }
            let actual = manifestLine(corpusCase, detail: detail, scratch: scratch)
            if actual.input != expected.input {
                changedInputs.append(corpusCase.name)
            } else if actual.record != expected.record {
                different.append(corpusCase)
            }
        }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) cases are not in the manifest: \(missing.prefix(10).joined(separator: ", "))")
        XCTAssertTrue(
            changedInputs.isEmpty,
            "\(changedInputs.count) cases' Markdown is not the Markdown recorded (the corpus itself changed): "
                + changedInputs.prefix(10).joined(separator: ", ")
        )
        guard !different.isEmpty else { return }
        let shown = different.prefix(5).map { corpusCase -> String in
            let markdown = corpusCase.markdown.utf8.count <= 600 ? " " + MarkdownWalkCorpusKit.quoted(corpusCase.markdown) : ""
            return "  - \(corpusCase.name)\(markdown)"
        }.joined(separator: "\n")
        XCTFail("""
            \(different.count) of \(cases.count) Markdown texts are read or exported differently from their records:
            \(shown)
            The reading text, a heading, a page, or the exported document changed. If that is meant, record again \
            with TEXTMOUTH_RECORD_MARKDOWN_CORPUS=1 and review the diff.
            """)
    }

    // MARK: - The Named Cases' Records

    /// The details a named case is recorded with.
    static let namedDetail: MarkdownWalkCorpusKit.Detail = [.writers, .treeLimits, .readableWriters]

    /// The line that begins a named case's record.
    static func recordHeader(_ name: String) -> String { "=== \(name)" }

    /// `generated.records` as it would be written now.
    private func namedRecords(scratch: URL) -> String {
        MarkdownWalkCorpusKit.namedCases.map { corpusCase in
            Self.recordHeader(corpusCase.name) + "\n"
                + "markdown \(MarkdownWalkCorpusKit.quoted(corpusCase.markdown))\n"
                + MarkdownWalkCorpusKit.record(of: corpusCase.markdown, detail: Self.namedDetail, scratch: scratch)
        }.joined()
    }

    /// `text`, a `generated.records`, as each case's lines by its name.
    static func recordsByName(_ text: String) -> [String: [String]] {
        var records: [String: [String]] = [:]
        var name: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("=== ") {
                name = String(line.dropFirst(4))
                records[name ?? ""] = []
            } else if let name {
                records[name, default: []].append(String(line))
            }
        }
        return records
    }

    // MARK: - Tests

    /// Every document reads, and is written by every writer, as recorded.
    func testEveryDocumentReadsAndExportsAsRecorded() throws {
        try XCTSkipIf(Self.isRecording, "The corpus is being recorded")
        let documents = try Self.documents()
        XCTAssertGreaterThanOrEqual(documents.count, Self.fewestDocuments, "TestData/markdown-corpus/inputs has lost documents")
        compare(documents, detail: .writers, scratch: try makeSandboxDirectory("MarkdownCorpus"))
    }

    /// Every damaged cutting of a document, and every mix, reads and walks as recorded.
    func testEveryCuttingAndMixReadsAsRecorded() throws {
        try XCTSkipIf(Self.isRecording, "The corpus is being recorded")
        compare(try Self.cuttingsAndMixes(), detail: [])
    }

    /// Every named case's record is the one kept, line for line; a difference
    /// names the case and shows the first line that differs.
    func testEveryNamedCaseReadsAndExportsAsRecorded() throws {
        try XCTSkipIf(Self.isRecording, "The corpus is being recorded")
        let expected = Self.recordsByName(try String(contentsOf: Self.recordsURL, encoding: .utf8))
        let actual = Self.recordsByName(namedRecords(scratch: try makeSandboxDirectory("MarkdownCorpus")))
        XCTAssertEqual(
            Set(expected.keys), Set(MarkdownWalkCorpusKit.namedCases.map(\.name)),
            "generated.records must hold exactly the named cases"
        )
        var differences: [String] = []
        for corpusCase in MarkdownWalkCorpusKit.namedCases {
            let was = expected[corpusCase.name] ?? []
            let now = actual[corpusCase.name] ?? []
            guard was != now else { continue }
            // The first line that differs, or the first line one side lacks.
            let at = zip(was, now).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(was.count, now.count)
            differences.append("""
                  - \(corpusCase.name), line \(at + 1):
                      recorded: \(at < was.count ? was[at] : "(no line)")
                      now:      \(at < now.count ? now[at] : "(no line)")
                """)
        }
        XCTAssertTrue(
            differences.isEmpty,
            "\(differences.count) named cases are read or exported differently from their records:\n"
                + differences.prefix(12).joined(separator: "\n")
        )
    }

    /// The manifest names exactly the documents, cuttings, and mixes the test
    /// compares, so neither a stale line nor a case left out goes unseen, and
    /// the names of the named cases do not repeat.
    func testTheManifestNamesExactlyTheCorpus() throws {
        try XCTSkipIf(Self.isRecording, "The corpus is being recorded")
        let names = try Self.documents().map(\.name) + Self.cuttingsAndMixes().map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "case names must not repeat")
        XCTAssertEqual(Set(Self.manifest().keys), Set(names))
        let named = MarkdownWalkCorpusKit.namedCases.map(\.name)
        XCTAssertEqual(Set(named).count, named.count, "named cases must not share a name")
    }

    /// The record tells two readings apart: a text whose soft break is read as
    /// a space has another record than the same words on one line with two
    /// spaces, and another than the words run together, so a walk that reads a
    /// break differently cannot keep a record.
    func testARecordTellsReadingsApart() {
        let wrapped = MarkdownWalkCorpusKit.record(of: "one\ntwo")
        XCTAssertTrue(wrapped.contains("text \"one two\""), wrapped)
        XCTAssertNotEqual(wrapped, MarkdownWalkCorpusKit.record(of: "one  two"))
        XCTAssertNotEqual(wrapped, MarkdownWalkCorpusKit.record(of: "onetwo"))
        XCTAssertNotEqual(MarkdownWalkCorpusKit.record(of: "# A"), MarkdownWalkCorpusKit.record(of: "## A"))
        XCTAssertEqual(MarkdownWalkCorpusKit.quoted("a\"b\\c\n\u{2028}\u{0}"), "\"a\\\"b\\\\c\\n\\u{2028}\\u{0}\"")
    }

    // MARK: - Recording

    /// Records the corpus when asked (`TEXTMOUTH_RECORD_MARKDOWN_CORPUS=1`),
    /// and is skipped otherwise: first the inputs, when
    /// `TEXTMOUTH_RECORD_MARKDOWN_INPUTS=1` too, then the manifest and the
    /// named cases' records, each written whole in one step.
    func testRecordTheCorpus() throws {
        try XCTSkipUnless(Self.isRecording, "Set TEXTMOUTH_RECORD_MARKDOWN_CORPUS=1 to record the corpus")
        try FileManager.default.createDirectory(at: Self.inputsFolder, withIntermediateDirectories: true)
        if Self.isRecordingInputs {
            try recordInputs()
        }
        let scratch = try makeSandboxDirectory("MarkdownCorpus")

        let documents = try Self.documents()
        var lines = documents.map { ($0.name, manifestLine($0, detail: .writers, scratch: scratch)) }
        lines += try Self.cuttingsAndMixes().map { ($0.name, manifestLine($0, detail: [], scratch: nil)) }
        let manifest = lines.map { "\($0.0)\t\($0.1.input)\t\($0.1.record)\n" }.joined()
        try manifest.write(to: Self.manifestURL, atomically: true, encoding: .utf8)
        try namedRecords(scratch: scratch).write(to: Self.recordsURL, atomically: true, encoding: .utf8)
        print("MARKDOWN CORPUS RECORDED: \(documents.count) documents, \(lines.count) manifest lines, "
            + "\(MarkdownWalkCorpusKit.namedCases.count) named cases")
    }

    /// Imports every book, PDF, and format sample of TestData as a reader
    /// imports it and keeps the content.md each import wrote as an input, and
    /// TestData's Markdown file as it is. A document that cannot be imported,
    /// or that has no text, is named and left out.
    ///
    /// The books imported stay in the hosted tests' library for the rest of
    /// the run: a recording run runs this class alone, and the test host's
    /// sandbox is swept by the next run.
    private func recordInputs() throws {
        var sources: [(name: String, url: URL)] = try TextPipelineFixtures.testDataBookNames.map { ($0, try requireFile($0)) }
        sources += try DocumentGoldenTests.pdfNames.map { ($0, try requireFile($0)) }
        for sample in TextPipelineFixtures.formatSampleNames {
            let copy = try copyOfFormatSample(
                TextPipelineFixtures.pathInsideFormatSamples(sample),
                named: TextPipelineFixtures.formatSampleImportNames[sample]
            )
            sources.append((TextPipelineFixtures.formatSampleGoldenName(sample), copy))
        }
        var kept = 0
        for (name, url) in sources {
            do {
                let book = try FileImportService.importFileWithReport(from: url).book
                let content = try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
                try content.write(to: Self.inputURL(named: name), options: .atomic)
                kept += 1
            } catch {
                print("MARKDOWN CORPUS INPUT NOT KEPT: \(name): \(error.localizedDescription)")
            }
        }
        // The one Markdown file of TestData, as a Markdown book's importer reads it.
        try Data(contentsOf: try requireFile("sample.md")).write(to: Self.inputURL(named: "raw__sample.md"), options: .atomic)
        print("MARKDOWN CORPUS INPUTS KEPT: \(kept + 1) of \(sources.count + 1)")
    }

    /// Where the input named `name` is kept.
    private static func inputURL(named name: String) -> URL {
        inputsFolder.appendingPathComponent("\(name).\(inputExtension)")
    }
}
