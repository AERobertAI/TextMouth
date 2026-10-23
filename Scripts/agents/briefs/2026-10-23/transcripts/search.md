# Brief: `transcripts-search`, Search in Book searches a transcribed audiobook's transcript (T2)

Worker slug `transcripts-search`, branch `transcripts/search` (`git checkout -b transcripts/search team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Three commits, as below; about 170 changed lines besides tests.

## Why
The user, October 23: "I think there should be a implemented text search feature for transcribed books that searches the transcript and lets the user click on the results to go there". A VoiceOver user must be able to type a word, hear how many results there are, move through them, each read with its time and a few words around it, and press Return on one to jump to that place in the audio, announced, with Go Back returning.

Search in Book (Command-F, the reader's toolbar Search button, `BookSearchView` and `BookSearchModel`) already does all of this for a text book, and refuses an audiobook, whose chapters' text is only spacing that counts time. A transcribed audiobook's reader holds its transcript's text in `reader.content?.transcript` (`TranscriptText`, `TextMouth/Models/TranscriptTextIndex.swift` 200-312): its `chapters` (one per audio chapter, in order) and an index that gives each sentence's place in the text and its time in the chapter (`chapterTime(atTextOffset:inChapter:)`, `audioOffset(atTextOffset:inChapter:)`). Extend Search in Book to it; build no second search (DRY). The menu command stays Search in Book with its Command-F: a second command would duplicate it, which the user has asked never to do.

## Read first (by line range)
- `TextMouth/Views/Reader/BookSearchView.swift`: 95-160 (result, corpus, engine), 160-200 (`search`), 254-320 (the view's init and `locationTitles`), 322-450 (body), 452-527 (`SearchResultRow`).
- `TextMouth/ViewModels/BookSearchModel.swift` 95-120 (inits).
- `TextMouth/Views/Reader/ReaderView.swift`: 100-140 (toolbar), 480-530 (`searchSheet`), 600-640 (panel commands, `shouldAcceptPanelCommand`).
- `TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift` 205-260 (`navigateToSearchResult`, `navigatePreservingReturnPosition`, `returnToSavedPosition`).
- `TextMouth/Models/TranscriptTextIndex.swift` 215-312; `TextMouth/Parsers/AudioBookParser.swift` 8-18; `TimeFormatting` in `TextMouth/Models/DocumentContent.swift` 457-500.
- `TextMouth/Views/Reader/BookmarkPanelView.swift` 243-262 (how a row takes Return).
- `TextMouth/Views/ContentView.swift` 200-212 (the library's own Go Back).

## Commit 1: timed results for a transcript
1. In `BookSearchView.swift`, a new `struct BookSearchTiming: Sendable` beside `BookSearchCorpus`, doc commented: the transcript a search's chapter texts come from (`let transcript: TranscriptText`) and where each chapter begins, in seconds from the start of the book (`let chapterStarts: [TimeInterval]`). `func time(chapterIndex: Int, characterOffset: Int) -> TimeInterval` returns the chapter's start (0 for an index outside `chapterStarts`) plus `transcript.chapterTime(atTextOffset: characterOffset, inChapter: chapterIndex)`: the start of the sentence holding the match, which is also where a jump lands. `static func forTranscript(_ transcript: TranscriptText, audioChapters: [Chapter]) -> BookSearchTiming`: `chapterStarts[i]` is the sum, over the audio chapters before `i`, of `AudioBookParser.time(forCharacterOffset: chapter.text.utf16Length)` (an audiobook's chapter text is spacing of `ReaderViewModel.audioCharsPerSecond` characters a second).
2. `BookSearchCorpus` gains `var timing: BookSearchTiming? = nil` (a `var` with a default, so the memberwise init still compiles everywhere). `BookSearchResult` gains `var time: TimeInterval?`, nil unless timed. `BookSearchEngine.search` sets each result's `time` from `corpus.timing` after the location titles. `id` does not change.
3. `BookSearchResult` gains `var timedLabel: String?`: for a timed result, `"\(contextAndLocation), at \(TimeFormatting.spoken(time))"`; nil otherwise. The rotor entry (`accessibilityRotor`) uses `timedLabel ?? contextAndLocation`.

## Commit 2: the reader searches its transcript
4. `ReaderViewModel` (in `ReaderViewModel+Bookmarks.swift`, beside `navigateToSearchResult`):
   - `var canSearchText: Bool`: a text book with content, or an audiobook whose `content?.transcript` is not nil.
   - `var searchCorpus: BookSearchCorpus?`: for a text book, exactly what `searchSheet` builds today (chapter texts, chapter titles, `headings`, the book's title); for an audiobook with a transcript, the transcript's chapter texts, `content.chapters.map(\.title)` as titles, no headings (the reader's audiobook headings count audio time, not transcript text), the book's title, and `timing: .forTranscript(transcript, audioChapters: content.chapters)`; nil otherwise.
   - `func navigateToTranscriptSearchResult(chapterIndex: Int, textOffset: Int)`: for an audiobook with a transcript, moves with `navigatePreservingReturnPosition(chapterIndex:characterOffset:)` to `transcript.audioOffset(atTextOffset:inChapter:)` (so the Return button and Go Back come back), then `autoPlayIfEnabled()`, and sets `pendingJumpAnnouncement` to `BookSearchWording.movedTo(time:location:)` with the time of `BookSearchTiming.forTranscript(...).time(...)` and the chapter's title as the location (nil when it is empty or equals the book's title, as `BookSearchView.locationTitles` decides with no headings: call it). Without a transcript it does nothing.
   - `var pendingJumpAnnouncement: String?` and `func announcePendingJump()`, which announces it with `announceToVoiceOver` and clears it.
   - `func goBack()`: with a saved position, `returnToSavedPosition()`; without one, `announceToVoiceOver(BookSearchWording.nothingToGoBackTo)`.
5. `ReaderView`:
   - The toolbar's Search button shows while `viewModel.canSearchText` (not `!viewModel.isAudioBook`); update the toolbar's doc comment ("a text book's only").
   - `.searchInBook`: when `canSearchText`, toggle the sheet as today; when the reader's book is an audiobook without transcript text, announce `BookSearchWording.noTranscript(bookTitle:)` instead (still only for the window that takes the command). Update the comment there.
   - `searchSheet` builds `BookSearchView` from `viewModel.searchCorpus` (a new `BookSearchView.init(corpus:totalCharacterCount:totalWordCount:currentWPM:announce:onNavigate:)`, which the existing init calls, so `A10AccessibilityTests` compiles unchanged). Its `onNavigate` calls `navigateToTranscriptSearchResult(chapterIndex:textOffset:)` for a timed corpus and `navigateToSearchResult` otherwise, then closes the sheet as today.
   - `.sheet(isPresented: $panels.search, onDismiss: { viewModel.announcePendingJump() })`, so the jump is heard once the sheet has gone and VoiceOver has settled on the reader (as Move to Library… does after REV11 F6).
   - Handle `.goBack` like the other panel commands: `guard shouldAcceptPanelCommand(notification) else { return }`, then `viewModel.goBack()`. Check first that the library's own handler (`ContentView`, `isKeyLibraryWindow`) cannot also act when a reader window is key, and that a reader's handler cannot act when a Library window is key; say what you found in your report.
6. `enum BookSearchWording` at the top of `BookSearchView.swift`, doc commented, exactly:
   - `static func noTranscript(bookTitle: String) -> String`: `"\(bookTitle) has no transcript to search. Transcribe it first, with Transcribe Audio."`
   - `static func movedTo(time: TimeInterval, location: String?) -> String`: `"Moved to \(TimeFormatting.spoken(time)), \(location)."`, or `"Moved to \(TimeFormatting.spoken(time))."` without a location.
   - `static let nothingToGoBackTo = "No previous position to return to."`
   - `static let transcriptFieldHint = "Type to search the book's transcript"`.

## Commit 3: the sheet's rows
7. `BookSearchView` keeps whether its corpus is timed. When it is: the Display picker (Percentage/Time) is not shown, since the time is exact; the search field's hint is `BookSearchWording.transcriptFieldHint`; each row shows `TimeFormatting.format(time)` where the position goes and its spoken label is `result.timedLabel`. An untimed search is exactly as today.
8. Every result row (timed or not) also takes Return, as a bookmark row does (`BookmarkPanelView.swift` 259-262): `.onKeyPress(keys: [.return], phases: .down)` performs the row's action and returns `.handled`. Space and VoiceOver's activation work as before. Factor the row's action into one function both use (DRY).

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`)
Add `TextMouthProductionTests/TranscriptSearchTests.swift` (run `/opt/homebrew/bin/xcodegen generate` and commit the regenerated `project.pbxproj` with it), each test doc commented:
- `BookSearchTiming`: from two audio chapters of 3 and 2 seconds (`Chapter` with spacing text of 30 and 20 characters) and a `TranscriptText` read from a reader (below), `chapterStarts == [0, 3]`; an index past the end counts from 0.
- The reader of a transcribed silent audiobook, made as `TranscriptEditTests.testAnEditOfATranscribedAudiobookIsTakenIntoItsTranscript` (lines 178-186) makes it, with `TranscriptionUIScripts.twoTracks` ("Gannet wings fold over the breakwater." 0-1500 ms and "Rope coils dry on the pier." 1500-2940 ms in 01.wav; "The ferry bell rings twice." 0-1920 ms in 02.wav): `canSearchText` is true and `searchCorpus` is timed; `BookSearchEngine.search(query: "pier", useRegex: false, in: corpus)` gives one result in chapter 0 at 1.5 seconds and `"ferry"` one in chapter 1 at 3 seconds; each result's `timedLabel` is its context, then ", at " and the spoken time.
- `navigateToTranscriptSearchResult` for "ferry": the reader's chapter is 1 and its offset `transcript.audioOffset(...)`, `hasSavedPosition` is true, `pendingJumpAnnouncement` is `BookSearchWording.movedTo(time: 3, location: …)` as decided; `announcePendingJump()` makes it `lastAnnouncement` and clears it; `goBack()` returns to where the reader was, and a second `goBack()` announces `nothingToGoBackTo`.
- An untranscribed silent audiobook: `canSearchText` false, `searchCorpus` nil. A text book: `canSearchText` true and `searchCorpus` untimed, with the same chapter texts as its content.
- Each `BookSearchWording` sentence as a literal string, one example each (with and without a location).
- No test needs a hosted window; if one does, it calls `skipUnlessHostedWindowsExposeAccessibility()` first.

Run: `python3 Scripts/test/run-area.py TranscriptSearchTests BookSearchModelTests BookSearchEngineTests BookTextSearchMatcherTests SearchResultLocationTests SearchResultRowsTests ViewsAndWindowsReaderSheetTests HeadingVocabularyTests`, then `python3 Scripts/test/run-area.py --unassigned` and report the classes it lists (the lead places them).

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-search --timeout 240`, never a sleep loop.

## Do not touch
`ReaderBookCommands.swift`, `MenuCommands.swift`, `LibraryAudioCommand.swift`, the transcription and export files, `KeyboardShortcut.swift` (no new shortcut), any `*.md`. Do not change what a text book's search finds or how its rows read, beyond Return.

## Completion check
`grep -n -A1 "isAudioBook" TextMouth/Views/Reader/ReaderView.swift | grep -i "search"` finds nothing.
