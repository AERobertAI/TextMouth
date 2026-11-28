# Task `readers`: the WebVTT and SubRip readers (FMT23, step 1)

Slug `podcastext-readers`, branch `podcastext/readers` (from `team/podcastext`). Read `common.md` beside this brief first.

## Goal
Two readers that turn a .vtt or .srt file's bytes into a `TimedTextDocument` (`TextMouth/Models/TimedText.swift`): bounded, tolerant of what real files hold, and never trusting them. Nothing calls them yet; the lead and later tasks wire them in.

## Files you own (new)
- `TextMouth/Parsers/TimedTextMarkup.swift`: what the two readers share: the timestamp grammar, the markup and character-reference rules, and the finishing of a cue list (sorting, the cap, no cues).
- `TextMouth/Parsers/WebVTTReader.swift`
- `TextMouth/Parsers/SubRipReader.swift`
- `TextMouthProductionTests/TimedTextReaderTests.swift` (the readers) and `TextMouthProductionTests/TimedTextModelTests.swift` (the lead's model, which nobody has tested yet).
Touch no other file but `project.pbxproj` (by xcodegen).

## API (exactly these names)
```swift
enum WebVTTReader {
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument
}
enum SubRipReader {
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument
}
enum TimedTextTimestamp {
    /// The milliseconds `text` names, or nil when it is not a timestamp (item 3).
    static func milliseconds(_ text: Substring) -> Int?
}
```
`maximumCues` is a parameter so a test can prove the cap with a small number. The readers throw only `TimedTextError`, and never log (their callers do).

## Behavior

### Shared (TimedTextMarkup.swift)
1. **Decoding.** `TextFileDecoder.decode(data, fileName: <"transcript.vtt" or "transcript.srt">, format: .txt, policy: .guess)` (`TextMouth/Parsers/TextFileDecoder.swift:271`): it drops leading byte-order marks, reads UTF-8 and UTF-16, guesses a legacy encoding, falls back to Windows-1252, and turns CR LF and lone CR into LF. A `TextEncodingError` it throws becomes `TimedTextError.notTimedText(<format>)`.
2. **Lines and blocks.** Split the text at "\n". A blank line is one that is empty or holds only spaces and tabs.
3. **Timestamp grammar** (`TimedTextTimestamp.milliseconds`), for both formats: `[H:]M:S` then a fraction.
   - Two or three fields separated by ":"; every field ASCII digits only (no sign, no space).
   - With three fields: hours 1 to 3 digits (any value), minutes 1 or 2 digits from 0 to 59.
   - With two fields: minutes 1 to 4 digits (any value; some tools write "75:00.000").
   - Seconds: 1 or 2 digits, 0 to 59, then optionally "." or "," and a fraction of 1 or more digits, of which the first three count as a decimal fraction ("5" is 500 ms, "05" is 50, "005" is 5, "0059" is 5); no fraction reads as 0 ms.
   - Anything else (an empty field, a fourth field, a letter, 60 seconds) is nil. The bounded digit counts keep the arithmetic far from overflow.
4. **Timing line.** A line holding "-->": the start is the text before the first "-->", trimmed of spaces and tabs; the end is the first run of characters that are not spaces or tabs after it. Whatever follows the end (WebVTT cue settings such as `align:start position:10%`, SubRip coordinates such as `X1:40 X2:600`) is ignored.
5. **Markup** in a cue's text lines (joined by "\n" first):
   - Every tag, from a "<" to the next ">", is removed. A "<" with no ">" after it stays as text, with everything after it.
   - **Voices** (WebVTT's `<v Ana>`, `<v.loud Ben>`): a tag whose name is `v` (the character after "v" is a space, a tab, a "." or the ">") is a voice tag; its annotation is what follows the first space or tab after the tag name and its classes, up to the ">", finished with `TimedTextCue.plainText`. The cue's `voice` is the first non-empty annotation. Each later voice tag of the same cue whose annotation differs from the voice named last in the cue puts `Annotation: ` (the annotation, a colon, a space) into the text where the tag stood; one naming the same voice again puts nothing.
   - Timestamp tags (`<00:00:01.500>`), `<c.x>`, `<b>`, `<i>`, `<u>`, `<lang en>`, `<ruby>`, `<rt>`, and closing tags are simply removed (their text stays).
   - **SubRip only:** `{\` up to the next `}` (an override such as `{\an8}`) is removed too; a `{\` with no `}` after it stays.
   - **Character references,** decoded after the tags are removed (so `&lt;b&gt;` is the text "<b>", never a tag): `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` `&nbsp;` (U+00A0); `&lrm;` and `&rlm;` are removed; `&#NNN;` and `&#xHHH;` become their character when it is a Unicode scalar other than U+0000, at most 7 digits; any other `&...;`, and an `&` without a `;`, stay as written.
   - Last, the text is finished with `TimedTextCue.plainText` (one space for each run of white space, none at the ends).
6. **A cue is skipped, and counted in `skippedCueCount`,** when its start or end does not read (item 3), its end is before its start, either lies past `Transcript.maximumMilliseconds` (exactly that value is allowed), or its text is blank once finished.
7. **Finishing:** cues are stably sorted by start (a tie keeps the file's order). When more than `maximumCues` cues are kept, throw `TimedTextError.tooManyCues(limit: maximumCues)`; stop reading as soon as the count passes it. When none is kept, throw `TimedTextError.noCues(<format>)`.

### WebVTT
8. The first line must be `WEBVTT`, or `WEBVTT` followed by a space or a tab and anything (`WEBVTT - four tones`); otherwise throw `.notTimedText(.webVTT)` (`WEBVTTX`, a missing line, a blank first line). The header's lines run to the first blank line and are ignored.
9. The rest is blocks separated by blank lines. A block whose first line is `NOTE`, `STYLE`, or `REGION`, alone or followed by a space or tab, is ignored (not counted).
10. In any other block, the timing line is the first line when it holds "-->", else the second line when it does (the first is the cue's identifier, ignored). A block with neither is ignored (not counted). The lines after the timing line are the cue's text (item 5).

### SubRip
11. Lines are scanned in order. A timing line is a line holding "-->" whose start and end both read (item 3). Lines before the first timing line are ignored.
12. A cue's text is the lines after its timing line, up to the first of: a blank line; the next line holding "-->"; or a line of digits alone (spaces around it allowed) that is directly followed by a timing line, which is the next cue's number written without the blank line before it. Cue numbers are never text, and need not be in order or present at all.
13. A line holding "-->" that does not read as a timing line counts one skipped cue, and the lines after it, up to the next blank line, are ignored.

## Tests
`TimedTextModelTests` (the model, `TextMouth/Models/TimedText.swift`):
- the raw values "webvtt", "srt", "podcast-json" (stored in files, so pinned); `fileExtension` and `name` of each;
- `cueFileFormat(forExtension:)`: "vtt", "VTT", "Vtt" give `.webVTT`; "srt", "SRT" give `.subRip`; "json", "txt", "" give nil;
- `plainText`: tabs, line breaks, U+00A0, and runs of spaces become single spaces, trimmed;
- `sentences`: a voice is named before its cue's text when it is not the voice named last ("Ana: "), not again for the next cue of the same voice, not for a cue without a voice, and again after another voice spoke ("Ana", "Ana", nil, "Ben", "Ana" gives names on cues 1, 4, and 5); a named cue's words move by the name's UTF-16 length (use a voice "Zoë" and a word in the cue, and check the word's offset and that its range still spells the word in the sentence's text);
- every `TimedTextError.errorDescription`, word for word (for `.tooLarge(byteLimit: 5 * 1_048_576)`: "The file is larger than the 5 MB TextMouth reads as a transcript.").

`TimedTextReaderTests`:
- **the samples,** copied first: `vtt/tone4.vtt` gives exactly four cues, `(0, 900, "First tone, 440 hertz.", "Ana")`, `(1000, 1900, "Second tone, 550 hertz & bold.", "Ben")`, `(2000, 2900, "Third tone, café 660 hertz. Second line of the cue.", "Ana")`, `(3000, 3900, "The fourth, 880 hertz, with no speaker.", nil)`, none skipped, and its `sentences` begin "Ana: ", "Ben: ", "Ana: ", and nothing. `srt/tone4.srt` (CR LF line endings, an `<i>` tag, a two-line cue) gives `(0, 900, "This sentence belongs to the first tone, 440 hertz.")`, `(1000, 1900, "This one belongs to the second tone, 550 hertz.")`, `(2000, 2900, "Third tone, 660 hertz. A café, an étude.")`, `(3000, 3900, "The fourth and last tone is 880 hertz.")`, no voices;
- the timestamp grammar, a table of accepted and refused strings covering every rule of item 3 (including "100:00:00.000" as 360,000,000 and "0:01.5" as 1,500);
- the header rules of item 8; NOTE, STYLE, and REGION blocks; an identifier line; cue settings; a byte-order mark with CR LF;
- each skip of item 6 counted; the boundary `Transcript.maximumMilliseconds` kept and one more refused;
- the markup of item 5, each rule by a small case, including a second voice in one cue, a voice with classes, a timestamp tag, `&lt;b&gt;`, `&#233;`, `&#x1F600;`, `&#0;` and `&bogus;` left as written, `&lrm;` removed, a lone "<", and SubRip's `{\an8}`;
- SubRip's missing blank line (item 12), an unreadable timing line (item 13), cue numbers out of order, a cue with no number;
- a SubRip file in Windows-1252 (the bytes of "café" with 0xE9) reads "café";
- the cap with `maximumCues: 3` (four cues throw `.tooManyCues(limit: 3)`); no cue at all throws `.noCues`;
- out-of-order cues come back sorted, ties in file order;
- robustness: each prefix of the WebVTT and the SubRip sample, cut every 5 bytes, either reads or throws a `TimedTextError`, never anything else, and a few kilobytes of random bytes (a fixed seed, `SystemRandomNumberGenerator` is not seedable, so write a tiny linear congruential generator in the test) do the same.

Run: `TimedTextReaderTests TimedTextModelTests TranscriptModelTests`.

## Not yours
No wiring into imports, commands, or export; no change to `TimedText.swift` (ask the lead), `TextFileDecoder`, or any existing file.
