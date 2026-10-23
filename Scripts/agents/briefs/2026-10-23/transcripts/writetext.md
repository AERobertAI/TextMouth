# Brief: `transcripts-writetext`, nothing the user saved in a transcript's text is lost (T5 fixes 2 and 5)

Worker slug `transcripts-writetext`, branch `transcripts/writetext` (`git checkout -b transcripts/writetext team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Two commits, as below; about 130 changed lines besides tests.

## Why (the team's reviewer confirmed each)
A transcribed audiobook's content.md is written from its transcript.json (`TranscriptTextLoader.writeText`, `TextMouth/Services/TranscriptTextLoader.swift` 245-298). Edit Text takes an edit of it into transcript.json (`TranscriptEdit.apply`, `TranscriptEdit.swift` 40-110), aligning only the transcript's sentences.
1. **Edits outside the sentences are announced as taken, then vanish.** A renamed heading, or words typed into a chapter the recognizer heard nothing in, are not in transcript.json, yet the user hears "Text updated", and the layer's digest then names the user's own content.md. The next rewrite from transcript.json (Clean Up, Undo Cleanup, a change of the layer's version, a transcript.json synced from another Mac) compares content.md with that digest, finds it the same, and replaces it with no copy kept.
2. **A rewrite can download a file, or replace one without keeping it.** `writeText` reads content.md with a plain `Data(contentsOf:)` (line 280), which downloads a file that is only in iCloud (TextMouth must never download one by reading it); offline it reads nothing and keeps no copy. A copy that cannot be kept (`keepUnwrittenText`, line 353) is only logged, and the file is replaced anyway. `TranscriptStore.install` (`TranscriptInstallation.swift` 35-84; Transcribe Again, Clean Up, Undo Cleanup) writes transcript.json before content.md and never checks that content.md is on this Mac.

## Read first (by line range)
- `TextMouth/Services/TranscriptEdit.swift` 1-120 and 140-214.
- `TextMouth/Services/BookTextEditing.swift` 20-56 (`BookTextEditRefusal`) and 1085-1120 (where `TranscriptEditError` becomes a refusal).
- `TextMouth/Models/BookTextEditWording.swift` 52-110 (`refused`, `kept`).
- `TextMouth/Services/TranscriptTextLoader.swift` 194-300 and 345-392.
- `TextMouth/Services/TranscriptInstallation.swift` 20-84.
- `TextMouth/Services/TranscriptTextBuilder.swift` 236-300 (how content.md is written and read back).
- Tests: `TextMouthProductionTests/TranscriptEditTests.swift` 225-290 (a refusal kept beside content.md; the loader keeping unsaved text) and 345-420 (fixtures).

## Commit 1: refuse an edit the transcript cannot hold
1. `TranscriptEdit.apply` throws two new `TranscriptEditError` cases, checked before any sentence is aligned:
   - `headingChanged`: a chapter's heading in the edited text differs from the one the transcript's text gives that chapter (compare each chapter's heading text found by `headingRanges(in:)`, trimmed of surrounding white space, with the title `TranscriptTextBuilder` writes for it; a heading removed or added counts as changed);
   - `wordsWithoutSentences`: a chapter whose transcript has no sentences holds, outside its heading, anything but white space.
2. `BookTextEditRefusal` gains `headingChanged` and `wordsWithoutSentences` (both keep the earlier text, as `chaptersChanged` does), mapped from the errors where the others are (`BookTextEditing.swift` near 1097). `BookTextEditWording.refused` words them, exactly:
   - `"Text not updated: the edited transcript of \(bookTitle) changes a chapter's heading, which comes from its audio. Put the heading back as it was and save again; until then, the book keeps the text it had."`
   - `"Text not updated: the edited transcript of \(bookTitle) adds words to a chapter the transcript heard no speech in, where they can't be kept. Remove them and save again; until then, the book keeps the text it had."`
   As every refusal is, the edited text is kept beside content.md and its place named after the sentence (`notTaken`). Add each case to every `switch` over `BookTextEditRefusal`.

## Commit 2: write the text again without losing or downloading anything
3. `TranscriptTextError` gains, with these descriptions exactly:
   - `textOnlyInCloud`: `"The book's text is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again."`
   - `textNotKept`: `"The book's text holds changes TextMouth couldn't keep a copy of, so it leaves the text as it is."`
4. `writeText`:
   - Before reading content.md, when it is only in the cloud (`DatalessFiles.isDataless`, through a parameter defaulting to it, so a test can say so), throw `textOnlyInCloud`: nothing is read, downloaded, or written.
   - Keep the existing content.md beside itself first, as today (`keepUnwrittenText`), when its bytes differ from the new bytes and either its digest differs from `writtenDigest` (today's rule) or the transcript has been edited (`transcript.editedAt != nil`) and its reading text differs from the new text's. Reading text means content.md parsed as the builder reads it back (`MarkdownCacheService.parseMultiChapterMarkdown`): each chapter's title and text, with every run of white space taken as one space. So a heading renamed, or words outside the sentences, saved before step 1 refused them, are kept, while a content.md that differs only in its escaping or its paragraph breaks keeps no copy.
   - When a copy is needed and cannot be kept, throw `textNotKept` before writing anything: content.md stays as it was. `keepUnwrittenText` returns whether it kept the copy (through a parameter defaulting to `BookTextEditSessions.keepCopy(of:bytes:)`, so a test can make it fail); keep its log line.
5. `TranscriptStore.install` checks, before it writes transcript.json, that the book's content.md is not only in the cloud (the same check, the same error), so a refusal leaves transcript.json as it was too.
6. Update the doc comments of `writeText`, `keepUnwrittenText`, and `install` to say all this.

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`), each doc commented
- In `TranscriptEditTests`, modelled on `testAnEditChangingTheChaptersIsRefusedAndKept` (line 230): an edit that renames a chapter's heading is refused (the transcript is unchanged, the edited text is kept beside content.md, VoiceOver hears the new sentence with where it was kept); an edit adding words to a chapter without sentences is refused the same way (a fixture whose second file has no sentences, as `TranscriptionUIScripts.twoTracks` but with `"02.wav": []`); an edit that changes only sentences is still taken.
- In `TranscriptTextTests`:
  - an edited transcript (`editedAt` set) whose content.md holds a renamed heading, with the layer's digest naming that content.md (as a taken edit leaves it): `install` of a cleaned-up copy keeps the old content.md beside it (one `.edited-` copy) before writing;
  - the same with a content.md that differs only in escaping (a `\.` written as `.` mid-line) keeps no copy;
  - a content.md only in the cloud (the parameter says so): `writeText` throws `textOnlyInCloud`, and content.md's bytes are unchanged; `install` throws it too and leaves transcript.json unchanged;
  - a copy that cannot be kept (the parameter fails): `writeText` throws `textNotKept` and content.md is unchanged.
- Each new sentence pinned as a literal string.

Run: `python3 Scripts/test/run-area.py TranscriptEditTests TranscriptTextTests BookTextEditTests TranscriptCleanupTests TranscriptCleanupStoreTests TranscriptCleanupSheetTests TranscriptDeletionTests`, then `python3 Scripts/test/run-area.py transcripts`. Add no test file.

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-writetext --timeout 240`, never a sleep loop. Write both commits before your first build.

## Do not touch
`BookTextEditor.swift`, the cleanup sheet model, the job center, `TranscriptionPresentation.swift` (another worker's), `TranscriptTextBuilder.swift` beyond reading it, `MarkdownLiteral.swift`, the feeds, and any `*.md`. In `BookTextEditWording.swift` change only `refused` and its doc.

## Completion check
`grep -n "Data(contentsOf: cacheURL)" TextMouth/Services/TranscriptTextLoader.swift` finds no read that the dataless check does not come before.
