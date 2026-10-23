# Brief: `transcripts-textescape`, a transcript's content.md escapes only what TextMouth's reader needs (T3, part 2)

Worker slug `transcripts-textescape`, branch `transcripts/textescape` (`git checkout -b transcripts/textescape team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. One commit, about 30 changed lines besides tests.

## Why
A transcribed audiobook's content.md is its transcript's text, and Edit Text now opens it for every transcribed audiobook, a feed episode's included (task T1, on the team branch). Today `TranscriptTextBuilder.markdown(of:)` (`TextMouth/Services/TranscriptTextBuilder.swift` 236-252) escapes every ASCII punctuation character (`MarkdownLiteral.escaped`), so the user's editor and braille display show "Rope coils dry on the pier\." and "Gannet wings\, folded\.". Task T3's first part (on the team branch) added `MarkdownLiteral.minimallyEscaped(_:smartPunctuation:)` and `MarkdownLiteral.guardingLineStart(_:)` (`TextMouth/Parsers/MarkdownLiteral.swift`): with `smartPunctuation: true` they escape only what TextMouth's own reader needs, which substitutes curly quotes, dashes, and ellipses, so quotes, apostrophes, and runs of `-` or `.` stay escaped and commas, single periods, colons, question marks, and the rest do not. A transcript's text counts time, not characters, so changing how it is written is safe; a text book's content.md is not touched (that would re-read the whole library).

The transcript layer of a book's index carries a version for exactly this (`BookContentTranscriptIndex.currentVersion`, `TextMouth/Models/TranscriptTextIndex.swift` 20-48): "A change to either changes this version, and each transcribed book's text is then written again from its transcript.json as it opens." Writing again keeps every edit Edit Text took (they are in transcript.json) and keeps a hand edit it did not take beside content.md first (`TranscriptTextLoader`, its doc at lines 1-21).

## Read first (by line range)
- `TextMouth/Services/TranscriptTextBuilder.swift` 230-300.
- `TextMouth/Models/TranscriptTextIndex.swift` 18-104.
- `TextMouth/Parsers/MarkdownLiteral.swift` (the two new functions and their docs).
- `TextMouthProductionTests/TranscriptTextTests.swift` 110-200 and 390-440.

## The change
1. `TranscriptTextBuilder.markdown(of:)`: a chapter's heading is `"# " + MarkdownLiteral.minimallyEscaped(title, smartPunctuation: true)`; a paragraph is its sentences' texts joined with one space first, then written as one line, `MarkdownLiteral.guardingLineStart(MarkdownLiteral.minimallyEscaped(joined, smartPunctuation: true))`. The chapter marker line stays as it is. Rewrite the function's doc comment (and the type's, where it says every character is escaped) to say what is escaped and why: TextMouth's reader reads the text back as exactly the transcript's characters, so each sentence is found where it lies (`locate`).
2. `BookContentTranscriptIndex.currentVersion` becomes `"1.1.0"`. Extend its doc comment with one line: 1.1.0 (October 23, 2026) escapes only what the reader needs, so a transcript's text reads in an editor as it was heard; every transcribed book's text is written again once as it opens. Nothing else in the layer changes.

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`)
Exact-output tests you may change, and only as said:
- `TranscriptTextTests.testContentMarkdownHasAHeadingPerChapterAndAParagraphPerFewSentences`: its expected content.md loses the backslashes before the single periods ("One. Two. Three. Four."); nothing else in it changes.
- Edits written against a transcript's content.md with `MarkdownLiteral.escaped(...)`: `TranscriptEditTests` lines 129 and 192-193, `BookTextEditTests` line 907, and any such line in the feed-episode test `transcripts-commands` added to `TranscriptEditTests`: write them with `MarkdownLiteral.minimallyEscaped(_, smartPunctuation: true)`, the builder's own escaping, and fix the `replacing` helper's doc comment, which says content.md escapes every sentence's punctuation. Find every such line with `grep -n "MarkdownLiteral.escaped" TextMouthProductionTests/TranscriptEditTests.swift TextMouthProductionTests/BookTextEditTests.swift`; a line there that edits a text book's content.md stays as it is.
- Any test that builds a `BookContentTranscriptIndex` with version "1.0.0" written out as a literal, when it means the current version: use `BookContentTranscriptIndex.currentVersion`.
`TranscriptTextTests.testTheTextReadsBackExactlyWithEverySentencePlaced` (its tricky sentences: headings, stars, lists, markup, pipes, quotes, dashes, ellipses, backslashes, ampersands) must pass unchanged: it is the proof.

New tests in `TranscriptTextTests`, each doc commented:
- content.md of a chapter whose sentences hold commas, single periods, a colon, a question mark, an apostrophe, quotation marks, "--", "...", a `#`, a `*`, and a paragraph that begins "1." is pinned exactly, with backslashes only where the rules put them, and `TranscriptTextBuilder.text(of:bookTitle:bookAuthor:)` places every sentence (none left out).
- A book whose saved layer is version "1.0.0" with a fully escaped content.md (install a transcript, then rewrite the layer's version to "1.0.0" and content.md to what `MarkdownLiteral.escaped` wrote, as `testALostLayerIsMadeAgainFromTheTranscript` (lines 393-410) rewrites its layer): `TranscriptTextLoader.load` writes content.md again, without the needless backslashes, logs TRANSCRIPT_TEXT_REBUILT once, gives the layer version "1.1.0", and the transcript.json is unchanged; a second load writes nothing.

Run: `python3 Scripts/test/run-area.py TranscriptTextTests TranscriptEditTests BookTextEditTests TranscriptCleanupTests TranscriptCleanupSheetTests TranscriptDeletionTests TranscriptSearchTests BookExportServiceTests`, then `python3 Scripts/test/run-area.py transcripts`. Add no test file.

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-textescape --timeout 240`, never a sleep loop.

## Do not touch
`MarkdownLiteral.swift` (ask the lead if a rule there looks wrong), any writer of a text book's content.md, `MarkdownCacheService`, the reader, the export, and any `*.md`.

## Completion check
`grep -n "MarkdownLiteral.escaped" TextMouth/Services/TranscriptTextBuilder.swift` finds nothing.
