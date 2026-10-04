import XCTest
@testable import TextMouth

/// The experimental transcript cleanup (FR05): rules applied to a scripted
/// transcript's sentences (`TranscriptCleanup`), and the rule file's layout
/// and validation (`TranscriptCleanupRuleSet`). The narration is invented,
/// so a log line quoting it would stand out.
final class TranscriptCleanupTests: XCTestCase {

    // MARK: - Whole Words

    /// A whole-word rule matches in any case and with any apostrophe, keeps
    /// the punctuation around the words, and writes its replacement in the
    /// case the sentence wrote the match in.
    func testAWholeWordRuleKeepsPunctuationAndCase() {
        let cleanup = TranscriptCleanup(rules: [rule("alright", "all right")])

        XCTAssertEqual(cleanup.cleaned("“Alright,” she said.").text, "“All right,” she said.")
        XCTAssertEqual(cleanup.cleaned("It was alright; then ALRIGHT.").text, "It was all right; then ALL RIGHT.")
        XCTAssertEqual(cleanup.cleaned("It was alright; then ALRIGHT.").corrections, [2])
        XCTAssertEqual(cleanup.cleaned("Downright alrighty.").text, "Downright alrighty.", "no whole word matched")
    }

    /// A rule of several words matches them only when nothing but a space
    /// stands between them.
    func testARuleOfSeveralWordsMatchesThemSideBySide() {
        let cleanup = TranscriptCleanup(rules: [rule("rabbit hole", "rabbit-hole")])

        XCTAssertEqual(cleanup.cleaned("Down the rabbit hole, at last.").text, "Down the rabbit-hole, at last.")
        XCTAssertEqual(cleanup.cleaned("A rabbit, hole and all.").text, "A rabbit, hole and all.")
        XCTAssertEqual(cleanup.cleaned("Rabbit Hole!").text, "Rabbit-hole!")
    }

    /// A whole-word rule's last word also matches the word with a
    /// possessive ending, which stays, as a rule for a name must; the
    /// contraction of a small word is no possessive.
    func testAWholeWordRuleKeepsAPossessiveEnding() {
        let names = TranscriptCleanup(rules: [rule("Bennett", "Bennet"), rule("Miss Lizzie", "Miss Lizzy")])
        let small = TranscriptCleanup(rules: [rule("it", "this")])

        XCTAssertEqual(names.cleaned("Mr. Bennett's daughters met Miss Lizzie’s friend.").text,
                       "Mr. Bennet's daughters met Miss Lizzy’s friend.")
        XCTAssertEqual(names.cleaned("BENNETT'S HOUSE").text, "BENNET'S HOUSE")
        XCTAssertEqual(names.cleaned("Bennetts and Lizzies.").text, "Bennetts and Lizzies.")
        XCTAssertEqual(small.cleaned("It's late, and it rang.").text, "It's late, and this rang.")
        XCTAssertEqual(
            TranscriptCleanupFixtures.rule("Bennet", "Bennet's").validationFailure(),
            "replacement holds the pattern itself, so every cleanup would change it again"
        )
    }

    /// Apostrophes match whichever way they are written, and a word's core
    /// keeps its own.
    func testApostrophesMatchEitherWay() {
        let cleanup = TranscriptCleanup(rules: [rule("shan't", "shall not")])

        XCTAssertEqual(cleanup.cleaned("I shan’t go.").text, "I shall not go.")
        XCTAssertEqual(cleanup.cleaned("I shan't go.").text, "I shall not go.")
    }

    // MARK: - Letters Inside Words

    /// A rule matching inside words replaces its letters wherever they
    /// stand, in the case they were written.
    func testARuleMatchingInsideWordsReplacesLetters() {
        let cleanup = TranscriptCleanup(rules: [TranscriptCleanupRule(
            pattern: "neighbor", replacement: "neighbour", wholeWord: false, evidence: 0, note: nil
        )])

        let cleaned = cleanup.cleaned("Neighbors and neighborhoods.")
        XCTAssertEqual(cleaned.text, "Neighbours and neighbourhoods.")
        XCTAssertEqual(cleaned.corrections, [2])
    }

    // MARK: - Rules in Order

    /// The rules apply in order, each to what the ones before it left, and
    /// each counts its own corrections, with an example of them.
    func testRulesApplyInOrderEachCountingItsOwn() {
        let cleanup = TranscriptCleanup(rules: [rule("tolled", "told"), rule("told", "said"), rule("ferry", "ferry boat")])

        let cleaned = cleanup.cleaned("The keeper tolled us twice and told us once.")

        XCTAssertEqual(cleaned.text, "The keeper said us twice and said us once.")
        XCTAssertEqual(cleaned.corrections, [1, 2, 0])
        XCTAssertEqual(cleaned.examples[0], [TranscriptCleanup.Example(
            before: "The keeper tolled us twice and told…",
            after: "The keeper told us twice and told…"
        )])
        XCTAssertTrue(cleaned.examples[2].isEmpty)
    }

    /// A sentence no rule changes comes back exactly as it was, spaces and
    /// all; a sentence a rule changes is single-spaced.
    func testAnUnchangedSentenceComesBackAsItWas() {
        let cleanup = TranscriptCleanup(rules: [rule("quillwort", "quill-wort")])

        XCTAssertEqual(cleanup.cleaned("Tide  tables hang.").text, "Tide  tables hang.")
        XCTAssertEqual(cleanup.cleaned("Quillwort  grows.").text, "Quill-wort grows.")
    }

    /// An example shows a few words around the change, with "…" where
    /// words were left out.
    func testAnExampleShowsTheWordsAroundTheChange() {
        let cleanup = TranscriptCleanup(rules: [rule("alright", "all right")])

        let example = cleanup.cleaned("One two three four five six alright seven eight nine ten eleven.").examples[0].first

        XCTAssertEqual(example?.before, "…three four five six alright seven eight nine ten…")
        XCTAssertEqual(example?.after, "…three four five six all right seven eight nine ten…")
    }

    // MARK: - A Transcript

    /// A transcript's preview rewrites each sentence a rule changes, keeping
    /// its time and dropping its words' timings, leaves every other
    /// sentence as it was, words and all, and counts corrections by rule
    /// and changed sentences; the cleaned transcript is valid.
    func testAPreviewRewritesTheSentencesTheRulesChange() {
        let transcript = TranscriptFixtures.transcript([
            (path: "01.wav", duration: 9_000, sentences: [
                TranscriptFixtures.sentence("The pier was alright at dawn.", from: 0, to: 2_400),
                TranscriptFixtures.sentence("Tide tables hang in the office.", from: 2_400, to: 5_100),
                TranscriptFixtures.sentence("Alright, the pier again.", from: 5_100, to: 6_960),
            ]),
        ])
        let cleanup = TranscriptCleanup(rules: [rule("alright", "all right"), rule("pier", "jetty"), rule("gull", "gannet")])

        let preview = cleanup.preview(of: transcript)

        XCTAssertEqual(preview.original, transcript)
        XCTAssertEqual(preview.corrections, 4)
        XCTAssertEqual(preview.changedSentences, 2)
        XCTAssertEqual(preview.changes.map(\.rule.pattern), ["alright", "pier"])
        XCTAssertEqual(preview.changes.map(\.corrections), [2, 2])
        XCTAssertEqual(preview.changes[0].examples.count, 2)
        let sentences = preview.cleaned.files[0].sentences
        XCTAssertEqual(sentences.map(\.text), [
            "The jetty was all right at dawn.", "Tide tables hang in the office.", "All right, the jetty again.",
        ])
        XCTAssertEqual(sentences.map(\.startMilliseconds), [0, 2_400, 5_100])
        XCTAssertEqual(sentences.map(\.endMilliseconds), [2_400, 5_100, 6_960])
        XCTAssertEqual(sentences.map(\.words.isEmpty), [true, false, true])
        XCTAssertEqual(sentences[1], transcript.files[0].sentences[1])
        XCTAssertNil(preview.cleaned.validationFailure())
        XCTAssertNil(preview.cleaned.cleanedUp, "a preview records no cleanup")
    }

    /// Rules that change nothing leave the transcript as it was.
    func testAPreviewOfNoChangeLeavesTheTranscript() {
        let transcript = TranscriptFixtures.twoFiles
        let preview = TranscriptCleanup(rules: [rule("gull", "gannet")]).preview(of: transcript)

        XCTAssertEqual(preview.cleaned, transcript)
        XCTAssertEqual(preview.corrections, 0)
        XCTAssertEqual(preview.changedSentences, 0)
        XCTAssertTrue(preview.changes.isEmpty)
    }

    /// A sentence rewritten keeps its time and drops its words' timings; the
    /// same text changes nothing.
    func testRewritingASentenceDropsItsWordsOnlyWhenItsTextChanges() {
        var sentence = TranscriptFixtures.sentence("Gulls circle the quay.", from: 100, to: 1_900)
        let original = sentence

        sentence.rewrite(as: "Gulls circle the quay.")
        XCTAssertEqual(sentence, original)

        sentence.rewrite(as: "Gulls circle the jetty.")
        XCTAssertEqual(sentence.text, "Gulls circle the jetty.")
        XCTAssertTrue(sentence.words.isEmpty)
        XCTAssertEqual(sentence.startMilliseconds, 100)
        XCTAssertEqual(sentence.endMilliseconds, 1_900)
    }

    // MARK: - The Rule File

    /// A rule file is read with its fields' defaults, its words single
    /// spaced, and its day named in the user's words.
    func testARuleFileIsReadWithItsDefaults() throws {
        let rules = try TranscriptCleanupRuleSet.decoded(Data("""
        {"version": 3, "date": "2026-10-04",
         "rules": [{"pattern": "  rabbit   hole ", "replacement": "rabbit-hole"},
                   {"pattern": "colour", "replacement": "color", "wholeWord": false, "evidence": 4, "note": "Spelling."}]}
        """.utf8))

        XCTAssertEqual(rules.format, 1)
        XCTAssertEqual(rules.version, 3)
        XCTAssertEqual(rules.rules.map(\.pattern), ["rabbit hole", "colour"])
        XCTAssertEqual(rules.rules.map(\.wholeWord), [true, false])
        XCTAssertEqual(rules.rules.map(\.evidence), [0, 4])
        XCTAssertEqual(rules.rules.map(\.note), [nil, "Spelling."])
        XCTAssertEqual(rules.dayName, Date(timeIntervalSince1970: 1_791_072_000).formatted(
            Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        ))
    }

    /// A rule file that can't be used says why, naming the field and never
    /// quoting a rule.
    func testAnUnusableRuleFileSaysWhy() {
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "", "replacement": "x"}]}"#),
                       "rules[0].pattern is empty")
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "--", "replacement": "x"}]}"#),
                       "rules[0].pattern holds no letter or figure")
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "quay --", "replacement": "x"}]}"#),
                       "rules[0].pattern holds a word with no letter or figure, which no whole word matches")
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "quay", "replacement": " "}]}"#),
                       "rules[0].replacement is empty")
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "quay", "replacement": "the quay"}]}"#),
                       "rules[0].replacement holds the pattern itself, so every cleanup would change it again")
        XCTAssertEqual(reason(#"{"version": 1, "date": "2026-10-04", "rules": [{"pattern": "quay", "replacement": "key", "evidence": -1}]}"#),
                       "rules[0].evidence is -1, below 0")
        XCTAssertEqual(reason(#"{"format": 2, "version": 1, "date": "2026-10-04", "rules": []}"#),
                       "format 2 is not the supported 1")
        XCTAssertEqual(reason(#"{"version": 0, "date": "2026-10-04", "rules": []}"#), "version is 0, below 1")
        XCTAssertEqual(reason(#"{"version": 1, "date": "October", "rules": []}"#), "date is not a day written as 2026-10-04")
        XCTAssertEqual(reason(#"{"version": 1, "rules": []}"#), "date is missing")
        XCTAssertEqual(reason("not json"), "it is not valid JSON")
    }

    // MARK: - Helpers

    /// A whole-word rule writing its replacement for its pattern.
    private let rule = TranscriptCleanupFixtures.rule

    /// Why the rule file `json` can't be used, or nil when it can.
    private func reason(_ json: String) -> String? {
        do {
            _ = try TranscriptCleanupRuleSet.decoded(Data(json.utf8))
            return nil
        } catch {
            return (error as? TranscriptCleanupRuleSet.Unusable)?.reason ?? "\(error)"
        }
    }
}

// MARK: - Fixtures

/// What the cleanup's tests share (FR05): rules written briefly, rules that
/// change the transcription tests' scripted narration, and a book
/// transcribed with that narration.
enum TranscriptCleanupFixtures {
    /// A whole-word rule writing `replacement` for `pattern`, right in two
    /// places.
    static func rule(_ pattern: String, _ replacement: String) -> TranscriptCleanupRule {
        TranscriptCleanupRule(pattern: pattern, replacement: replacement, wholeWord: true, evidence: 2, note: nil)
    }

    /// Rules, version 4 of October 4, 2026, that change two sentences of the
    /// scripted narration (`TranscriptionUIScripts.twoTracks`): "breakwater"
    /// and "pier", one correction each.
    static let narrationRules = TranscriptCleanupRuleSet(
        version: 4,
        date: "2026-10-04",
        rules: [rule("breakwater", "break-water"), rule("pier", "jetty")]
    )

    /// A silent audiobook titled `title`, of two tracks in `world`, last read
    /// at `savedPosition`, transcribed with the scripted narration and
    /// installed as its text, and its transcript.
    @MainActor
    static func transcribedBook(
        in world: IntegrationWorld,
        title: String = "Breakwater Notes",
        savedPosition: ReadingPosition? = nil
    ) throws -> (book: Book, transcript: Transcript) {
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [3, 2], savedPosition: savedPosition)
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks)
        try TranscriptStore.install(transcript, for: book)
        return (book, transcript)
    }
}
