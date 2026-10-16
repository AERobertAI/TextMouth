import Foundation
@testable import TextMouth

// The corpus report: what the importers made of every file in a folder, in
// plain Markdown a person reads through VoiceOver or a braille display.
//
// This file holds the report's builder (pure functions over values, tested
// with synthetic values by `CorpusReportFormatTests`) and its extension of
// `DocumentDump`. The walk that imports real files is `CorpusRunner` in
// `CorpusRunner.swift`; the opt-in test that writes a report is
// `CorpusReportTests`.
//
// The report is one fact per line: headings and bullet lists, no tables, no
// emoji, and every outcome said in a word (`imported`, `imported with
// warnings`, `refused`, `skipped`, `timed out`), never by a mark or color.

// MARK: - Dump Extension

extension DocumentDump {
    /// The format as a person names it ("EPUB", "Plain Text"), falling back
    /// to the dump's raw name for a format this build does not know.
    var displayFormat: String {
        BookFormat(rawValue: format)?.displayName ?? format
    }

    /// Whether the book has audio worth reporting: tracks, or a duration.
    var hasAudio: Bool {
        !tracks.isEmpty || (audioDuration ?? 0) > 0
    }
}

// MARK: - Values

/// What the importer made of a file it read: the dump of the book (the same
/// facts, and the same checksum, as a golden) and the opening lines of its
/// reading text.
struct CorpusFacts {
    /// The golden's facts: format, title, author, counts, headings, tracks.
    var dump: DocumentDump
    /// The first non-empty lines of the reading text, as the runner found
    /// them (the builder cuts each to a fixed length).
    var firstLines: [String]

    /// Whether the import left something out (chapters, or PDF pages whose
    /// text could not be read).
    var hasWarnings: Bool { dump.reportMessage != nil }
}

/// How a file ended: what the importer made of it, or why it made nothing.
enum CorpusOutcome {
    /// The file was imported and read back.
    case imported(CorpusFacts)
    /// The importer refused the file; the message is the failure's
    /// `localizedDescription`, verbatim.
    case refused(String)
    /// The file was never imported, for the reason given.
    case skipped(String)
    /// The import did not finish in this many seconds.
    case timedOut(seconds: Int)
}

/// One file's place in the report.
struct CorpusFileEntry {
    /// The path from the corpus folder, with `/` between components.
    var relativePath: String
    /// The format as a person names it, as the importer detects it from the
    /// file; nil when the file's kind is not one the importer knows.
    var format: String?
    var outcome: CorpusOutcome
    /// How long the import took, in seconds; nil when none was attempted.
    var importSeconds: Double?

    /// The word the report gives for how the file ended.
    var resultWord: String {
        switch outcome {
        case .imported(let facts): return facts.hasWarnings ? "imported with warnings" : "imported"
        case .refused: return "refused"
        case .skipped: return "skipped"
        case .timedOut: return "timed out"
        }
    }
}

/// What the report says about the run as a whole, besides its files.
struct CorpusReportContext {
    /// A path that must never appear in the report, and the words that
    /// stand in its place.
    struct HiddenPath {
        var path: String
        var replacement: String
    }

    /// The corpus folder's name: its last path component only.
    var folderName: String
    /// The date of the run, as `yyyy-MM-dd`.
    var date: String
    /// The macOS version, as the operating system words it.
    var macOSVersion: String
    /// The app's version and build.
    var appBuild: String
    /// Paths the importer's messages may name (the corpus folder, the
    /// sandbox the files are copied into); each is replaced by its words.
    var hiddenPaths: [HiddenPath] = []
    /// How many files the folder holds that can be read; more than the
    /// entries when the run was cut at the file limit.
    var foundCount: Int
    /// The limit that cut the run, when it did.
    var fileLimit: Int?
    /// Whether every file has been read. A report written while the run is
    /// under way says so.
    var isComplete: Bool
}

// MARK: - Builder

/// Writes the report from values. Nothing here reads a file.
enum CorpusReportBuilder {
    /// How many headings a section lists before it says how many more.
    static let headingLimit = 200
    /// How many lines of the reading text a section shows.
    static let firstLineCount = 5
    /// How many characters of a line a section shows.
    static let firstLineLength = 120
    /// The line a section gives for an Ogg file, which is never decoded.
    static let oggSkipReason = "Ogg audio is never decoded in the test host"
    /// The extensions of Ogg audio files.
    static let oggExtensions: Set<String> = ["ogg", "oga", "opus"]

    // MARK: Whole report

    /// The whole report: the title block, then one section per file.
    static func report(context: CorpusReportContext, entries: [CorpusFileEntry]) -> String {
        var lines = header(context: context, entries: entries)
        for entry in entries {
            lines.append("")
            lines += section(for: entry, context: context)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The title block: the folder's name, the date, the Mac and the app,
    /// whether the run is finished or was cut, and the counts line.
    static func header(context: CorpusReportContext, entries: [CorpusFileEntry]) -> [String] {
        var lines = ["# Corpus report", ""]
        lines.append("- Folder: \(clean(context.folderName, context))")
        lines.append("- Date: \(context.date)")
        lines.append("- macOS: \(context.macOSVersion)")
        lines.append("- App build: \(context.appBuild)")
        lines.append("- Status: " + (context.isComplete
            ? "complete"
            : "in progress, \(entries.count) of \(context.foundCount) files read so far"))
        if let limit = context.fileLimit, context.foundCount > limit {
            lines.append("- Cut: \(context.foundCount) files were found and only the first \(limit) are read (TEXTMOUTH_CORPUS_MAX_FILES)")
        }
        lines.append("")
        lines.append(countsLine(for: entries))
        return lines
    }

    /// `N files: A imported, B with warnings, C refused, D skipped`, with
    /// `, E timed out` added when any file timed out. The word is always
    /// `files`, so a script can find the line by `^[0-9]+ files:`.
    static func countsLine(for entries: [CorpusFileEntry]) -> String {
        func count(_ word: String) -> Int { entries.filter { $0.resultWord == word }.count }
        var line = "\(entries.count) files: "
        line += "\(count("imported")) imported, \(count("imported with warnings")) with warnings, "
        line += "\(count("refused")) refused, \(count("skipped")) skipped"
        let timedOut = count("timed out")
        if timedOut > 0 { line += ", \(timedOut) timed out" }
        return line
    }

    // MARK: Sections

    /// The section of one file: a heading with its relative path, then
    /// bullets, one fact each, ending with the checksum line.
    static func section(for entry: CorpusFileEntry, context: CorpusReportContext) -> [String] {
        var lines = ["## \(clean(entry.relativePath, context))"]
        lines.append("- Format: \(entry.format.map { clean($0, context) } ?? "unrecognized")")
        lines.append("- Result: \(entry.resultWord)")
        switch entry.outcome {
        case .imported(let facts):
            lines += importedLines(facts, context: context)
        case .refused(let message):
            lines.append("- Refusal: \(clean(message, context))")
        case .skipped(let reason):
            lines.append("- skipped: \(clean(reason, context))")
        case .timedOut(let seconds):
            lines.append("- Note: timed out after \(seconds) seconds; the import was left to finish in the background and its result was dropped")
        }
        if let seconds = entry.importSeconds {
            lines.append("- Import time: \(String(format: "%.1f", seconds)) seconds")
        }
        // A file with no reading text has no checksum to compare.
        if case .imported(let facts) = entry.outcome {
            lines.append("- Checksum: \(facts.dump.textChecksum)")
        } else {
            lines.append("- Checksum: none")
        }
        return lines
    }

    /// The bullets that describe what an imported book is: title, author,
    /// size, warnings, headings, opening lines, audio.
    private static func importedLines(_ facts: CorpusFacts, context: CorpusReportContext) -> [String] {
        let dump = facts.dump
        var lines = [
            "- Title: \(valueOrNone(dump.title, context))",
            "- Author: \(valueOrNone(dump.author, context))",
            "- Text length: \(dump.textLength) UTF-16 units, \(dump.wordCount) words",
            "- Chapters: \(dump.chapterCount)",
        ]
        if let message = dump.reportMessage {
            lines.append("- Warnings: \(clean(message, context))")
        }
        lines += headingLines(dump.headings, context: context)
        lines.append("- First lines:")
        let shown = facts.firstLines.prefix(firstLineCount)
        if shown.isEmpty {
            lines.append("  - (the book has no text)")
        }
        for line in shown {
            lines.append("  - \(cut(clean(line, context), to: firstLineLength))")
        }
        if dump.hasAudio {
            lines.append("- Tracks: \(dump.tracks.count)")
            lines.append("- Audio duration: \(String(format: "%.1f", dump.audioDuration ?? 0)) seconds")
        }
        return lines
    }

    /// The heading count, then a nested list of the headings with their
    /// levels, at most `headingLimit` of them and then `and N more`.
    private static func headingLines(_ headings: [DocumentDump.HeadingLine], context: CorpusReportContext) -> [String] {
        var lines = ["- Headings: \(headings.count)"]
        for heading in headings.prefix(headingLimit) {
            lines.append("  - level \(heading.level): \(clean(heading.text, context))")
        }
        if headings.count > headingLimit {
            lines.append("  - and \(headings.count - headingLimit) more")
        }
        return lines
    }

    // MARK: Text helpers

    /// `value` cleaned for the report, or `(none)` when it is empty.
    private static func valueOrNone(_ value: String, _ context: CorpusReportContext) -> String {
        let cleaned = clean(value, context)
        return cleaned.isEmpty ? "(none)" : cleaned
    }

    /// `text` as one line safe for the report: each hidden path replaced by
    /// its words, and every run of whitespace (a newline, a tab) one space.
    static func clean(_ text: String, _ context: CorpusReportContext) -> String {
        var result = text
        // The longest paths first, so a path inside another is not
        // replaced by half.
        for hidden in context.hiddenPaths.sorted(by: { $0.path.count > $1.path.count }) where !hidden.path.isEmpty {
            result = result.replacingOccurrences(of: hidden.path, with: hidden.replacement)
        }
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `text` cut to `length` characters, with `...` after a cut one.
    static func cut(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "..." : text
    }

    /// The first `count` non-empty lines of the reading text of `chapters`
    /// (the chapters' text in order), whitespace trimmed. Stops reading as
    /// soon as it has enough, so a long book is not split whole.
    static func firstLines(of chapters: [String], count: Int = firstLineCount) -> [String] {
        var found: [String] = []
        for chapter in chapters {
            for line in chapter.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                found.append(trimmed)
                if found.count == count { return found }
            }
        }
        return found
    }
}
