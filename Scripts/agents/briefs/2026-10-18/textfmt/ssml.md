# textfmt-ssml: an SSML file read as text (FMT07, part 1)

Slug `textfmt-ssml`, branch `textfmt/ssml` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

An .ssml file (W3C Speech Synthesis Markup Language) becomes a text book: its markup removed, its paragraphs and sentences kept. It is never given to the speech engine as SSML, nor as text with tags: on macOS 26.3.1 `AVSpeechUtterance(ssmlRepresentation:)` ignores the book's rate and pitch and `sub` aliases, and crashed the research probe on every `emphasis` element (`ssml/passage.ssml` holds one on purpose); and TextMouth's speech engine takes tag-shaped text in a plain string for markup (`SpeechMarkupGuard`). So this reader turns SSML into simple HTML, which another task hands to `HTMLToMarkdownConverter`, as every HTML book's text is read; that converter escapes literal text and keeps `<em>` as Markdown emphasis, which the listener never hears as symbols.

The sample `ssml/passage.ssml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<speak version="1.1" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">
  <p>
    <s>The ferry leaves at <say-as interpret-as="time" format="hms12">9:30am</say-as>.</s>
    <s>Wait here <break time="2s"/> until you hear the horn.</s>
  </p>
  <p>
    <s>It is <emphasis level="strong">not</emphasis> a long crossing.</s>
    <s><prosody rate="slow" pitch="-2st">Mind the gap between the boat and the pier.</prosody></s>
    <s>Say the word <phoneme alphabet="ipa" ph="t&#601;&#712;m&#593;&#720;to&#650;">tomato</phoneme> twice, and spell <say-as interpret-as="characters">SSML</say-as>.</s>
    <s><sub alias="World Wide Web Consortium">W3C</sub> publishes the standard.</s>
  </p>
</speak>
```

It must read as two paragraphs: "The ferry leaves at 9:30am. Wait here until you hear the horn." and "It is <em>not</em> a long crossing. Mind the gap between the boat and the pier. Say the word tomato twice, and spell SSML. World Wide Web Consortium publishes the standard."

## Read first (by line range)

- `TextMouth/Parsers/PackageSAXParser.swift` lines 1-110: the SAX base every package reader subclasses. Subclass it, so external entities are never resolved and damage is described in the shared words.
- `TextMouth/Parsers/DocumentByteLimit.swift` (whole file).
- One existing subclass for the pattern, such as `TextMouth/Parsers/DAISYParser+OPFParser.swift` (83 lines).

## What to build

A new file `TextMouth/Parsers/SSMLReader.swift`, `enum SSMLReader`:

1. `enum Failure: LocalizedError, Equatable`:
   - `case notSSML(rootElement: String)`: "This file is not SSML: it begins with the element “<name>”, not “speak”."
   - `case damaged(reason: String)`: "This SSML file is damaged or incomplete: <reason>." where reason is the one `PackageSAXParser` gives ("its markup breaks off early or has extra content after the end (line 3, column 1)").
2. `static func html(from url: URL) throws -> String`: the bytes through `DocumentByteLimit.contents(of:)`, then `html(from:)` below.
3. `static func html(from data: Data) throws -> String`, a `PackageSAXParser` subclass doing the work. Elements are matched by local name (strip any prefix), case-sensitively as SSML is:
   - The root must be `speak`; otherwise `.notSSML(rootElement:)` with its local name.
   - `p` and `paragraph` begin and end a paragraph. Text outside any paragraph (directly in `speak`, or in an `s` outside a `p`) forms a paragraph of its own, ended by the next `p` or the end.
   - `s` and `sentence` end with a space, so sentences never run together.
   - `break` is a space, never a paragraph: a word boundary, so the words around it never join.
   - `emphasis` writes its content inside `<em>…</em>`.
   - `sub` writes its `alias` attribute's text in place of its content (what SSML says to speak; the content when the alias is missing or blank).
   - `say-as`, `phoneme`, `prosody`, `voice`, `lang`, `token`, `w`, `mark`, and any element not named here write their content only (`phoneme`'s `ph` has no text form, so its written word stays).
   - `audio` writes its content (SSML's fallback text) and never its `src`, which is never fetched; `desc` inside it is dropped.
   - `desc`, `meta`, `metadata`, and `lexicon` write nothing, content included.
   - In each paragraph, runs of white space become one space and the ends are trimmed; an empty paragraph writes nothing.
   - The result is `<html><body>` then `<p>…</p>` per paragraph, then `</body></html>`, with every text character `&`, `<`, `>`, `"` escaped (one small helper). A file with no words gives a body with no paragraph; the import refuses it as having no text, elsewhere.
4. Damage: the subclass's malformed-XML error is `.damaged(reason:)`. An empty file has no text to read (`DocumentByteLimit.contents(of:)` says so before parsing).

About 120 lines with comments. No other app file changes.

## Tests

A new file `TextMouthProductionTests/SSMLReaderTests.swift`, class `SSMLReaderTests` (run `xcodegen generate`). Small SSML strings in the test, through one helper that returns the HTML's paragraphs (parse the result with SwiftSoup and take each `p`'s inner HTML), so each test states only its SSML and its paragraphs.

1. The sample (a copy) gives exactly the two paragraphs above (the `<em>` kept), and `HTMLToMarkdownConverter.convert(_:)` of the result, parsed with `MarkdownDocParser.parse(markdown:title:)`, gives text without any `<`, `>`, `*`, or "W3C", and with "World Wide Web Consortium" and "9:30am".
2. `break` between two words keeps one space; `s` elements without spaces between them stay apart ("One.</s><s>Two." gives "One. Two.").
3. `sub` with an alias, without one, and with a blank one.
4. `audio` with a `src` and fallback text and a `desc` gives the fallback only; `desc`, `meta`, `metadata`, and `lexicon` give nothing.
5. Text directly in `speak`, before and after a `p`, gives three paragraphs in order.
6. Text holding `<`, `&`, and quotes as character references (`&lt;b&gt;`) comes out escaped, and the converter's Markdown reads them as written, with no tag.
7. A prefixed root (`<ssml:speak xmlns:ssml="http://www.w3.org/2001/10/synthesis">`) reads as SSML; `<html>` as the root is `.notSSML(rootElement: "html")`, its sentence pinned word for word.
8. A truncated file is `.damaged`, its sentence pinned; an empty file has no text to read; a file past a bound limit is refused with `DocumentTooLargeError`.
9. An external entity is never resolved: `<!DOCTYPE speak [<!ENTITY outside SYSTEM "file:///etc/hosts">]><speak><p>A &outside; B</p></speak>` never gives the hosts file's text ("localhost"), whether it reads or is refused.

Run `SSMLReaderTests`.

## Not yours

No `BookFormat` case, no import or cache wiring, no `Info.plist`: another task adds them. Never import AVFoundation, and never call any speech API.
