import AppKit
import XCTest
@testable import TextMouth

/// This Mac's recognizer measured on speech whose text is known (FR05), the
/// measurement behind TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md and the
/// cleanup rules derived from it (`TranscriptAccuracy`).
///
/// It runs only when `TEXTMOUTH_TRANSCRIPT_MEASUREMENT` (through xcodebuild,
/// `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT`) names a folder, and takes
/// minutes. It measures the DAISY fixtures this checkout keeps, a person
/// reading Fire Safety and a synthetic voice reading Are You Ready, against
/// their books' text; and each audio file in the folder's `audio` folder
/// named `<text>--<voice>.<extension>` against `texts/<text>.txt`, the text
/// it was synthesized from (with AVSpeechSynthesizer.write, never played,
/// and never in the repository). Each file's transcript is kept in the
/// folder's `transcripts` folder, so a later run measures again without
/// transcribing. The tables are written to `measurement.md` in the folder,
/// and every difference, for reading through, to `differences.json`.
///
/// The recognizer listens in US English unless
/// `TEXTMOUTH_TRANSCRIPT_MEASUREMENT_LOCALE` lists other installed
/// Englishes, such as "en-US,en-GB"; the transcripts, tables, and
/// differences of each but US English carry the locale in their names.
/// Nothing is downloaded, and nothing plays.
@MainActor
final class TranscriptAccuracyMeasurementTests: XCTestCase {

    /// Transcribes every source in each language asked for, aligns each
    /// transcript with its text, and writes the tables.
    func testMeasureTheRecognizerOnKnownText() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TEXTMOUTH_TRANSCRIPT_MEASUREMENT"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT to a folder to measure the recognizer")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let english = try await requireInstalledEnglishModel()
        let asked = (environment["TEXTMOUTH_TRANSCRIPT_MEASUREMENT_LOCALE"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for identifier in asked.isEmpty ? [english.identifier(.bcp47)] : asked {
            guard case .installed(let locale) = await TranscriptionAvailability.modelStatus(for: Locale(identifier: identifier)) else {
                throw XCTSkip("the model for \(identifier) is not installed on this Mac, and the tests never download it")
            }
            try await measure(in: folder, locale: locale)
        }
    }

    /// Measures every source with the recognizer listening in `locale`, and
    /// writes the tables and differences into `folder`.
    private func measure(in folder: URL, locale: Locale) async throws {
        let identifier = locale.identifier(.bcp47)
        let suffix = identifier == "en-US" ? "" : "-\(identifier)"
        let transcripts = folder.appendingPathComponent("transcripts\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)

        var sources = try await measureDAISYFixtures(locale: locale, transcripts: transcripts)
        sources += try await measureSynthesizedSpeech(in: folder, locale: locale, transcripts: transcripts)

        XCTAssertFalse(sources.isEmpty, "nothing was measured")
        for source in sources {
            XCTAssertFalse(source.alignment.heard.isEmpty, "\(source.name): nothing was heard")
        }
        let report = MeasurementReport(sources: sources, locale: identifier, isWord: Self.isEnglishWord)
        try report.markdown().write(to: folder.appendingPathComponent("measurement\(suffix).md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report.differenceRecords())
            .write(to: folder.appendingPathComponent("differences\(suffix).json"), options: .atomic)
        print("MEASUREMENT: \(sources.count) sources in \(identifier), written to \(folder.path)/measurement\(suffix).md")
    }

    /// Whether `word` is an English word, in American or British spelling,
    /// as the system's spelling checker knows them.
    static func isEnglishWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        return ["en_US", "en_GB"].contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
    }

    // MARK: - The Sources

    /// The DAISY fixtures this checkout keeps, each imported as the library
    /// imports an audio DAISY book, its files transcribed in the order the
    /// book plays them, and scored against the book's own text.
    private func measureDAISYFixtures(locale: Locale, transcripts: URL) async throws -> [MeasuredSource] {
        let fixtures = [
            (archive: TranscriptionFixtureTests.fireSafety, name: "Fire Safety", group: MeasuredSource.Group.person),
            (archive: TranscriptionFixtureTests.areYouReady, name: "Are You Ready", group: .daisySynthetic),
        ]
        var measured: [MeasuredSource] = []
        let world = try makeIntegrationWorld("Transcript Measurement")
        for fixture in fixtures {
            let archive = URL(fileURLWithPath: testFilePath(fixture.archive))
            guard FileManager.default.fileExists(atPath: archive.path) else {
                print("MEASUREMENT: \(fixture.archive) is not in this checkout's TestData; left out")
                continue
            }
            // The book's text, as TextMouth reads a DAISY book's text, and
            // its audio, as it imports the book as an audiobook.
            let text = try await OffMainWork.runThrowing { try DAISYParser.parse(url: archive).allText }
            let folder = world.folder.path
            let book = try await OffMainWork.runThrowing {
                try FileImportService.importDAISYAudioZipWithReport(from: archive, toFolder: folder).book
            }
            let plan = try await OffMainWork.runThrowing { try TranscriptionPlan.make(for: book) }
            var sentences: [TranscriptSentence] = []
            for (number, file) in plan.files.enumerated() {
                let cache = transcripts.appendingPathComponent("\(fixture.archive)-\(number).json")
                sentences += try await transcribe(file.url, in: locale, keptIn: cache)
            }
            measured.append(MeasuredSource(
                name: fixture.name,
                text: fixture.name,
                group: fixture.group,
                book: fixture.name,
                voice: fixture.group == .person ? "Tony Porter" : "TPB Narrator",
                audioSeconds: plan.totalDuration,
                alignment: TranscriptAccuracy.align(
                    heard: TranscriptAccuracy.words(heardIn: sentences),
                    written: TranscriptAccuracy.words(in: text)
                )
            ))
        }
        return measured
    }

    /// Each audio file in `folder`'s `audio` folder, named
    /// `<text>--<voice>.<extension>`, transcribed and scored against
    /// `texts/<text>.txt`, in the order of their names.
    private func measureSynthesizedSpeech(in folder: URL, locale: Locale, transcripts: URL) async throws -> [MeasuredSource] {
        let audioFolder = folder.appendingPathComponent("audio", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: audioFolder.path)) ?? []
        var measured: [MeasuredSource] = []
        for name in names.sorted() where ["m4a", "wav", "caf", "aiff"].contains((name as NSString).pathExtension) {
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.components(separatedBy: "--")
            guard parts.count == 2 else { continue }
            let textURL = folder.appendingPathComponent("texts", isDirectory: true).appendingPathComponent("\(parts[0]).txt")
            let text = try String(contentsOf: textURL, encoding: .utf8)
            let audio = audioFolder.appendingPathComponent(name)
            let sentences = try await transcribe(audio, in: locale, keptIn: transcripts.appendingPathComponent("\(stem).json"))
            let seconds = try await OffMainWork.runThrowing { try TranscriptionPlan.duration(ofAudioFileAt: audio) }
            let book = parts[0].components(separatedBy: "-").first ?? parts[0]
            measured.append(MeasuredSource(
                name: stem,
                text: parts[0],
                group: .voice(parts[1].capitalized),
                book: book.capitalized,
                voice: parts[1].capitalized,
                audioSeconds: seconds,
                alignment: TranscriptAccuracy.align(
                    heard: TranscriptAccuracy.words(heardIn: sentences),
                    written: TranscriptAccuracy.words(in: text)
                )
            ))
        }
        return measured
    }

    /// The sentences this Mac's engine hears in `audio`, in `locale`: those
    /// kept at `cache` by an earlier run, or transcribed now and kept there.
    private func transcribe(_ audio: URL, in locale: Locale, keptIn cache: URL) async throws -> [TranscriptSentence] {
        if let kept = try? Data(contentsOf: cache),
           let sentences = try? JSONDecoder().decode([TranscriptSentence].self, from: kept) {
            return sentences
        }
        let engine = SystemTranscriptionEngine()
        let model = try await engine.prepare(locale: locale)
        let sentences = try await engine.transcribe(fileAt: audio, locale: Locale(identifier: model.locale)) { _ in }
        try JSONEncoder().encode(sentences).write(to: cache, options: .atomic)
        return sentences
    }
}

// MARK: - What Was Measured

/// One transcript measured against its known text.
struct MeasuredSource {
    /// Who or what read a source aloud.
    enum Group: Hashable, Comparable {
        /// A person: the narrator of Fire Safety.
        case person
        /// The synthetic voice of Are You Ready, made for its DAISY book.
        case daisySynthetic
        /// A system voice, by name, reading public-domain chapters.
        case voice(String)

        /// The group's name in a table.
        var title: String {
            switch self {
            case .person: return "Person (Fire Safety)"
            case .daisySynthetic: return "TPB Narrator (Are You Ready)"
            case .voice(let name): return "\(name) (synthesized)"
            }
        }
    }

    /// The source's name: the fixture's title, or the audio file's.
    let name: String
    /// The name of the known text it reads, which two voices reading one
    /// text share.
    let text: String
    /// Who read it.
    let group: Group
    /// The book it comes from.
    let book: String
    /// The voice that read it.
    let voice: String
    /// How long its audio plays.
    let audioSeconds: TimeInterval
    /// Its transcript aligned with its text.
    let alignment: TranscriptAccuracy.Alignment
}

// MARK: - The Tables

/// The measurement's tables, in Markdown: the word error rate of each
/// source and group, the kinds of mistake, the differences found most
/// often, how the recognizer's confidence bears on mistakes, the matched
/// words written differently, and the corrections that would have been
/// right everywhere they apply. On the main actor, where the spelling
/// checker that judges words is.
@MainActor
struct MeasurementReport {
    /// What was measured.
    let sources: [MeasuredSource]
    /// The language the recognizer listened in.
    let locale: String
    /// Whether a word is an English word.
    let isWord: @MainActor (String) -> Bool

    /// The groups, a person first, each with its tally.
    private var groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)] {
        Dictionary(grouping: sources, by: \.group)
            .map { group, members in (group, tally(of: members)) }
            .sorted { $0.group < $1.group }
    }

    /// The tally of `members`.
    private func tally(of members: [MeasuredSource]) -> TranscriptAccuracy.Tally {
        var tally = TranscriptAccuracy.Tally()
        for member in members {
            tally.add(member.alignment)
        }
        return tally
    }

    /// The whole report.
    func markdown() -> String {
        let groups = self.groups
        let synthetic = tally(of: sources.filter { $0.group != .person })
        let everything = tally(of: sources)
        var lines: [String] = ["# Transcript accuracy measurement", "", "Recognizer locale: \(locale).", ""]
        lines += sourceTable()
        lines += groupTable(groups, synthetic: synthetic, everything: everything)
        lines += classTable(groups.map { (title: $0.group.title, tally: $0.tally) } + [(title: "All synthetic", tally: synthetic)])
        lines += frequentTable("Substitutions (heard → written)", kind: .substitution, groups: groups, everything: everything)
        lines += frequentTable("Deletions (written, not heard)", kind: .deletion, groups: groups, everything: everything)
        lines += frequentTable("Insertions (heard, not written)", kind: .insertion, groups: groups, everything: everything)
        lines += confidenceTable(groups)
        lines += surfaceTable(groups)
        lines += likenessTable(groups)
        lines += candidateTable()
        lines += heldOutTable()
        return lines.joined(separator: "\n") + "\n"
    }

    /// How the corrections always right in every book but one fare in that
    /// one: of them, how many it hears the pattern of at all, and how many
    /// times they would be right and wrong there.
    private func heldOutTable() -> [String] {
        let measurement = { (source: MeasuredSource) in
            TranscriptAccuracy.Measurement(source: source.name, text: source.text, alignment: source.alignment)
        }
        var lines = [
            "## Corrections from the other books, tried on each", "",
            "| Book held out | Always right in the others | Heard in this book | Times right | Times wrong | Wrong, for example |",
            "|---|---:|---:|---:|---:|---|",
        ]
        for book in Set(sources.map(\.book)).sorted() {
            let learned = TranscriptAccuracy.ruleCandidates(sources.filter { $0.book != book }.map(measurement))
                .filter(\.wasAlwaysRight)
            let tried = TranscriptAccuracy.tallied(learned, over: sources.filter { $0.book == book }.map(measurement))
                .filter { $0.fixes + $0.conflicts > 0 }
            let right = tried.reduce(0) { $0 + $1.fixes }
            let wrong = tried.reduce(0) { $0 + $1.conflicts }
            let examples = tried.filter { $0.conflicts > 0 }.prefix(4).map { "\($0.pattern) → \($0.replacement)" }
            lines.append("| \(book) | \(learned.count) | \(tried.count) | \(right) | \(wrong) | "
                + "\(Self.cell(examples.joined(separator: "; "))) |")
        }
        return lines + [""]
    }

    /// Each source's word error rate.
    private func sourceTable() -> [String] {
        var lines = [
            "## Sources", "",
            "| Source | Voice | Audio (min) | Words | WER | WER without passages | Substitutions | Deletions | Insertions |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
        for source in sources {
            var tally = TranscriptAccuracy.Tally()
            tally.add(source.alignment)
            lines.append("| \(source.name) | \(source.voice) | \(Self.minutes(source.audioSeconds)) | \(tally.writtenWords) | "
                + "\(Self.percent(tally.wordErrorRate)) | \(Self.percent(tally.wordErrorRateWithoutPassages)) | "
                + "\(tally.substitutions) | \(tally.deletions) | \(tally.insertions) |")
        }
        return lines + [""]
    }

    /// Each group's word error rate.
    private func groupTable(
        _ groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)],
        synthetic: TranscriptAccuracy.Tally,
        everything: TranscriptAccuracy.Tally
    ) -> [String] {
        var lines = [
            "## Groups", "",
            "| Group | Words | WER | WER without passages | Substitutions | Deletions | Insertions |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        let rows = groups.map { ($0.group.title, $0.tally) } + [("All synthetic", synthetic), ("Everything", everything)]
        for (title, tally) in rows {
            lines.append("| \(title) | \(tally.writtenWords) | \(Self.percent(tally.wordErrorRate)) | "
                + "\(Self.percent(tally.wordErrorRateWithoutPassages)) | \(tally.substitutions) | \(tally.deletions) | \(tally.insertions) |")
        }
        return lines + [""]
    }

    /// Word errors by kind of mistake, for each group, titled, as counts and
    /// shares of the group's errors.
    private func classTable(_ groups: [(title: String, tally: TranscriptAccuracy.Tally)]) -> [String] {
        var lines = [
            "## Word errors by kind", "",
            "| Kind | " + groups.map(\.title).joined(separator: " | ") + " |",
            "|---|" + String(repeating: "---:|", count: groups.count),
        ]
        for errorClass in TranscriptAccuracy.ErrorClass.allCases {
            let cells = groups.map { group -> String in
                let count = group.tally.errorsByClass[errorClass] ?? 0
                let share = group.tally.errors == 0 ? 0 : Double(count) / Double(group.tally.errors)
                return "\(count) (\(Self.percent(share)))"
            }
            lines.append("| \(errorClass.title) | " + cells.joined(separator: " | ") + " |")
        }
        return lines + [""]
    }

    /// The differences of `kind` found most often, with each group's count.
    private func frequentTable(
        _ title: String,
        kind: TranscriptAccuracy.Difference.Kind,
        groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)],
        everything: TranscriptAccuracy.Tally
    ) -> [String] {
        var lines = [
            "## Most frequent: \(title)", "",
            "| Heard | Written | All | " + groups.map(\.group.title).joined(separator: " | ") + " | Kind |",
            "|---|---|---:|" + String(repeating: "---:|", count: groups.count) + "---|",
        ]
        for (pair, count) in everything.mostFrequent(kind, limit: 30) {
            let cells = groups.map { "\($0.tally.pairs[pair] ?? 0)" }
            let kindTitle = everything.pairClasses[pair]?.title ?? ""
            lines.append("| \(Self.cell(pair.heard)) | \(Self.cell(pair.written)) | \(count) | "
                + cells.joined(separator: " | ") + " | \(kindTitle) |")
        }
        return lines + [""]
    }

    /// How the recognizer's confidence bears on its mistakes, by group.
    private func confidenceTable(_ groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)]) -> [String] {
        var lines = ["## Confidence and mistakes", ""]
        for (group, tally) in groups {
            let total = tally.confidence.reduce(0) { $0 + $1.words }
            guard total > 0 else { continue }
            let errors = tally.confidence.reduce(0) { $0 + $1.errors }
            lines += [
                "### \(group.title)", "",
                "| Confidence | Words heard | Share of words | Wrong | Wrong in the band | Share of all wrong |",
                "|---|---:|---:|---:|---:|---:|",
            ]
            for band in tally.confidence {
                let upper = band.upTo >= 1 ? "1" : String(format: "%.2f", band.upTo)
                let range = band.upTo >= 1 ? "\(String(format: "%.2f", band.from)) to \(upper)" : "\(String(format: "%.2f", band.from)) to under \(upper)"
                lines.append("| \(range) | \(band.words) | \(Self.percent(Double(band.words) / Double(total))) | \(band.errors) | "
                    + "\(Self.percent(band.errorRate)) | \(Self.percent(errors == 0 ? 0 : Double(band.errors) / Double(errors))) |")
            }
            lines.append("")
        }
        return lines
    }

    /// Matched words written differently, by group.
    private func surfaceTable(_ groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)]) -> [String] {
        var lines = [
            "## Matched words written differently", "",
            "| Group | Matched words | Case differs | Ending punctuation differs |",
            "|---|---:|---:|---:|",
        ]
        for (group, tally) in groups {
            let matched = max(1, tally.surface.matched)
            lines.append("| \(group.title) | \(tally.surface.matched) | \(tally.surface.casing) "
                + "(\(Self.percent(Double(tally.surface.casing) / Double(matched)))) | \(tally.surface.punctuation) "
                + "(\(Self.percent(Double(tally.surface.punctuation) / Double(matched)))) |")
        }
        return lines + [""]
    }

    /// How alike each group's mistakes are to the person's: of the person's
    /// substitutions, how many the group made too, and how alike the
    /// shares of each kind of mistake are.
    private func likenessTable(_ groups: [(group: MeasuredSource.Group, tally: TranscriptAccuracy.Tally)]) -> [String] {
        guard let person = groups.first(where: { $0.group == .person })?.tally else { return [] }
        let personPairs = Set(person.pairs.keys)
        var lines = [
            "## Likeness to the person's mistakes", "",
            "| Group | The person's differences also found | Shares of kinds, overlap |",
            "|---|---:|---:|",
        ]
        for (group, tally) in groups where group != .person {
            let shared = personPairs.filter { tally.pairs[$0] != nil }.count
            // The overlap of two distributions: the sum of the smaller share
            // of each kind, passages left out; 100% means the same shares.
            let kinds = TranscriptAccuracy.ErrorClass.allCases.filter { $0 != .passage }
            let share = { (tally: TranscriptAccuracy.Tally, kind: TranscriptAccuracy.ErrorClass) -> Double in
                let total = kinds.reduce(0) { $0 + (tally.errorsByClass[$1] ?? 0) }
                return total == 0 ? 0 : Double(tally.errorsByClass[kind] ?? 0) / Double(total)
            }
            let overlap = kinds.reduce(0.0) { $0 + min(share(person, $1), share(tally, $1)) }
            lines.append("| \(group.title) | \(shared) of \(personPairs.count) | \(Self.percent(overlap)) |")
        }
        return lines + [""]
    }

    /// The corrections the measurements suggest: those right every time,
    /// whether their pattern's words are English words, and which pass as
    /// TextMouth's own rules (`TranscriptAccuracy.conservativeRules`); then
    /// those found more than once that would also have been wrong.
    private func candidateTable() -> [String] {
        let candidates = TranscriptAccuracy.ruleCandidates(sources.map {
            TranscriptAccuracy.Measurement(source: $0.name, text: $0.text, alignment: $0.alignment)
        })
        // Each word of the patterns judged once, here on the main actor.
        let words = Set(candidates.flatMap { $0.pattern.split(separator: " ").map(String.init) })
        let english = Set(words.filter(isWord))
        let kept = Set(TranscriptAccuracy.conservativeRules(candidates) { english.contains($0) }.map(\.pattern))
        var lines = [
            "## Corrections right in every place they apply", "",
            "Places counts each place of a known text once, however many voices read it.", "",
            "| Heard | Written | Places | Times heard | Voices | Kind | Heard words all English | Kept as a rule |",
            "|---|---|---:|---:|---:|---|---|---|",
        ]
        for candidate in candidates where candidate.wasAlwaysRight {
            let allEnglish = candidate.pattern.split(separator: " ").allSatisfy { english.contains(String($0)) }
            lines.append("| \(Self.cell(candidate.pattern)) | \(Self.cell(candidate.replacement)) | \(candidate.evidence) | "
                + "\(candidate.fixes) | \(candidate.sources.count) | \(candidate.errorClass.title) | \(allEnglish ? "yes" : "no") | "
                + "\(kept.contains(candidate.pattern) ? "yes" : "no") |")
        }
        lines += [
            "", "## Corrections found more than once that would also have been wrong", "",
            "| Heard | Written | Times right | Times wrong | Kind |",
            "|---|---|---:|---:|---|",
        ]
        for candidate in candidates where !candidate.wasAlwaysRight && candidate.fixes > 1 {
            lines.append("| \(Self.cell(candidate.pattern)) | \(Self.cell(candidate.replacement)) | \(candidate.fixes) | "
                + "\(candidate.conflicts) | \(candidate.errorClass.title) |")
        }
        return lines + [""]
    }

    // MARK: Every Difference

    /// One difference, for reading through them all: where it was found,
    /// its kind, what was heard and written, how sure the recognizer was of
    /// each word heard, and the written words around it.
    struct DifferenceRecord: Codable {
        let source: String
        let group: String
        let kind: String
        let errorClass: String
        let heard: String
        let written: String
        let confidences: [Double?]
        let before: String
        let after: String
    }

    /// Every difference of every source, in order.
    func differenceRecords() -> [DifferenceRecord] {
        sources.flatMap { source -> [DifferenceRecord] in
            let alignment = source.alignment
            return alignment.differences.map { difference in
                let context = 5
                let before = alignment.written[max(0, difference.written.lowerBound - context)..<difference.written.lowerBound]
                let afterEnd = min(alignment.written.count, difference.written.upperBound + context)
                let after = alignment.written[difference.written.upperBound..<afterEnd]
                return DifferenceRecord(
                    source: source.name,
                    group: source.group.title,
                    kind: difference.kind.rawValue,
                    errorClass: TranscriptAccuracy.errorClass(of: difference, in: alignment).rawValue,
                    heard: difference.heard.map { alignment.heard[$0].text }.joined(separator: " "),
                    written: difference.written.map { alignment.written[$0].text }.joined(separator: " "),
                    confidences: difference.heard.map { alignment.heard[$0].confidence },
                    before: before.map(\.text).joined(separator: " "),
                    after: after.map(\.text).joined(separator: " ")
                )
            }
        }
    }

    // MARK: Formatting

    /// `fraction` as a percent with one decimal.
    private static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// `seconds` in minutes with one decimal.
    private static func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds / 60)
    }

    /// `text` safe in a table cell: "(none)" for nothing, and no "|".
    private static func cell(_ text: String) -> String {
        text.isEmpty ? "(none)" : text.replacingOccurrences(of: "|", with: "\\|")
    }
}
