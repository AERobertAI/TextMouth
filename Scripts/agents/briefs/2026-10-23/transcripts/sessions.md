# Brief: `transcripts-sessions`, Edit Text's session and the changes that rewrite a transcript (T5 fixes 1 and 3)

Worker slug `transcripts-sessions`, branch `transcripts/sessions` (`git checkout -b transcripts/sessions team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Two commits, as below; about 120 changed lines besides tests.

## Why (the team's reviewer confirmed each)
Four changes rewrite a transcribed audiobook's transcript: Clean Up's Apply and Undo Cleanup (`TranscriptCleanupSheetModel.apply()` and `undo()`, lines 380-420), a new transcription's install (`TranscriptionJobCenter`, lines 205-220), and Delete Transcript (`TranscriptionPresenter.deleteConfirmed`, `TranscriptionPresentation.swift` 168-195). Each first ends the book's Edit Text session through an injected `endTextEdit` closure, which only drops the session (`BookTextEditor.end`, `BookTextEditor.swift` 206-216). So:
1. **A lost change.** A check of an edit already running on the sessions' queue (`BookTextEditSessions.check`, `BookTextEditing.swift` 405-455) still reads, aligns, and writes transcript.json, racing the change: an edit just announced as "Text updated" lands on a cleanup or a new transcript, or overwrites it, or brings a deleted transcript back. Nothing waits for it.
2. **Saves silently ignored.** When the change then fails (the transcript changed, the audio changed, a file error), the session stays ended, so the user's later saves in their editor are never taken, and nothing says so.
3. **A session that outlives its book.** `BookTextEditor.check(_:)` (lines 190-202) and `handle(.missing)` end a session whose book left the library (removed, or a feed episode whose download was deleted and whose row moved to its feed's shelf) without a word; the user's save is not taken and they are not told.

`BookTextEditSessions.settlePendingEdit(of:)` (`BookTextEditing.swift` 380-403) already waits for a running check and takes an edit saved but not yet checked; use it.

## Read first (by line range)
- `TextMouth/Services/BookTextEditor.swift` 100-262.
- `TextMouth/Services/BookTextEditing.swift` 370-403.
- `TextMouth/ViewModels/TranscriptCleanupSheetModel.swift` 1-60 (services) and 378-425.
- `TextMouth/ViewModels/TranscriptionJobCenter.swift` 135-225; `TextMouth/ViewModels/TranscriptionSheetModel.swift` 40-80 (services).
- `TextMouth/Views/Transcription/TranscriptionPresentation.swift` 160-195.
- `TextMouth/Models/BookTextEditWording.swift` 40-60.
- Tests: `TextMouthProductionTests/TranscriptionUITestSupport.swift` 120-165, `TranscriptCleanupSheetTests.swift` 495-520, `TranscriptEditTests.swift` 170-230 and 345-420 (`makeEditor`, `check`).

## Commit 1: settle, end, and begin again
1. `BookTextEditor` gains, each doc commented:
   - `func pauseEditing(of book: Book) async -> Bool`: when `book` is being edited, settles its pending edit off the main thread (`OffMainWork.run { sessions.settlePendingEdit(of: book) }`: a check already running finishes, and an edit saved but not yet checked is taken, committed, and announced as any taken edit is), then ends the session (`end(_:)`), and returns true; returns false at once for a book not being edited.
   - `func resumeEditing(of book: Book) async`: begins `book`'s session again after a change that `pauseEditing` paused has failed, from a fresh baseline read off the main thread as `edit(_:choosingApp:in:from:)` reads one, with no explanation and without opening the editor, so the user's next save is taken. When the baseline cannot be read, it announces `BookTextEditWording.cannotBegin(failure, bookTitle:)` as `edit` does.
2. Replace the injected `endTextEdit: @MainActor (UUID) -> Void` with two closures, in `TranscriptCleanupServices`, in the Transcribe Audio sheet's services (`TranscriptionSheetModel.swift` 56 and 74, which `TranscriptionPresenter.deleteConfirmed` uses), and in `TranscriptionJobCenter.init`: `pauseTextEdit: @MainActor (Book) async -> Bool` (live: `BookTextEditor.shared.pauseEditing(of:)`) and `resumeTextEdit: @MainActor (Book) async -> Void` (live: `BookTextEditor.shared.resumeEditing(of:)`). Update every test stand-in that passes `endTextEdit` (`grep -rn "endTextEdit" TextMouthProductionTests`): `TranscriptionUITestSupport.swift` 133, 150, 158 and `TranscriptCleanupSheetTests.swift` 511, recording the books paused and resumed where a test recorded the ends.
3. The four changes: take the book as the library holds it now, then `let wasEditing = await pauseTextEdit(book)` before anything is written; on success go on as today (the session stays ended, since the change rewrote the text it watched); when the change throws, `if wasEditing { await resumeTextEdit(book) }`, then report the failure as today. In the job center, pause just before the install (not before the minutes of transcription), with the install in a `do`/`catch` of its own that resumes and rethrows. Update the comment at each site.

## Commit 2: say when a session ends because its book is gone
4. `BookTextEditor` remembers each session's book title when the session begins (`private var sessionTitles: [UUID: String]`, from the library's row, removed in `end(_:)`). Where it ends a session because the library no longer lists the book (`check(_:)`, and `handle` for `.missing`), it first announces `BookTextEditWording.stoppedBookGone(bookTitle:)`, once, then ends it (one private function both call, DRY). A session ended for any other reason says nothing new.
5. `BookTextEditWording.stoppedBookGone(bookTitle:)`, placed right after `updatedInFeed`, exactly: `"Text not updated: \(bookTitle) was removed, or its download deleted, so Edit Text has stopped for it."`

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`), each doc commented
- In `TranscriptCleanupSheetTests`, with a real editor made as `TranscriptEditTests.makeEditor` makes one (copy the helper's few lines into this file) and the sheet's services pausing and resuming through it:
  - an edit saved in content.md but not yet checked, then Apply: the edit is taken first (transcript.json holds it), the cleanup is refused because the transcript changed (the phase is `.failed`), and the session is running again (`sessions.isEditing(book.id)`);
  - Apply with a session but no pending edit: the cleanup is applied, and the session has ended;
  - Undo Cleanup that fails resumes the session too.
- In `TranscriptDeletionTests` (or `TranscriptEditTests`): Delete Transcript with an edit saved but not yet checked takes the edit, then deletes the transcript, and ends the session.
- For the job center: an install that throws, with `pauseTextEdit` answering true, calls `resumeTextEdit` once with the book; one that succeeds calls it never (use the job center's existing test stand-ins).
- In `TranscriptEditTests`: a session whose book's row leaves the library: the next check announces `stoppedBookGone` with the book's title, once, and the session has ended; a second check says nothing.
- `stoppedBookGone("Ep. 378")` pinned as a literal string.

Run: `python3 Scripts/test/run-area.py TranscriptCleanupSheetTests TranscriptDeletionTests TranscriptEditTests BookTextEditTests TranscriptionSheetTests TranscriptionSheetViewTests TranscriptionProgressTests TranscriptionServiceTests TranscriptionOfferTests`, then `python3 Scripts/test/run-area.py transcripts`. Add no test file.

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-sessions --timeout 240`, never a sleep loop. Write both commits before your first build.

## Do not touch
`TranscriptEdit.swift`, `TranscriptTextLoader.swift`, `TranscriptInstallation.swift`, `BookTextEditing.swift` beyond reading it, the cleanup sheet's `examine()`, the Transcribe Audio sheet's existing-transcript lines (other workers' regions), the feeds, and any `*.md`. In `BookTextEditWording.swift` add only the one sentence, right after `updatedInFeed`.

## Completion check
`grep -rn "endTextEdit" TextMouth TextMouthProductionTests` finds nothing.
