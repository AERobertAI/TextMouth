# polish3-cleanupfeed: Clean Up Transcript refuses what its menus never offer

- Team `polish3`; lead `polish3-lead`; your task is number 18 on the team's list.
- Your slug is `polish3-cleanupfeed`. Your branch is `polish3/cleanupfeed`, made with `git checkout -b polish3/cleanupfeed team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-cleanupfeed --role "Clean Up Transcript refuses a feed's episode" --branch polish3/cleanupfeed --team polish3 --files TextMouth/Views/Transcription/TranscriptionPresentation.swift TextMouthProductionTests/TranscriptCleanupSheetTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-cleanupfeed 18 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the TODO's "`TranscriptionPresentation.cleanUp` not refusing a feed item".

## The problem
The user decided feed items are not editable (FR11), so Clean Up Transcript (Experimental)… is never offered for a feed's episode: the library's rows and menu build their commands with `LibraryAudioCommand.isTranscriptCleanable(_:)` (`TextMouth/Models/LibraryAudioCommand.swift` 82 to 92: an audiobook in a package of its own, never a feed item), and the reader's menu item is enabled by the same rule (`TextMouth/Views/Reader/ReaderBookCommands.swift` line 117). But `TranscriptionPresenter.cleanUp(_:library:window:)` (`TextMouth/Views/Transcription/TranscriptionPresentation.swift` lines 113 to 127), which every path goes through (the row's command at line 104, the reader's at `ReaderBookCommands.swift` 152 to 156), opens the sheet for any book.

Confirm it is still open first: `grep -n "isTranscriptCleanable\|isFeedItem" TextMouth/Views/Transcription/TranscriptionPresentation.swift` finds nothing.

## What to build
1. In `cleanUp`, return at once, opening nothing, when `!LibraryAudioCommand.isTranscriptCleanable(book)`, in the same `guard` as `cleanup == nil`. Use that function, not `book.isFeedItem` alone, so the presenter keeps exactly the menus' rule.
2. Extend its doc comment: it opens nothing for a book the command is never offered for (`LibraryAudioCommand.isTranscriptCleanable(_:)`), such as a feed's episode, whose transcript the user decided is not editable (FR11).
3. It says nothing aloud: nothing offers the command for such a book, so no listener can ask.

## Tests
In `TextMouthProductionTests/TranscriptCleanupSheetTests.swift`, beside `testTheCommandOpensOneSheetForItsBook` (lines 55 to 70), add `testTheCommandOpensNoSheetForAFeedsEpisode`, made the same way:
- `var book = try transcribedBook(in: world)`, then make it a feed's episode: `book.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:harbour-log")` (`Book.isFeedItem` is `feedLink != nil`, `Book.swift` 209 to 215; `FeedItemIndexMoveTests.swift` line 187 builds one the same way).
- Assert first that `LibraryAudioCommand.isTranscriptCleanable(book)` is false, so the test states the rule it relies on.
- Then both `presenter.cleanUp(book, library: world.library, window: nil)` and `presenter.perform(.cleanUpTranscript(book), library: world.library, window: nil)` leave `presenter.cleanup` nil.
- Give it a doc comment in the file's style, one or two lines.

## Commits
One commit. Its message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `TranscriptCleanupSheetTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-cleanupfeed-…`.

      BBS_AGENT=polish3-cleanupfeed .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-cleanupfeed -only-testing:TextMouthProductionTests/TranscriptCleanupSheetTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-cleanupfeed-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `LibraryAudioCommand.swift`, `ReaderBookCommands.swift`, `Book.swift`, and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/cleanupfeed` to `polish3-lead`, move task 18 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
