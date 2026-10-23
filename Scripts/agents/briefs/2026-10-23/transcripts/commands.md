# Brief: `transcripts-commands`, edit a feed episode's transcript, and Retranscribe Audio… (T1 and T4)

Worker slug `transcripts-commands`, branch `transcripts/commands` (`git checkout -b transcripts/commands team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Two commits: T1, then T4. About 120 changed lines besides tests.

## Why
The user, October 23: "I transcribed episode 378 of Finish it at random and can't find the option to edit transcript which I thought was a thing … Also call the menu item "retranscribe audio" or similar if there is already a transcript". On October 7 the user decided feed items are not editable (FR11, question 4 of `humanQuestions/2026-10-07-late.md`: an episode or article in its feed lost Edit Audio, Edit Text, Clean Up Transcript, and Book Info's editing). A transcript is the listener's own work, so now an episode's transcript can be edited and cleaned up; an article's text (the feed's own content) and an episode's audio still cannot. The transcript is safe to edit because a feed item's package stays, with its transcript, when its download is deleted by a rule or by Delete Download (`FeedItemPackage.holdsListenersFiles`, `staysWithoutTheFile`); only Delete Episode, Delete Feed, and Delete Transcript delete it, and each asks first.

## Read first (by line range)
- `TextMouth/Services/BookTextEditor.swift` 130-160 (`canEditText`), 204-212 (`end`), 236-262 (`handle`).
- `TextMouth/Models/LibraryAudioCommand.swift`, all 93 lines.
- `TextMouth/Views/Reader/ReaderBookCommands.swift` 115-160.
- `TextMouth/App/MenuCommands.swift` 563-650 (`BookCommands`).
- `TextMouth/Views/Transcription/TranscriptionPresentation.swift` 90-135.
- `TextMouth/Models/TranscriptionWording.swift` 1-45 and 140-155; `TextMouth/Models/BookTextEditWording.swift` 42-50.
- `TextMouth/ViewModels/TranscriptionSheetModel.swift` 296-306 and 390-396.
- `TextMouth/ViewModels/TranscriptCleanupSheetModel.swift` 120-160 and 245-312; `TextMouth/Views/Transcription/TranscriptCleanupSheet.swift` 85-105.

## Commit 1, T1: a feed episode's transcript can be edited and cleaned up
1. `BookTextEditor.canEditText(of:isTranscribed:)` becomes `!book.tmbDirectoryName.isEmpty && (book.format.isAudio ? isTranscribed : !book.isFeedItem)`. Rewrite its doc comment: a text book's text, and any transcribed audiobook's transcript text, an episode's in its feed included (the user's request of October 23, 2026); never a feed article's text, which belongs to its feed (FR11, question 4). An episode's edit is kept in its transcript, which stays in the episode's package when its download is deleted (`FeedItemPackage`), and goes only with Delete Episode, Delete Feed, or Delete Transcript.
2. `LibraryAudioCommand.isTranscriptCleanable(_:)` becomes `isTranscribable(book)`. Rewrite its doc and the docs that say a feed's episode is never cleaned up: the `cleanUpTranscript` case (lines 15-18), `commands(for:isTranscribed:)` (lines 42-50), and `isAudioEditable` stays as it is (Edit Audio is still withheld from a feed's episode). In `ReaderBookCommands.swift`, replace the comment at lines 130-131 ("An episode's or article's transcript, in its feed, is not cleaned up (FR11): only made again or deleted.") with one saying a transcribed audiobook's transcript is cleaned up, an episode's in its feed included. In `TranscriptionPresentation.swift` update the doc near line 118 that names a feed's episode as an example of a book Clean Up refuses; keep the guard (it still refuses a book without a package).
3. New wording, `TranscriptionWording.feedEpisodeTranscriptNote`, exactly:
   `"This episode's transcript, with your changes, stays with the episode in its feed, even after its download is deleted. Deleting the episode or the feed deletes it; Move to Library keeps it with the episode as a book."`
4. New wording, `BookTextEditWording.updatedInFeed`, exactly `updated + ". " + TranscriptionWording.feedEpisodeTranscriptNote` ("Text updated. This episode's transcript, …").
5. `BookTextEditor`: the first edit taken (`handle`, case `.adopted`) in a session of a book whose row is a feed item (`library?.bookByID(bookID)?.isFeedItem`, read before `commitTextEdit`) announces `updatedInFeed`; every later edit taken in that session announces `updated`, as today. Keep the books told in `private var announcedFeedNotes: Set<UUID>`, removed in `end(_:)` beside `announcedRefusals` and `announcedCopies`. A book that is not a feed item always hears `updated`.
6. `TranscriptCleanupSheetModel` gains `var feedNoteLine: String?`: `TranscriptionWording.feedEpisodeTranscriptNote` when `book.isFeedItem`, else nil (doc comment it). `TranscriptCleanupSheet.readyLines` shows it right after the experimental line, as a `Text` with `.fixedSize(horizontal: false, vertical: true)`. The model's list of the lines VoiceOver hears together (around line 310) includes it right after the experimental line.

## Commit 2, T4: Retranscribe Audio… once a book has a transcript
7. `TranscriptionWording`: add `static let retranscribeCommandTitle = "Retranscribe Audio…"` (the ellipsis is the one character "…", as in `transcribeCommandTitle`), and `static func transcribeCommandTitle(hasTranscript: Bool) -> String`, which returns it or `transcribeCommandTitle`. Add `static func retranscribeSheetTitle(bookTitle: String) -> String` returning `"Retranscribe \(bookTitle)"`. Change `transcribeAgainTitle` from "Transcribe Again" to `"Retranscribe"`. Doc comment each.
8. `LibraryAudioCommand` gains `case retranscribe(Book)`: Retranscribe Audio…, for one audiobook in a package of its own that has a transcript, opening the Transcribe Audio sheet as `transcribe` does for one book. `title` returns `TranscriptionWording.retranscribeCommandTitle` for it. `commands(for:isTranscribed:)` appends `.retranscribe(book)` instead of `.transcribe(targets)` when the row acts on one book alone that is transcribable and transcribed; otherwise `.transcribe(targets)` as today (several books, one of them transcribed, still get `.transcribe(targets)`, which refuses with `oneBookAtATime`). Update the docs. `TranscriptionPresentation.perform` handles `.retranscribe(let book)` exactly as `.transcribe([book])`. Make every `switch` over `LibraryAudioCommand` handle the new case. The context menu and the row's VoiceOver actions both list `audioCommands` (`LibrarySubviews.swift` 550 and 969), so both follow without change.
9. `BookCommands` (the reader's Book menu): the Transcribe button's title is `TranscriptionWording.transcribeCommandTitle(hasTranscript: canDeleteBookTranscript == true)`, with a comment that Delete Transcript… is available exactly while the key reader's book has a transcript (`ReaderBookCommandsSupport.hasTranscript`). Update the struct's doc comment to mention Retranscribe Audio….
10. `TranscriptionSheetModel.heading`: while not transcribing, `retranscribeSheetTitle` when the book has a transcript (`existing != nil`, as `transcribeTitle` decides), else `sheetTitle` as today. The progress heading and every other line stay.

## Tests (no test may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`)
Exact-output tests you may change, and only as said:
- `LibraryFeedItemEditTests.testEditTextIsNotOfferedForAFeedItem` becomes `testEditTextIsOfferedForAFeedEpisodesTranscriptOnly`: an article false, an untranscribed episode false, a transcribed episode true, a library book true.
- `FeedItemUIBookInfoTests.testAFeedItemsTranscriptIsNotCleanedUp` becomes `testAFeedEpisodesTranscriptCanBeCleanedUp`: `isTranscriptCleanable(episode)` true, `isAudioEditable(episode)` false, and the transcribed episode's commands are `[.retranscribe(episode), .cleanUpTranscript(episode), .deleteTranscript(episode)]`.
- `TranscriptCleanupSheetTests.testTheCommandOpensNoSheetForAFeedsEpisode` becomes `testTheCommandOpensTheSheetForAFeedsEpisode`: both routes open a sheet, and its model's `feedNoteLine` is the note.
- `TranscriptDeletionTests` line 28 and `TranscriptCleanupSheetTests` line 33: `.transcribe([book])` becomes `.retranscribe(book)` for the transcribed book; nothing else in those arrays.
- `TranscriptionSheetTests` line 306 and `TranscriptEditTests` line 309: "Transcribe Again" becomes "Retranscribe".

New tests, each with a doc comment:
- In `TranscriptionSheetTests`: the titles (`.retranscribe(book).title == "Retranscribe Audio…"`, `.transcribe([book]).title == "Transcribe Audio…"`, `transcribeCommandTitle(hasTranscript:)` both ways); the commands for an untranscribed audiobook (`.transcribe`), a transcribed one (`.retranscribe`), and two books one of them transcribed (`.transcribe` of both); `perform(.retranscribe(book))` opens the sheet, as the existing test of `.transcribe` does; the ready sheet's heading reads "Retranscribe <title>" for a transcribed book and "Transcribe <title>" for one without.
- In `TranscriptEditTests`: Edit Text of a feed episode's transcript, modelled on `testAnEditOfATranscribedAudiobookIsTakenIntoItsTranscript` (lines 178-221), with the book given a `feedLink` as `FeedItemUIBookInfoTests.testTheReadersBookInfoOfAFeedItemIsReadOnly` (line 113) makes a feed item the library and a reader both find. Two saves in one session: VoiceOver hears `[BookTextEditWording.updatedInFeed, BookTextEditWording.updated]`, and the transcript took both edits. Write each edit with the file's own escaping, through the file's `replacing` helper, as the existing test does.
- Pin the two new sentences as literal strings, where the existing wording tests of each file are.

Run: `python3 Scripts/test/run-area.py LibraryFeedItemEditTests FeedItemUIBookInfoTests TranscriptCleanupSheetTests TranscriptDeletionTests TranscriptionSheetTests TranscriptionSheetViewTests TranscriptEditTests BookTextEditTests LibraryFeedAudioEditTests KeyboardReachabilityTests`, then `python3 Scripts/test/run-area.py transcripts`. Add no test file (so no `xcodegen`).

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-commands --timeout 240`, never a sleep loop.

## Do not touch
`BookSearchView.swift`, `ReaderView.swift`, the export files, `MarkdownLiteral.swift`, `TranscriptTextBuilder.swift` (other workers' files), any `*.md`, and `FeedBookUse`/`LibraryViewModel+Feeds.swift` (the reviewer is studying them). Do not change what a feed article's Edit Text, or a feed episode's Edit Audio, does.

## Completion check
`grep -rn "not cleaned up (FR11)\|never an episode in its feed\|Transcribe Again" TextMouth TextMouthProductionTests` finds nothing.
