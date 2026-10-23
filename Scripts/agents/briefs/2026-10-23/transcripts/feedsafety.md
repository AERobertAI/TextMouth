# Brief: `transcripts-feedsafety`, a feed episode's transcript edit survives its feed's rules (T5, question 1)

Worker slug `transcripts-feedsafety`, branch `transcripts/feedsafety` (`git checkout -b transcripts/feedsafety team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Two commits, as below; about 80 changed lines besides tests.

## Why (the team's reviewer confirmed it)
Edit Text is now offered for a feed episode's transcript (task T1, on the team branch). Edit Text's session lasts until TextMouth quits; closing the editor does not end it. When a feed's rule (played, or outside the newest N) deletes the episode's download meanwhile, its row moves to the feed's shelf and the package stays, with its transcript (`FeedItemPackage`). Two things then go wrong:
1. The session's next check finds no row and ends (another worker now makes it say so), so a save made after the rule ran is never taken; it stays only in the kept package's content.md.
2. Downloading the episode again throws that content.md away: `FeedEpisodeImporter`'s restore (`TextMouth/Services/Feeds/FeedEpisodeImporter.swift` around 270-300) keeps an article's earlier text (`earlierText`, `keepEarlierText(_:in:)`), but sets `earlierText` to nil for audio.

The rules already wait for a download in use (`FeedBookUse`: open in a reader, being transcribed, being exported), reading `FeedLibraryHost.feedBooksInUse`; the listener's own deletions refuse such a download, saying why, through `feedBookUse(of:)`. A text being edited must make the rules wait too, but must not make the listener's deletions refuse: a session never ends by itself, so a refusal would leave Delete Download and Delete Feed refused until TextMouth quits. `FeedCenter+DeleteFeed.swift` 170-186 already skips a row in `feedBooksInUse` that has no `feedBookUse`.

## Read first (by line range)
- `TextMouth/ViewModels/LibraryViewModel+Feeds.swift` 225-262.
- `TextMouth/Services/Feeds/FeedCenter.swift` 110-130 (`FeedLibraryHost`).
- `TextMouth/Models/FeedBookUse.swift` 1-20.
- `TextMouth/Services/Feeds/FeedEpisodeImporter.swift` 170-330; `TextMouth/Services/Feeds/FeedItemPackage.swift` 1-80 and 380-430 (`copyWhatANewDownloadKeeps`, `keptText`).
- `TextMouth/Services/BookTextEditing.swift` 225-300 (`BookTextEditSessions`: `shared`, `bookIDs`, `isEditing`, `keepCopy(of:bytes:)`).

## Commit 1: the rules wait while an episode's text is being edited
1. `LibraryViewModel.feedBooksInUse` also holds the books being edited with Edit Text: the book IDs of `BookTextEditSessions`, read through a property the library model keeps (`var textEditSessions: BookTextEditSessions = .shared`, doc commented), so a test can give it sessions of its own. `feedBookUse(of:)` and `feedBookUses` stay as they are.
2. Rewrite the docs that say both read one list and never disagree: `feedBooksInUse` and `feedBookUses` in `LibraryViewModel+Feeds.swift`, `FeedLibraryHost.feedBooksInUse` and `feedBookUse(of:)` in `FeedCenter.swift`, and the header of `FeedBookUse`: the rules also leave a download whose text is being edited, for their next pass, while the listener's own deletions go ahead, since an editing session ends only when TextMouth quits; its transcript stays in the package, and a save made after the download went is kept when the episode is downloaded again.

## Commit 2: downloading an episode again keeps a save no session took
3. In `FeedEpisodeImporter`'s restore of a kept package, for an audiobook: when the kept package holds a content.md whose digest differs from the one its kept record's transcript layer recorded (`contentIndex?.transcript?.textCacheFingerprint.cache.digest`; read the record as the restore already reads `keptState`), that content.md stays beside the restored package's content.md as an `.edited-` copy (`BookTextEditSessions.keepCopy(of:bytes:)`, as an edit Edit Text could not take is kept), and the debug log says so as the article's earlier text does. A content.md matching the recorded digest, or a package with no layer, is not copied. Read it without downloading anything, as `FeedItemPackage.keptText(of:)` reads an article's. First check what `copyWhatANewDownloadKeeps` already carries over, and say in your report what you found; the required outcome is that after a re-download the saved bytes are on disk in the restored package, as content.md or as a copy beside it.

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`), each doc commented
- `feedBooksInUse` holds a book with an Edit Text session (sessions of the test's own, begun for the book's ID as `BookTextEditTests` begins them), and `feedBookUse(of:)` is nil for it; without the session it holds neither.
- A feed rule's pass leaves that download for later: use the rule's existing tests and their library host (search `FeedLifecycleTests` or the class testing `sweepPlayedDownloads` / `applyItemPolicy`) with the session's book ID in use, and assert the download stays and is reported in use.
- Delete Download of that episode still goes ahead (not refused).
- Restoring a kept audio package whose content.md differs from its layer's digest keeps those bytes in the restored package (as content.md or an `.edited-` copy); one whose content.md matches keeps no copy. Model the setup on the existing restore tests of kept packages (search `FeedEpisodeImporter` and `restore` in `TextMouthProductionTests`).

Run the classes you touched, then `python3 Scripts/test/run-area.py feeds`. Add no test file unless no feed test class fits (then `xcodegen generate` and commit the project with it).

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-feedsafety --timeout 240`, never a sleep loop. Write both commits before your first build.

## Do not touch
`BookTextEditor.swift`, `BookTextEditing.swift` beyond reading it, the transcription files, the reader, the export, and any `*.md`. Do not change what `feedBookUse(of:)` returns or how the listener's deletions decide.

## Completion check
`grep -n "never disagree" TextMouth/ViewModels/LibraryViewModel+Feeds.swift TextMouth/Services/Feeds/FeedCenter.swift` finds nothing.
