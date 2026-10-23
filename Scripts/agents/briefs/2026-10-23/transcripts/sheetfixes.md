# Brief: `transcripts-sheetfixes`, three small fixes the review found in the transcription sheets (T5)

Worker slug `transcripts-sheetfixes`, branch `transcripts/sheetfixes` (`git checkout -b transcripts/sheetfixes team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Three commits, one per fix; about 90 changed lines besides tests.

## Why (the team's reviewer confirmed each)
1. **A Clean Up sheet reads the book where it was.** `TranscriptCleanupSheetModel.examine()` (`TextMouth/ViewModels/TranscriptCleanupSheetModel.swift` 212-235) reads the transcript from `self.book`, the book as the sheet was opened; Apply and Undo already take the book as the library holds it now. A sheet left open while the book moved (Move to Library… of a feed episode, a move between folders) then says the book has no transcript when it comes back to TextMouth and examines again.
2. **Retranscribing replaces more than the sheet says.** The Transcribe Audio sheet warns that transcribing again replaces the user's edits (`editedLine`, `TranscriptionSheetModel.swift` 352-357), but not a cleanup; and a transcript only in iCloud, or one written by a later TextMouth, reads as no transcript at all (lines 252-254 keep `existing` only for `.found`), so the sheet says "Transcribe", warns of nothing, and the install replaces it unseen.
3. **Apply offered, then refused.** A cleanup rule that turns a sentence holding only its word into white space (a rule "um" to " ", or to nothing) leaves a sentence with no text; Apply is offered, then the install fails with "the transcript is not usable" (`TranscriptCleanup.cleaned(_:)`, `TextMouth/Services/TranscriptCleanup.swift` 100-112, and `Transcript.validationFailure`).

## Read first (by line range)
- `TextMouth/ViewModels/TranscriptCleanupSheetModel.swift` 140-170 and 210-245.
- `TextMouth/ViewModels/TranscriptionSheetModel.swift` 136-150 (`ExistingTranscript`), 236-262 (`load`), 296-312 (`heading`), 340-400 (the lines, `readyLines`, `transcribeTitle`).
- `TextMouth/Models/TranscriptionWording.swift` 140-175 (`alreadyTranscribed`, `editedTranscript`, `day`).
- `TextMouth/Models/Transcript.swift` 40-60 (`cleanedUp`, `TranscriptCleanupNote`) and the sentence checks of `validationFailure`.
- `TextMouth/Services/TranscriptCleanup.swift` 60-130 (`preview`, `cleaned`).

## The fixes
1. `examine()` reads the transcript of the book as the library holds it now, `library?.bookByID(book.id) ?? book`, as `apply()` and `undo()` do, with a comment saying why.
2. In the Transcribe Audio sheet:
   - `ExistingTranscript` gains `var cleanedUpAt: Date? = nil`, set from the transcript's cleanup note (`transcript.cleanedUp`, its date), in `load`.
   - New `var cleanedLine: String?`: `TranscriptionWording.cleanedUpTranscript(on:)` when the transcript was cleaned up. It is shown and spoken where `editedLine` is (in `noticeLines` and `readyLines`), right after it.
   - A transcript only in iCloud (`.inCloud`) or of a layout this TextMouth does not read (`.unsupportedVersion`) counts as one the book has: a new `enum UnreadableTranscript { case inCloud, laterVersion }` kept in `var unreadableExisting: UnreadableTranscript?` (published as `existing` is), and `var hasTranscript: Bool { existing != nil || unreadableExisting != nil }`, which `heading` and `transcribeTitle` use where they test `existing` today ("Retranscribe …" and "Retranscribe"). `existingLine` says, for such a transcript, `TranscriptionWording.transcriptInCloud` or `TranscriptionWording.transcriptFromLaterVersion`. A transcript that is `.unusable` stays as today (it was set aside already).
   - New wording in `TranscriptionWording`, next to `editedTranscript`, exactly:
     - `static func cleanedUpTranscript(on date: Date) -> String`: `"You cleaned up this transcript on \(day(date)). Transcribing again replaces the cleanup."`
     - `static let transcriptInCloud = "This book has a transcript that is only in iCloud. Transcribing again replaces it."`
     - `static let transcriptFromLaterVersion = "This book has a transcript made by a later version of TextMouth. Transcribing again replaces it."`
3. `TranscriptCleanup` never leaves a sentence without text: a sentence whose cleaned text would hold nothing but white space keeps its text unchanged, and its changes are neither listed nor counted in the preview (so Apply is not offered for them alone). Do it in the one place the cleaned text of a sentence is decided (`cleaned(_:)`, returning the text unchanged with no corrections or examples), with a comment.

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`), each doc commented
- `TranscriptCleanupSheetTests`: a sheet whose book moved after it opened (the library's row given a new package place, the transcript moved with it) examines the transcript where it is now and is ready, not unavailable.
- `TranscriptionSheetTests`: a cleaned-up transcript's sheet has `cleanedLine` (the exact sentence, for a fixed date) in `noticeLines` and `readyLines`; a transcript the stand-in reads as `.inCloud` gives the heading "Retranscribe <title>", the button "Retranscribe", and `existingLine` the iCloud sentence; `.unsupportedVersion(99)` gives the later-version sentence; `.unusable` stays "Transcribe".
- `TranscriptCleanupTests`: with a rule from "um" to nothing (and one to " "), a sentence "Um" keeps its text and counts no correction, while "Well um yes" is cleaned as today; a transcript of only such sentences previews no change.
- Each new sentence pinned as a literal string.

Run: `python3 Scripts/test/run-area.py TranscriptCleanupSheetTests TranscriptionSheetTests TranscriptionSheetViewTests TranscriptCleanupTests TranscriptCleanupRuleFileTests TranscriptEditTests`, then `python3 Scripts/test/run-area.py transcripts`. Add no test file.

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-sheetfixes --timeout 240`, never a sleep loop. Write all three commits before your first build.

## Do not touch
Another worker is changing, in the same two model files, the injected services (`endTextEdit` becomes `pauseTextEdit` and `resumeTextEdit`) and the bodies of `apply()` and `undo()`: leave those regions as they are. Not `BookTextEditor.swift`, `TranscriptEdit.swift`, `TranscriptTextLoader.swift`, the feeds, the reader, the export, or any `*.md`.

## Completion check
`grep -n "let book = self.book" TextMouth/ViewModels/TranscriptCleanupSheetModel.swift` finds nothing.
