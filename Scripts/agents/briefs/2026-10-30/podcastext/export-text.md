# Task `export-text`: a transcript's text through the Convert to writers (triage, TODO 3984 and 3992)

For `podcastext-export`, as one more commit on `podcastext/export` after the lead has reviewed the first (sent by message; your context is intact). The orchestrator's triage of October 30 gives two open items in the files your task already edits:
- TODO 3984: "an audiobook's Transcript.md could take the same Convert to choice" (`BookExportService.swift:209-211`, `convertsText` is true for `.markdown` alone);
- TODO 3992 (its export part): "a transcript cannot be exported as HTML, RTF, Word, or braille".

## Behavior
1. The transcript's picker lists, in order: "JSON and Markdown" (the default), then every text writer exactly as the "Text as Markdown" picker lists them after Markdown (`TextExportWriters.all`: ids, names, and hints unchanged), then "WebVTT", then "SubRip".
2. With a text writer chosen, the Transcript checkbox exports only the transcript's text, its content.md walked and written by that writer, as "<stem> - Transcript.<the writer's extension>" (the item's Markdown file, converted as "Text as …" converts a text book's); transcript.json is not exported then.
3. Its label is "Transcript as <writer name>" with no size (as a converted text's), and its hint "The transcript's text as <writer name>, made from the Markdown TextMouth reads it from." The writer's options view (a braille writer's, say) shows under the transcript's picker while it is chosen and the kind is checked, exactly as under the text's picker; the options state is the writer's one state for the dialog (`optionsStates[id]`), shared by both pickers.
4. `BookExportConversion.applies(to:)`: `.text` applies to `.markdown` and to `.transcript`; `files(of:for:conversions:)` gives the transcript, under `.text`, only its Markdown file converted (item 2). `convertsText` stays true for `.markdown` alone, so every existing test of it stays as it is.
5. Nothing else changes: the text kinds' choices, the default, and WebVTT and SubRip.

## Tests (more of TranscriptExportTests)
- the transcript's choices (item 1): the first and the last two pinned, the middle equal to `TextExportWriters.all` mapped as `BookExportConvertToTests` maps them;
- the label and hint with "HTML" (item 3);
- a real export with "html" chosen for the transcript of an installed transcript: exactly "<stem> - Transcript.html", whose text holds the transcript's sentences;
- with a braille writer chosen (look up its id in `TextExportWriters.all`), `optionsView(for: .transcript)` is not nil while checked, and nil while unchecked.

Run: `TranscriptExportTests BookExportConvertToTests BookExportConversionTests BookExportServiceTests BookExportSheetTests BrailleExportWriterTests`.
