# polish-cloudonce: Remove Download's refusal is said once, by its alert (#2094)

- Team polish; lead `polish-lead`. Your slug is `polish-cloudonce`, and your branch is `polish/cloudonce`, made with `git checkout -b polish/cloudonce team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes TODO #2094 ("Still open after the REV14 feed-fixes merge").

## What is wrong
`LibraryCloudCommands.removeDownloads(of:in:from:)` is in `TextMouth/ViewModels/LibraryViewModel+Cloud.swift`, about lines 856 to 944. It announces its summary (`VoiceOverAnnouncer.announce(message, from: window)`, about line 938). When any book kept its download, it then also returns a `LibraryCloudRefusal` with the same message.

The Library window shows that refusal as an alert:
- `LibraryCloudWindowSupport` in `TextMouth/Views/Library/LibraryView.swift`, about lines 1983 to 1990;
- `performCloudCommand`, about lines 1440 to 1447.

VoiceOver reads an alert as it appears, so the listener hears the words twice, or hears the announcement cut off as the alert takes focus.

REV14's feed finding 6 settled the rule for the feed deletions: the alert alone, with nothing announced besides. See `FeedCommandRunner.refuse(message:)` in `TextMouth/Views/Feeds/FeedCommandRunner.swift`, about lines 439 to 447; its comment says why.

## Do
1. In `removeDownloads`, announce the summary only when no book was refused, that is, when every target's download was removed. When any book was refused, announce nothing and return the refusal. Its alert carries the same whole message: what was removed, what stayed, and why.
2. Update `removeDownloads`'s doc comment (about lines 856 to 870) to say so, as `FeedCommandRunner.refuse(message:)`'s comment does, naming REV14's rule and #2094.
3. In LibraryView.swift, change only the comment above `LibraryCloudWindowSupport`'s `.alert` (about lines 1983 to 1984, "which VoiceOver has also heard announced"): the alert is now the only place the refusal is said. Touch nothing else in LibraryView.swift, since two later tasks edit it.

## Tests
Update the tests that pin the double speech so that they pin the alert alone. Each test keeps its refusal assertion and now asserts that nothing was announced (`said` is empty). Make each test's doc comment say that the refusal is shown, not said.
- `TextMouthProductionTests/LibraryCloudCommandTests.swift`:
  - `testRemoveDownloadRefusesAnOpenBook` (about line 313);
  - `testRemoveDownloadRefusesChangesNotUploaded` (about line 337);
  - `testRemoveDownloadTheServiceFailsSaysTheRemovalFailed` (about line 357);
  - `testRemovingASelectionSaysOneSummary` (about line 376).
- `TextMouthProductionTests/KeepOnThisMacTests.swift`:
  - `testRemoveDownloadRefusesAKeptBook` (about line 596);
  - `testRemoveDownloadOfASelectionSparesTheKeptBooks` (about line 616; its comment says "with the reason said once").
- Check that the test of a removal that fully succeeds still expects its announcement (LibraryCloudCommandTests, about lines 290 to 308).
- Grep both files for any other `removeDownloads(` test that asserts `said` alongside a refusal, and update it the same way.

## Build and test
Run only `LibraryCloudCommandTests` and `KeepOnThisMacTests`, through the wrapper. Start the build in the background and check on it no more often than every 4 minutes. `-jobs 4` is required (the orchestrator's #2107). Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-cloudonce-…`.

    BBS_AGENT=polish-cloudonce .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-cloudonce" -only-testing:TextMouthProductionTests/LibraryCloudCommandTests -only-testing:TextMouthProductionTests/KeepOnThisMacTests > <scratchpad>/polish-cloudonce-build-1.log 2>&1

## Do not touch
- `LibraryCloudWording`, whose words stay as they are.
- LibraryView.swift beyond that one comment.
- Any `*.md` file.
