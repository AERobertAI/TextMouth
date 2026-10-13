# polish2-bookmarkname: one name for the bookmark command, Toggle Bookmark (#1937)

- Team `polish2`; lead `polish2-lead`; your task is number 11 on the team's list.
- Your slug is `polish2-bookmarkname`. Your branch is `polish2/bookmarkname`, made with `git checkout -b polish2/bookmarkname team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-bookmarkname --role "#1937: one name for the bookmark command" --branch polish2/bookmarkname --files TextMouth/Models/KeyboardShortcut.swift TextMouth/App/MenuCommands.swift --team polish2
      bbs task move polish2-bookmarkname 11 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes #1937, "one name for the bookmark command" (TODO line 3133).

## What is wrong
One command adds a bookmark at the reading position, or removes the one there (`ReaderViewModel.toggleBookmarkAtCurrentPosition()`). The listener meets it under two names:
- the Bookmarks menu calls it **Toggle Bookmark** (`TextMouth/App/MenuCommands.swift` line 439);
- the Shortcuts tab, config.json, and every message that names an action call it **Add Bookmark**, its raw value (`TextMouth/Models/KeyboardShortcut.swift` line 37: `case addBookmark = "Add Bookmark"`).

The TODO settled the answer: "Toggle Bookmark" as the raw value, with "Add Bookmark" in `formerNames`, and the menu titled from the action.

## Do
1. **The raw value.** Line 37 becomes `case addBookmark = "Toggle Bookmark"`. Keep the case's name, `addBookmark`, and the notification's (`.addBookmark`): renaming them would touch many files for no listener's gain. Give the case a doc comment: it adds a bookmark at the reading position or removes the one there, the Bookmarks menu's item of the same name; it was named Add Bookmark in Settings and config.json until October 12, a name still read (`formerNames`, #1937).
2. **The former name.** Add `"Add Bookmark": .addBookmark,` to `formerNames` (lines 1405 to 1409), and add a sentence to its doc comment (lines 1399 to 1404) saying so. A user's config.json, and the record of the user's edits, that name the command "Add Bookmark" must keep working: `named(_:)` and `exactlyNamed(_:)` (lines 1382 to 1397) already read former names, so this entry is all they need.
3. **The menu titled from its actions.** In `BookmarkCommands` (`MenuCommands.swift` lines 436 to 458), title each of the four buttons from its action's raw value, so the menu and the Shortcuts tab cannot drift apart again: `Button(ShortcutAction.addBookmark.rawValue)`, and likewise `.showBookmarkList`, `.nextBookmark`, and `.previousBookmark` (today "Show Bookmarks", "Next Bookmark", "Previous Bookmark", which their raw values already are). Add one comment above the menu saying why.
4. **Leave alone** the bookmark panel's own "Add Bookmark" button and its help (`BookmarkPanelView.swift` lines 175, 359, 457): that button adds a bookmark with a note, and is rightly named Add Bookmark.
5. **Commits:** one for steps 1 and 2 with their tests, and one for step 3. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
- **The former name is read.** In `TextMouthProductionTests/MenuKeyShortcutTests.swift`, the test ending at about line 767 checks the Record window's former names. Add beside them: `ShortcutAction.named("Add Bookmark")` and `named("add bookmark")` are `.addBookmark`; `exactlyNamed("Add Bookmark")` is `.addBookmark`; and `ShortcutAction.addBookmark.rawValue` is "Toggle Bookmark". Its last two lines already check that no two names, former names included, compare alike.
- **A round trip through config.json.** `TextMouthProductionTests/ShortcutConfigFileTests.swift`, `testTheRecordWindowsFormerNamesAreStillRead` (lines 60 to 95), shows the pattern. Add a test like it for the bookmark command: a config.json naming "Add Bookmark" with a key the user chose applies it to `.addBookmark`, logs no unknown name, and writes it back as "Toggle Bookmark", with no "Add Bookmark" entry; and a record of edits written under "Add Bookmark" reads as the same edit.
- **Existing tests that name it.** These pin "Add Bookmark" today:
  - `ShortcutConfigFileTests.swift` line 166, an expected written config file: it now says "Toggle Bookmark". If the file is written in sorted order, move the line to its sorted place.
  - `DoublePressBindingTests.swift` line 102, an excerpt of the user's own config.json: leave it as it is, since it now proves the user's file, written under the former name, still reads. If the test compares what is written back, change only that expectation.
  - `ConfigWatcherTests.swift` lines 357 and 365 merge two configs by their raw keys: leave them.
  - Then one grep, `grep -rn '"Add Bookmark"' TextMouthProductionTests`, for any other; judge each the same way: a file the user wrote keeps the old name, and what TextMouth writes or shows takes the new.

## Build and test
- Run `MenuKeyShortcutTests`, `ShortcutConfigFileTests`, `DoublePressBindingTests`, `ConfigWatcherTests`, `ShortcutListingTests`, and `ShortcutsSettingsTabTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-bookmarkname-…`.

      BBS_AGENT=polish2-bookmarkname .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-bookmarkname" -only-testing:TextMouthProductionTests/MenuKeyShortcutTests -only-testing:TextMouthProductionTests/ShortcutConfigFileTests -only-testing:TextMouthProductionTests/DoublePressBindingTests -only-testing:TextMouthProductionTests/ConfigWatcherTests -only-testing:TextMouthProductionTests/ShortcutListingTests -only-testing:TextMouthProductionTests/ShortcutsSettingsTabTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-bookmarkname-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `BookmarkPanelView.swift`, the reader, and any other app file.
- Any `*.md` file. (README.md names the command; the lead reports that to the orchestrator.)
