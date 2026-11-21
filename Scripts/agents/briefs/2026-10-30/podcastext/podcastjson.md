# Task `podcastjson`: the Podcasting 2.0 transcript and chapters readers (FMT25, step 4)

Slug `podcastext-podcastjson`, branch `podcastext/podcastjson` (from `team/podcastext`). Read `common.md` beside this brief first.

## Goal
Read a podcast's own JSON transcript (Podcasting 2.0, version 1.0.0) into a `TimedTextDocument` (`TextMouth/Models/TimedText.swift`), and its chapters file (version 1.2.0) into a small model that later tasks keep beside an episode's audio and turn into its headings. Both bounded, tolerant, and never following a link. Nothing calls them yet.

Formats (podcasting2.org, verified by the research): a transcript is `{"version": "1.0.0", "segments": [{"speaker": "Ana", "startTime": 0.0, "endTime": 0.9, "body": "..."}]}`, times in seconds; real feeds often give one word per segment. A chapters file is `{"version": "1.2.0", "chapters": [{"startTime": 0, "title": "...", "endTime": 2, "toc": false, "img": "...", "url": "...", "location": {...}}]}`. See the samples `TestData/format-samples/podcast-transcript-json/transcript.json` and `podcast-chapters-json/chapters.json`.

## Files you own (new)
- `TextMouth/Parsers/PodcastTranscriptReader.swift`
- `TextMouth/Parsers/PodcastChapters.swift`
- `TextMouthProductionTests/PodcastTranscriptReaderTests.swift`, `TextMouthProductionTests/PodcastChaptersTests.swift`
Touch no other file but `project.pbxproj` (by xcodegen).

## API (exactly these names)
```swift
enum PodcastTranscriptReader {
    /// The longest silence, in milliseconds, between two words of one sentence (item 7).
    static let wordGapMilliseconds = 1_000
    /// The most words one sentence gathers (item 7).
    static let maximumWordsPerSentence = 60
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument
}

/// One chapter of a podcast's chapters file, as TextMouth keeps it.
struct PodcastChapter: Equatable, Sendable {
    var startMilliseconds: Int
    var title: String
}

/// A podcast episode's chapters (Podcasting 2.0, version 1.2.0), as listed in its table of contents.
struct PodcastChapters: Equatable, Sendable {
    /// The most chapters a file may hold.
    static let maximumChapters = 5_000
    var chapters: [PodcastChapter]
    static func read(_ data: Data) throws -> PodcastChapters
    /// The file TextMouth keeps beside an episode's audio (item 13).
    func normalizedJSON() throws -> Data
    /// The chapters as a book of one audio file lasting `fileDuration` seconds takes them (item 14).
    func bookChapters(fileDuration: TimeInterval) -> [(title: String, startTime: TimeInterval, duration: TimeInterval)]
}

/// Why a chapters file is not used; logged, never shown.
enum PodcastChaptersError: Error, Equatable, CustomStringConvertible {
    case notChapters               // not JSON, not an object, or no "chapters" array
    case unsupportedVersion(String)
    case noChapters
    case tooManyChapters(limit: Int)
    var description: String { ... } // item 15
}
```

## Behavior

### The transcript
1. Parse with `JSONSerialization.jsonObject(with: data)`. Anything it refuses, or a top level that is not an object, throws `TimedTextError.notTimedText(.podcastJSON)`.
2. **Version:** when `version` is a string whose part before the first "." is not "1", throw `.unsupportedVersion(.podcastJSON, v)` with `v` the version's first 20 characters (it is the file's text, and the error is logged). A missing version, or one that is not a string, is accepted.
3. `segments` must be an array, else `.notTimedText(.podcastJSON)`. Each element that is not an object is skipped and counted.
4. **A segment's times:** `startTime` and `endTime` each a JSON number, or a string that `Double(_:)` reads; finite and not negative; else the segment is skipped and counted. Milliseconds through `Transcript.milliseconds(_:)` (`TextMouth/Models/Transcript.swift:232`). Either past `Transcript.maximumMilliseconds`, or an end before the start, is skipped and counted.
5. **Body and speaker:** `body` must be a string; finished with `TimedTextCue.plainText`; blank is skipped and counted. `speaker`, when a string, is finished the same way and is the cue's `voice`; blank or not a string means no voice.
6. Segments are stably sorted by start before anything is grouped.
7. **Words into sentences.** A segment whose finished body holds no space is a word. Consecutive words become one cue while each next word has the same voice (no voice equals no voice), starts less than `wordGapMilliseconds` after the previous word ends (a word starting before the previous one ends is fine), the cue does not yet end a sentence, and it holds fewer than `maximumWordsPerSentence` words. A cue ends a sentence when its last word ends with ".", "?", "!", or "…", optionally followed by any of `"'”’)]`. A segment with a space in its body ends any cue being gathered and is a cue of its own, with no `words`.
8. **A gathered cue:** its text is its words joined by single spaces; it starts where its first word starts and ends at the latest end among its words; `words` holds one `TranscriptWord` per word, at its UTF-16 offset and length in the text, with the word's own start and end, and no confidence. A lone word is a cue of one word, with its `words` too. These words always satisfy `Transcript.validationFailure()` (starts never decrease, each inside the cue's time and text); a test proves it on the sample.
9. More than `maximumCues` cues throws `.tooManyCues(limit: maximumCues)`; none throws `.noCues(.podcastJSON)`.

### The chapters
10. Parse as item 1; a refusal, a top level that is not an object, or no `chapters` array throws `PodcastChaptersError.notChapters`. Version as item 2, throwing `.unsupportedVersion`.
11. More than `maximumChapters` elements in `chapters` throws `.tooManyChapters(limit:)` before any is read.
12. **Each chapter:** an object, else skipped. `startTime` as item 4's times (number or numeric string, finite, not negative, at most `Transcript.maximumMilliseconds`), else skipped. `toc` equal to JSON `false` (or the string "false") leaves the chapter out: it is not in the table of contents (images and advertisement markers). `title`, a string finished with `TimedTextCue.plainText`, else "" (kept: item 14 names it). `endTime`, `img`, `url`, `location`, and every top-level field but `version` and `chapters` are ignored, and no address is ever opened. The chapters left are stably sorted by start. None left throws `.noChapters`.
13. **`normalizedJSON()`:** the chapters as Podcasting 2.0 chapters of version "1.2.0", each with only `startTime` (seconds, `Double(ms) / 1000`) and `title`, written with `JSONEncoder` and `.sortedKeys`. `PodcastChapters.read(normalizedJSON())` gives back the same chapters (a test proves it on the sample).
14. **`bookChapters(fileDuration:)`:** when the last chapter starts more than `TimedTextLimits.pastTheEndMarginMilliseconds` after `fileDuration`, the file describes other audio: return none. Otherwise return `NeroChapterReader.bookChapters(from:fileDuration:)` (`TextMouth/Parsers/NeroChapterReader.swift:150-185`) of the chapters as `NeroChapterReader.Chapter(title:start:)` in seconds, which already sorts, drops what lies at or past the end and repeated starts, begins the first at 0, makes each last until the next, and names an untitled one "Chapter N"; it returns none for a duration that is not a finite number above zero. Reuse it; do not copy it.
15. `description` of each error, for the log, never quoting a title: "not a chapters file", "version \(v) is not one TextMouth reads", "it lists no chapter TextMouth can use", "it lists more than \(limit) chapters".

## Tests
`PodcastTranscriptReaderTests`:
- **the sample,** copied first: four cues, `(0, 900, "This sentence belongs to the first tone, 440 hertz.", "Ana")`, `(1000, 1900, "This one belongs to the second tone, 550 hertz.", "Ben")`, `(2000, 2900, "Third tone, 660 hertz. A café, an étude.", "Ana")` with no words, and `(3000, 3800, "The fourth and last tone is 880 hertz.", "Ben")` with eight words, each where it lies ("fourth" at offset 4, length 6, 3100 to 3200); its `sentences` name "Ana: ", "Ben: ", "Ana: ", "Ben: ", with the last sentence's words moved by 5; and a `Transcript` made of those sentences (`TranscriptFixtures.transcript([(path: "tone4.wav", duration: 4_000, sentences: ...)])`) passes `validationFailure()`;
- each rule of items 2 to 9 by a small JSON case: versions "1.0.0", "1", "2.0.0", 1.0 (a number), a 40-character version cut to 20 in the error; times as strings, negative, NaN-like strings ("nan" reads as NaN in Swift: refused), past the maximum, end before start; a body that is a number; blank speakers; grouping across a speaker change, a gap of exactly 1,000 ms (splits) and 999 (joins), "?" and "”" endings, 61 words (60 then 1); a sentence segment between words; out-of-order segments; the cap with `maximumCues: 2`; no segments; not JSON; an array at the top.
`PodcastChaptersTests`:
- **the sample,** copied first: four chapters (the `toc: false` one left out) at 0, 1000, 2500, 3200 ms titled "Intro — 440 Hz", "Second: café", "Third, with a place", "Outro";
- items 10 to 15 by small cases, including `"toc": "false"`, a chapter without a title, 5,001 chapters, and no `chapters` key;
- `normalizedJSON()`'s exact bytes for two chapters, and the round trip on the sample;
- `bookChapters`: the sample over a 4-second file gives starts 0, 1, 2.5, 3.2 and durations 1, 1.5, 0.7, 0.8 (compare with an accuracy of 0.001); a last chapter at duration + 5 s is kept as Nero's rules keep it (dropped, being past the end, but the others stay) and at duration + 5.001 s gives none at all; a first chapter at 12 s is moved to 0.

Run: `PodcastTranscriptReaderTests PodcastChaptersTests`.

## Not yours
No fetching, no feed code, no package files, no change to `TimedText.swift` or `NeroChapterReader.swift`.
