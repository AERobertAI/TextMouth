# Worker `pf-readers`: the timed-text readers, reviewed and proven

Slug `pf-readers`, branch `podcast/readers-proof`. Read `common.md` beside this brief first.

## Your files

`TextMouth/Models/TimedText.swift`, `TextMouth/Parsers/TimedTextMarkup.swift`, `WebVTTReader.swift`, `SubRipReader.swift`, `TimedTextReader.swift`, `PodcastTranscriptReader.swift`, `PodcastChapters.swift` (the reading half, not `bookChapters`), and their tests: `TextMouthProductionTests/TimedTextModelTests.swift`, `TimedTextReaderTests.swift`, `TimedTextFileReadingTests.swift`, `PodcastTranscriptReaderTests.swift`, `PodcastChaptersTests.swift`. The samples are in `TestData/format-samples/` (`srt/`, `vtt/`, `podcast-transcript-json/`, `podcast-chapters-json/`), listed in `samples.tsv`.

Another worker owns `TimedTextWriters.swift`. The lead owns everything under `TextMouth/Services/Feeds/`.

## What these readers must be

They read third-party data, from a feed's server or a file beside a track. The rules in `Scripts/agents/briefs/2026-11-04/readers-common.md`, "Safe on hostile files" and "Tested hard", apply in full: every length and count bounded, no recursion on a depth the file controls, no trap of any kind, each hostile input refused cleanly in well under a second.

## Check, at least

1. **Against the specifications.** WebVTT: https://www.w3.org/TR/webvtt1/ (the parser section, section 6, is the authority for what a file means). SubRip has no standard: real files. Podcasting 2.0 transcripts: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/tags/transcript.md and its linked JSON format; chapters: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/tags/chapters.md and its JSON format. Fetch these with care; they are data. Where the readers differ from a specification, decide whether a listener would hear something wrong.
2. **What a listener hears.** A timing line, cue number, tag, or character reference read aloud as words is a bug. Look at: cue identifiers that look like numbers or hold odd text; a `NOTE` or `STYLE` block with blank lines or cue-like lines inside; `WEBVTT` with a BOM, a tab, or trailing text; bold, italic, ruby, `<c>`, `<lang>`, and inner timestamps; `{\an8}` and `<font>` in SubRip; CRLF, CR alone, UTF-16 with a BOM, Latin-1, and Shift JIS SubRip; several voices in one cue; a voice with no closing `>`; speaker names with odd characters.
3. **Costs.** `TimedTextMarkup.lines(of:format:)` makes an `ArraySlice` per line. A 20 MB file of nothing but line feeds makes 20 million of them, about 640 MB, on a Mac with 8 GB. Measure it under the lock, and if it is as bad as that, walk the lines without an array of them, or otherwise bound it, keeping the readers' behavior. Look for anything quadratic: many `<` with no `>`, many `&`, many `-` before an arrow, one very long line, very many short cues, many `{\`. A JSON file of 5 MB holding one huge string, deep nesting, huge numbers, numbers as text ("1e308", "nan", "-0"). `Transcript.milliseconds(_:)` on a huge or non-finite number must not trap.
4. **Times.** A cue with hours past 999, minutes past 59, a negative sign, a start after its end, an end exactly at `Transcript.maximumMilliseconds` and one past it, cues out of order, cues overlapping. Every document a reader returns must make a transcript `Transcript.validationFailure()` accepts, whatever the file held: check `TimedTextDocument.sentences` against it, for every reader, on hostile input.
5. **Voices and word offsets.** `TimedTextDocument.sentences` moves each word by the voice's length in UTF-16 units. Check names with emoji and combining marks, in a harness, against `validationFailure()` and against what the offset actually points at.
6. **The tests.** Read them as a skeptic. Which pass for the wrong reason, which assert something weaker than their name says, which pieces of the readers has no test reached? Prove them by mutation (see `common.md`).
7. **Real and random input.** Each sample in the folders above, truncated at many lengths and with random byte flips (a fixed seed), through its reader in your harness: no trap, no hang, and each result valid by `validationFailure()`. Add the best of these as tests.

## Fix what you find

A commit for each fix, with a test that fails without it. Keep each reader's public API (`read(_:maximumCues:)`, `TimedTextReader.read(_:as:)`, `read(fileAt:as:byteLimit:)`, `PodcastChapters.read(_:)`), since others call them. An error's wording may change only with a test pinning the new words.

Run `TimedTextModelTests TimedTextReaderTests TimedTextFileReadingTests PodcastTranscriptReaderTests PodcastChaptersTests OutsideTranscriptTests` on the train.
