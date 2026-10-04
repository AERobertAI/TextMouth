import XCTest
@testable import TextMouth

/// Measuring a transcript against the text read aloud (FR05,
/// `TranscriptAccuracy`), on small invented cases: the words compared, the
/// alignment and its word errors, the kinds of mistake, the matched words
/// written differently, the recognizer's confidence, the tallies, and the
/// corrections that were right in every place they apply.
final class TranscriptAccuracyTests: XCTestCase {

    // MARK: - Words

    /// The known text splits at spaces and at em and en dashes, leaves out
    /// what is only punctuation, and knows where sentences begin: at the
    /// start, after a full stop that is no title, and at a quotation.
    func testTheKnownTextSplitsIntoWordsAndSentences() {
        let words = TranscriptAccuracy.words(in: "“My dear Mr. Bennet,” said his lady—“have you heard?” * Then she went.\nNext line")

        XCTAssertEqual(words.map(\.key), ["my", "dear", "mr", "bennet", "said", "his", "lady", "have", "you", "heard", "then", "she", "went", "next", "line"])
        XCTAssertEqual(words.filter(\.startsSentence).map(\.key), ["my", "have", "then", "next"])
        XCTAssertEqual(words[3].text, "Bennet,”")
        XCTAssertNil(words[0].confidence)
    }

    /// Words are compared in lower case, without the punctuation at either
    /// end, and with every apostrophe straight.
    func testWordsAreComparedWithoutCasePunctuationOrCurlyApostrophes() {
        XCTAssertEqual(TranscriptAccuracy.key(of: "I’m"), "i'm")
        XCTAssertEqual(TranscriptAccuracy.key(of: "“Rabbit-Hole!”"), "rabbit-hole")
        XCTAssertEqual(TranscriptAccuracy.key(of: "don\u{02BC}t"), "don't")
    }

    /// The words heard come from the transcript's timed words, each with
    /// its confidence, and each sentence's first word begins a sentence; a
    /// sentence without timed words gives its runs between spaces.
    func testTheHeardWordsComeWithTheirConfidence() {
        let untimed = TranscriptSentence(text: "Gulls circle.", startMilliseconds: 2_000, endMilliseconds: 3_000, words: [])
        let heard = TranscriptAccuracy.words(heardIn: [
            TranscriptFixtures.sentence("The ferry docks at noon.", from: 0, to: 2_000),
            untimed,
        ])

        XCTAssertEqual(heard.map(\.key), ["the", "ferry", "docks", "at", "noon", "gulls", "circle"])
        XCTAssertEqual(heard.map(\.confidence), [0.9, 0.9, 0.9, 0.9, 0.9, nil, nil])
        XCTAssertEqual(heard.filter(\.startsSentence).map(\.key), ["the", "gulls"])
    }

    // MARK: - Aligning

    /// A word heard as another is a substitution, a word left out a
    /// deletion, and a word added an insertion; each counts one word error.
    func testTheAlignmentCountsEachKindOfWordError() {
        let alignment = align(heard: "the cat sad on mat today", written: "the cat sat on the mat")

        XCTAssertEqual(alignment.differences.map(\.kind), [.substitution, .deletion, .insertion])
        XCTAssertEqual(alignment.differences.map { alignment.heardKeys(of: $0) }, ["sad", "", "today"])
        XCTAssertEqual(alignment.differences.map { alignment.writtenKeys(of: $0) }, ["sat", "the", ""])
        XCTAssertEqual(alignment.substitutions, 1)
        XCTAssertEqual(alignment.deletions, 1)
        XCTAssertEqual(alignment.insertions, 1)
        XCTAssertEqual(alignment.errorCount, 3)
        XCTAssertEqual(alignment.wordErrorRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(alignment.matches.map(\.written), [0, 1, 3, 5])
    }

    /// A stretch of several words heard for fewer written counts the longer
    /// side's words as errors: "a light" for "alight" is one substitution
    /// and one insertion.
    func testAStretchCountsItsLongerSide() {
        let alignment = align(heard: "the lamp was a light by dusk", written: "the lamp was alight by dusk")

        XCTAssertEqual(alignment.differences.count, 1)
        XCTAssertEqual(alignment.substitutions, 1)
        XCTAssertEqual(alignment.insertions, 1)
        XCTAssertEqual(alignment.errorCount, 2)
    }

    /// A transcript that reads as its text, case and punctuation aside, has
    /// no errors; an empty transcript misses every word.
    func testMatchingAndEmptyTranscripts() {
        let same = align(heard: "Then, she rowed home.", written: "then she rowed home")
        XCTAssertTrue(same.differences.isEmpty)
        XCTAssertEqual(same.wordErrorRate, 0)

        let empty = align(heard: "", written: "she rowed home")
        XCTAssertEqual(empty.deletions, 3)
        XCTAssertEqual(empty.wordErrorRate, 1)
        XCTAssertEqual(align(heard: "", written: "").wordErrorRate, 0)
    }

    // MARK: - Kinds of Mistake

    /// Each difference is sorted into the first kind of mistake it fits.
    func testDifferencesAreSortedIntoKindsOfMistake() {
        XCTAssertEqual(kinds(heard: "we read it on the quay", written: "we read it over and over and over again all day on the quay"), [.passage])
        XCTAssertEqual(kinds(heard: "see page 12 for more", written: "see 12 for more"), [.announcement])
        XCTAssertEqual(kinds(heard: "it cost 4 pounds", written: "it cost four pounds"), [.number])
        XCTAssertEqual(kinds(heard: "said Miss Blacksland", written: "said Miss Blaxland"), [.name])
        XCTAssertEqual(kinds(heard: "come today", written: "come to-day"), [.hyphenation])
        XCTAssertEqual(kinds(heard: "down the rabbit hole", written: "down the rabbit-hole"), [.hyphenation])
        XCTAssertEqual(kinds(heard: "a strange color", written: "a strange colour"), [.spelling])
        XCTAssertEqual(kinds(heard: "a good humored man", written: "a good-humoured man"), [.spelling])
        XCTAssertEqual(kinds(heard: "they traveled far", written: "they travelled far"), [.spelling])
        XCTAssertEqual(kinds(heard: "I shall show it", written: "I shall shew it"), [.archaic])
        XCTAssertEqual(kinds(heard: "in there house", written: "in their house"), [.homophone])
        XCTAssertEqual(kinds(heard: "they were here", written: "they are here"), [.smallWords])
        XCTAssertEqual(kinds(heard: "the store dog bread", written: "the store bought bread"), [.other])
    }

    /// Two hyphens stand for a dash, which joins no words.
    func testTwoHyphensSeparateWordsAsADashDoes() {
        XCTAssertEqual(TranscriptAccuracy.words(in: "bad,--belongs to--them").map(\.key), ["bad", "belongs", "to", "them"])
        XCTAssertTrue(align(heard: "bad, belongs to them", written: "bad,--belongs to--them").differences.isEmpty)
    }

    /// American and British spellings are told apart from words that only
    /// look alike.
    func testSpellingVariantsAreAmericanAndBritishSpellingsOfOneWord() {
        XCTAssertTrue(TranscriptAccuracy.areSpellingVariants("honor", "honour"))
        XCTAssertTrue(TranscriptAccuracy.areSpellingVariants("organizations", "organisations"))
        XCTAssertTrue(TranscriptAccuracy.areSpellingVariants("centers", "centres"))
        XCTAssertTrue(TranscriptAccuracy.areSpellingVariants("practiced", "practised"))
        XCTAssertTrue(TranscriptAccuracy.areSpellingVariants("learned", "learnt"))
        XCTAssertFalse(TranscriptAccuracy.areSpellingVariants("formally", "formerly"))
        XCTAssertFalse(TranscriptAccuracy.areSpellingVariants("honor", "honor"))
        XCTAssertFalse(TranscriptAccuracy.areSpellingVariants("our", "or"), "words of three letters are never variants")
    }

    /// A capital letter makes a name only where no sentence begins, and "I"
    /// is never one.
    func testNamesAreCapitalizedWordsThatBeginNoSentence() {
        let words = TranscriptAccuracy.words(in: "Rowing home, Ottoline said I'd come. Rowing on.")
        XCTAssertEqual(words.filter(TranscriptAccuracy.isName).map(\.key), ["ottoline"])
    }

    // MARK: - Words Matched, Written Differently

    /// Matched words differing in case alone, or in the punctuation ending
    /// them, are counted, but are no word errors.
    func testMatchedWordsWrittenDifferentlyAreCounted() {
        let alignment = align(heard: "then he left", written: "Then, he left.")
        let surface = TranscriptAccuracy.surfaceDifferences(in: alignment)

        XCTAssertEqual(surface, TranscriptAccuracy.SurfaceDifferences(matched: 3, casing: 1, punctuation: 2))
        XCTAssertEqual(alignment.errorCount, 0)
    }

    // MARK: - Confidence

    /// Each word heard falls in the band of its confidence, and counts as
    /// wrong when it lies in a difference.
    func testConfidenceBandsCountWordsAndMistakes() {
        let heard = [
            word("the", confidence: 0.98),
            word("cat", confidence: 0.96),
            word("sad", confidence: 0.31),
            word("down", confidence: 0.92),
            word("today", confidence: 1),
        ]
        let alignment = TranscriptAccuracy.align(heard: heard, written: TranscriptAccuracy.words(in: "the cat sat down"))
        let bands = TranscriptAccuracy.adding(alignment, to: TranscriptAccuracy.emptyConfidenceBands())

        XCTAssertEqual(bands.map(\.from), [0, 0.5, 0.7, 0.9, 0.95])
        XCTAssertEqual(bands.map(\.words), [1, 0, 0, 1, 3])
        XCTAssertEqual(bands.map(\.errors), [1, 0, 0, 0, 1])
        XCTAssertEqual(bands[0].errorRate, 1)
        XCTAssertEqual(bands[4].errorRate, 1.0 / 3, accuracy: 1e-9)
    }

    // MARK: - Tallies

    /// A tally adds alignments up, by kind of mistake, and ranks the
    /// differences found most often, ties by what was heard.
    func testATallyAddsAlignmentsAndRanksDifferences() {
        var tally = TranscriptAccuracy.Tally()
        tally.add(align(heard: "they were here and there house", written: "they are here and their house"))
        tally.add(align(heard: "we were late", written: "we are late"))
        tally.add(align(heard: "the cat", written: "the black cat"))

        XCTAssertEqual(tally.writtenWords, 12)
        XCTAssertEqual(tally.substitutions, 3)
        XCTAssertEqual(tally.deletions, 1)
        XCTAssertEqual(tally.errors, 4)
        XCTAssertEqual(tally.wordErrorRate, 4.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(tally.errorsByClass[.smallWords], 2)
        XCTAssertEqual(tally.errorsByClass[.homophone], 1)
        XCTAssertEqual(tally.errorsByClass[.other], 1)
        let substitutions = tally.mostFrequent(.substitution, limit: 5)
        XCTAssertEqual(substitutions.map(\.pair), [
            TranscriptAccuracy.Pair(heard: "were", written: "are"),
            TranscriptAccuracy.Pair(heard: "there", written: "their"),
        ])
        XCTAssertEqual(substitutions.map(\.count), [2, 1])
        XCTAssertEqual(tally.mostFrequent(.deletion, limit: 5).map(\.pair), [TranscriptAccuracy.Pair(heard: "", written: "black")])
        XCTAssertTrue(tally.mostFrequent(.insertion, limit: 5).isEmpty)
    }

    /// Passages not in both count in the word error rate, and are left out
    /// of the rate without them and of the differences ranked.
    func testPassagesAreSetApartFromMisheardWords() {
        var tally = TranscriptAccuracy.Tally()
        tally.add(align(heard: "the tide turned", written: "the tide page eleven of the harbour almanac twice turned"))

        XCTAssertEqual(tally.errorsByClass[.passage], 7)
        XCTAssertEqual(tally.wordErrorRate, 7.0 / 10, accuracy: 1e-9)
        XCTAssertEqual(tally.wordErrorRateWithoutPassages, 0)
        XCTAssertTrue(tally.pairs.isEmpty)
    }

    // MARK: - Corrections That Were Always Right

    /// A correction is always right when every place its words were heard
    /// is a difference whose written words are the correction, in any
    /// measurement; heard once where it was right, it is not.
    func testACorrectionIsAlwaysRightOnlyWhenNoPlaceGoesWrong() {
        let first = measured("first", heard: "it was alright then", written: "it was all right then")
        let second = measured("second", heard: "she felt alright", written: "she felt all right")
        let third = measured("third", heard: "alright he said", written: "alright he said")

        let rightTwice = TranscriptAccuracy.ruleCandidates([first, second])
        let candidate = rightTwice.first { $0.pattern == "alright" }
        XCTAssertEqual(candidate?.replacement, "all right")
        XCTAssertEqual(candidate?.fixes, 2)
        XCTAssertEqual(candidate?.evidence, 2)
        XCTAssertEqual(candidate?.conflicts, 0)
        XCTAssertEqual(candidate?.sources, ["first", "second"])
        XCTAssertEqual(candidate?.wasAlwaysRight, true)

        let wrongOnce = TranscriptAccuracy.ruleCandidates([first, second, third])
        let refuted = wrongOnce.first { $0.pattern == "alright" }
        XCTAssertEqual(refuted?.fixes, 2)
        XCTAssertEqual(refuted?.conflicts, 1)
        XCTAssertEqual(refuted?.wasAlwaysRight, false)
    }

    /// Two voices reading one text give one place of evidence for a
    /// correction they both needed, however many times it was heard.
    func testTwoVoicesReadingOneTextGiveOnePlaceOfEvidence() {
        let first = measured("chapter--alex", text: "chapter", heard: "he felt alright", written: "he felt all right")
        let second = measured("chapter--daniel", text: "chapter", heard: "he felt alright", written: "he felt all right")

        let candidate = TranscriptAccuracy.ruleCandidates([first, second]).first { $0.pattern == "alright" }

        XCTAssertEqual(candidate?.fixes, 2)
        XCTAssertEqual(candidate?.evidence, 1)
        XCTAssertEqual(candidate?.sources, ["chapter--alex", "chapter--daniel"])
    }

    /// Names, numbers, announced pages, and passages suggest no correction.
    func testNamesNumbersAnnouncementsAndPassagesSuggestNoCorrection() {
        let candidates = TranscriptAccuracy.ruleCandidates([
            measured("names", heard: "said Miss Blacksland", written: "said Miss Blaxland"),
            measured("numbers", heard: "it cost 4 pounds", written: "it cost four pounds"),
            measured("pages", heard: "see page 12 for more", written: "see p. 12 for more"),
            measured("passage", heard: "we read it on the quay", written: "we read it over and over and over again all day on the quay"),
        ])

        XCTAssertTrue(candidates.isEmpty, "\(candidates.map(\.pattern))")
    }

    /// A correction of several words counts only where its words were heard
    /// within one sentence: a place across two sentences is neither a fix
    /// nor a conflict.
    func testACorrectionOfSeveralWordsStaysWithinASentence() {
        let found = measured("found", heard: "the lamp was a light by dusk", written: "the lamp was alight by dusk")
        let acrossSentences = TranscriptAccuracy.Measurement(
            source: "across",
            text: "across",
            alignment: TranscriptAccuracy.align(
                heard: TranscriptAccuracy.words(heardIn: [
                    TranscriptFixtures.sentence("Pass me a", from: 0, to: 900),
                    TranscriptFixtures.sentence("Light rain fell.", from: 900, to: 1_800),
                ]),
                written: TranscriptAccuracy.words(in: "Pass me a. Light rain fell.")
            )
        )

        let candidate = TranscriptAccuracy.ruleCandidates([found, acrossSentences]).first { $0.pattern == "a light" }

        XCTAssertEqual(candidate?.replacement, "alight")
        XCTAssertEqual(candidate?.fixes, 1)
        XCTAssertEqual(candidate?.conflicts, 0)
    }

    /// Corrections one text suggests, counted over another, fare as they
    /// would there: wrong where the words heard were the words meant, and
    /// right only where the same mistake was made.
    func testCorrectionsFromOneTextAreCountedOverAnother() {
        let learned = TranscriptAccuracy.ruleCandidates([
            measured("pride", heard: "a chase and four", written: "a chaise and four"),
        ]).filter(\.wasAlwaysRight)

        let tried = TranscriptAccuracy.tallied(learned, over: [
            measured("alice", heard: "the chase was long", written: "the chase was long"),
            measured("persuasion", heard: "her chase waited", written: "her chaise waited"),
        ])

        XCTAssertEqual(tried.map(\.pattern), ["chase"])
        XCTAssertEqual(tried.first?.fixes, 1)
        XCTAssertEqual(tried.first?.conflicts, 1)
        XCTAssertEqual(tried.first?.places, [TranscriptAccuracy.Place(text: "persuasion", word: 1)])
        XCTAssertEqual(tried.first?.sources, ["persuasion"])
    }

    /// TextMouth's own rules are only the corrections always right in two
    /// places or more, of words misheard rather than a convention, whose
    /// pattern holds a word that is no English word.
    func testConservativeRulesKeepOnlyCorrectionsOfWordsNoBookMeans() {
        let candidates = TranscriptAccuracy.ruleCandidates([
            // A word no dictionary holds, misheard in two places: kept.
            measured("one", heard: "an amultur painter", written: "an amateur painter"),
            measured("two", heard: "the amultur cook", written: "the amateur cook"),
            // An English word, right somewhere else: dropped.
            measured("three", heard: "I begged your pardon", written: "I beg your pardon"),
            measured("four", heard: "she begged leave", written: "she beg leave"),
            // A convention of spelling: dropped.
            measured("five", heard: "a fine color", written: "a fine colour"),
            measured("six", heard: "no color at all", written: "no colour at all"),
            // A word no dictionary holds, found in one place: dropped.
            measured("seven", heard: "an antivistamine tablet", written: "an antihistamine tablet"),
        ])
        let dictionary: Set<String> = ["an", "the", "begged", "beg", "color", "colour", "painter", "cook"]

        let rules = TranscriptAccuracy.conservativeRules(candidates, isWord: dictionary.contains)

        XCTAssertEqual(rules.map(\.pattern), ["amultur"])
        XCTAssertEqual(rules.first?.replacement, "amateur")
        XCTAssertEqual(rules.first?.evidence, 2)
        XCTAssertTrue(candidates.contains { $0.pattern == "begged" && $0.wasAlwaysRight })
        XCTAssertTrue(candidates.contains { $0.pattern == "color" && $0.errorClass == .spelling })
    }

    // MARK: - Helpers

    /// `heard`, as a transcript of one untimed sentence, aligned with
    /// `written`.
    private func align(heard: String, written: String) -> TranscriptAccuracy.Alignment {
        let sentences = heard.isEmpty ? [] : [TranscriptSentence(text: heard, startMilliseconds: 0, endMilliseconds: 1_000, words: [])]
        return TranscriptAccuracy.align(
            heard: TranscriptAccuracy.words(heardIn: sentences),
            written: TranscriptAccuracy.words(in: written)
        )
    }

    /// `heard` measured against `written`, as the recording `source` of the
    /// known text `text`, its own unless named.
    private func measured(_ source: String, text: String? = nil, heard: String, written: String) -> TranscriptAccuracy.Measurement {
        TranscriptAccuracy.Measurement(source: source, text: text ?? source, alignment: align(heard: heard, written: written))
    }

    /// The kinds of mistake of the differences between `heard` and
    /// `written`.
    private func kinds(heard: String, written: String) -> [TranscriptAccuracy.ErrorClass] {
        let alignment = align(heard: heard, written: written)
        return alignment.differences.map { TranscriptAccuracy.errorClass(of: $0, in: alignment) }
    }

    /// A word heard mid-sentence, with `confidence`.
    private func word(_ text: String, confidence: Double) -> TranscriptAccuracy.Word {
        TranscriptAccuracy.Word(text: text, key: TranscriptAccuracy.key(of: text), startsSentence: false, confidence: confidence)
    }
}
