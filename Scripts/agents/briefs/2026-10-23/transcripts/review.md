# Brief: `transcripts-review`, a bug hunt through transcription (T5)

You are `transcripts-review`, an Opus reviewer on team `transcripts`, lead `transcripts-lead`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display. The user is about to install 0.2.0 and wants it "as stable as you can make it". Your job is to find real bugs in the transcription feature, by reading, and report them with evidence. This round you change nothing.

## Ground rules
- Branch: `git checkout -b transcripts/review team/transcripts` in your worktree. You commit nothing this round.
- Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register transcripts-review --role "Opus reviewer: bug hunt through transcription (T5)" --branch transcripts/review --team transcripts --files none`.
- **Read only.** No builds, no tests, no edits. Read files by line range (`sed -n`), grep with several patterns at once, and read only what a question needs.
- Never touch `~/.TextMouth`. Never run anything that plays sound or records.

## What to read
- Services: `TextMouth/Services/Transcript*.swift` and `TextMouth/Services/Transcription*.swift` (TranscriptStore, TranscriptEdit, TranscriptEditAlignment, TranscriptCleanup, TranscriptCleanupStore, TranscriptCleanupRuleFile, TranscriptDeletion, TranscriptInstallation, TranscriptTextBuilder, TranscriptTextLoader, TranscriptSentenceBuilder, TranscriptAccuracy, TranscriptionService, TranscriptionEngine, TranscriptionAvailability, TranscriptionModelInstaller).
- View models: `TextMouth/ViewModels/TranscriptionJobCenter.swift`, `TranscribedBooks.swift`, `TranscriptionSheetModel.swift`, `TranscriptCleanupSheetModel.swift`, `TranscriptionOffers.swift`, `ReaderViewModel+Transcript.swift`.
- Views: `TextMouth/Views/Transcription/` (sheets, presentation, settings section).
- Edit Text: `TextMouth/Services/BookTextEditor.swift`, `BookTextEditing.swift`, `PackageFileEditing.swift`.
- Export of a transcript: `TextMouth/Services/BookExportService.swift` (`transcriptItem`).
- Feed episodes: `TextMouth/Services/Feeds/FeedItemPackage.swift`, `FeedLifecycle.swift` (`deleteDownload`, `removeDownload`, the sweep), `TextMouth/ViewModels/LibraryViewModel+Feeds.swift` (`removeFeedFiles`, `feedBooksInUse`), `TextMouth/Models/FeedBookUse.swift`.
- The design decisions, gitignored, in the main checkout: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TRANSCRIPTION-RESEARCH-2026-10-03.md` and `TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md`. Skim their decisions only.

## What to look for
Areas: transcribing, the job center, the transcript store, Edit Text's alignment, cleanup, deletion, export, feed episodes, the cloud (files only in iCloud, never downloaded by a read), and cancelling. Look for:
- data loss: a transcript, an edit, or a cleanup lost or silently not applied; a write that is not atomic; an edit taken against the wrong transcript;
- races: a transcription, cleanup, or deletion finishing after the book moved, was renamed, left the library, or its reader closed; two operations on one book at once; cancellation that leaves a half-written file, a stale "transcribing" state, or a job center stuck;
- traps: an unguarded subscript, a force unwrap, integer overflow on a value read from a file (transcript.json is untrusted: counts, offsets, times), an index out of range in the alignment;
- wrong state shown: a library row or reader that says a book is transcribed when it is not, or the reverse; a command offered that then refuses;
- the cloud: any read that would download a dataless file;
- VoiceOver: a result or failure that is never announced.

## Questions the lead needs answered
The lead is about to make these changes alongside you; check the code they rest on.
1. **Edit Text on a feed episode.** Edit Text is about to be offered for a feed episode's transcript (today `BookTextEditor.canEditText(of:isTranscribed:)` refuses every feed item). When a feed rule (played, or outside the newest N) deletes the episode's download while its transcript is open in an editor, the row moves to its feed's shelf and the package stays with its transcript. Does the Edit Text session then end (`BookTextEditor.check` finds no row), so a later save is never taken? Where does that save go, and is the listener told? Is the edit kept (`.edited-` copy) when the episode is downloaded again? Propose the smallest safe mitigation.
2. **Clean Up on a feed episode.** Clean Up Transcript is about to be offered for a feed episode too. What happens if the download is deleted, or the episode moves to the library (Move to Library…), while the Clean Up sheet is open or applying?
3. **Anything that assumes a feed item's transcript is never edited or cleaned up** (for example code paths that skip feed items, or the kept-package rules in `FeedItemPackage`).
4. **Retranscribing** a book whose transcript was edited or cleaned up: is the warning shown, does the new transcript replace the old cleanly (cleanup history, kept copies, the transcript layer of the content index), and does an open reader follow?
5. **Export of a transcript** while the book is being transcribed or cleaned up.

## Your report (your final message, at most 70 lines)
- Each confirmed bug: a one-line title; severity (data loss, crash, wrong behavior, cosmetic); the file and line range; the scenario that triggers it; what happens; the smallest fix; the test that would pin it.
- Then the answers to the five questions, each in a few lines.
- Then anything suspicious you could not confirm, labelled as such.
- Post `done: transcripts/review` to `transcripts-lead` (`bbs post transcripts-review --to transcripts-lead --topic "done: transcripts/review"`) and release your claims.

The lead may ask you, in a second round by message, to fix some of what you found on your branch, with tests; then the team's common rules for workers apply (`Scripts/agents/briefs/2026-10-19/teams-common.md`, "The worker's part" and "Builds").
