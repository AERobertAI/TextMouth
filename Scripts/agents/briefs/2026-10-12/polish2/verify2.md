# polish2-verify2: check the 90 follow-up clauses the first list did not name

- Team `polish2`; lead `polish2-lead`; your task is number 9 on the team's list.
- Your slug is `polish2-verify2`. Your branch is `polish2/verify2`, made with `git checkout -b polish2/verify2 team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Keeping the cost down". You build nothing, so skip "Builds".
- Then read `Scripts/agents/briefs/2026-10-12/polish2/verify.md`, the first pass's brief, from "Skip without checking" through "What to write". Its rules, kinds (`[listener]` and the rest), sizes, and layout are yours too.
- Register, joining the team, then mark your task started:

      bbs register polish2-verify2 --role "Second verify pass on 90 follow-up clauses" --branch polish2/verify2 --files Scripts/agents/briefs/2026-10-12/polish2/candidates-2.md --team polish2
      bbs task move polish2-verify2 9 working

- You write one file, `Scripts/agents/briefs/2026-10-12/polish2/candidates-2.md`, and nothing else.

## Why
The first pass wrote `candidates.md` beside this brief, but it listed only about two clauses in three. Each TODO line holds many clauses, separated by semicolons, and the first pass read some lines as one item. A script found the 90 clauses below, whose `#numbers` and backticked names `candidates.md` never mentions. Some are false alarms: the first pass may have covered them in other words. You check each.

## What to do
- **Do not read the TODO.** The clauses are below, whole, each with its TODO line number. A clause that starts mid-sentence, such as L3073's, continues the line before it: read the neighbors in this list for its sense.
- **Before checking, look in `candidates.md`.** If it already covers a clause in other words, list the clause under "Skipped without checking" as "covered: <its line in candidates.md>". One `grep -n` of `candidates.md` settles several clauses.
- **Then check the rest** as `verify.md` says. Spend at most about two calls an item, and batch 6 to 10 items in one Bash call.
- **The lead cares most about `[listener]` items:** what VoiceOver or a braille display shows, keyboard access, a wrong state shown, and a control that does nothing or the wrong thing. For each that is still open, give the file and lines, and a fix in one sentence that a worker could follow.
- Write `candidates-2.md` as you go, with the same five headings as `candidates.md`. Its first line is `# polish2 candidates, second pass, verified against main <short hash>, October 12`.

## Finish
1. Commit only the file, with `git add -f`, in one commit with this subject, and the `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` line at the end of its message:
   `List the polish2 second-pass candidates`
2. Post the commit to the team's channel (`--to team:polish2 --tag commit`).
3. Move your task: `bbs task move polish2-verify2 9 review --note "N open, N user, N fixed, N large, N skipped"`.
4. Post `done: polish2/verify2` to `polish2-lead`, and release your claims.
5. Reply with a report of at most 15 lines: the branch; the commit's hash and subject; the count in each list; the `[listener]` items still open, one line each; and anything you could not settle.

## Do not
- Change any code, test, or other file.
- Build, or run tests.
- Read `AGENTS.md`, `README.md`, `ARCHITECTURE.md`, `AGENT-NOTES-*`, or the TODO.

## The clauses
- L3073: moment past the marker (the next refresh after an audio position update, up to about a quarter
- L3074: second, the cursor put back at the marker) and without the fade-out, since
- L3076: audiobooks have no sleep timer test of their own
- L3076: the Return-key test helpers exist twice, privately
- L3078: in Add Feed, Search keeps Return while its
- L3079: field is focused even with the New Folder fields shown, so Create also draws as default then
- L3080: still closes the whole Move sheet while the New Folder fields are shown, and the fields do not take
- L3081: keyboard focus when opened
- L3083: Filter sheet logs SwiftUI's "Picker: the selection nil is invalid" at its first draw;
- L3085: calling task's pool thread with cancellation seen only between buffers, the same shape the level
- L3087: sheet's speed stepper and slider, and the feed threshold field and stepper, read as two VoiceOver
- L3088: stops with one label and value, by design (fine and coarse control).
- L3093: the key from another action (`updateBindings`, KeyboardShortcutsSettingsView.swift), and a key added
- L3094: by hand in config.json stays on both actions (`bindings(_:adopting:)`)
- L3094: the Shift+Skip settings never
- L3096: Speed's default (Command with "+") cannot match on a US keyboard, where "+" needs Shift
- L3097: one undecodable saved shortcut resets every
- L3098: the Shortcuts tab's rows label keys with symbols, so a braille display shows
- L3099: a command sign and arrows rather than words
- L3100: every whole percent of a download (board #1410)
- L3100: the feed deletions write no log line, so nothing
- L3103: a chapter render the engine refuses (`RENDER_REFUSED`) is never retried strictly guarded, so that chapter has no rendered audio to switch to
- L3104: Still open after the import-progress merge (October 7 evening): each book of a ZIP batch is read twice for its checksum (the duplicate check, then `importFileWithReport`)
- L3104: a one-book audio or DAISY ZIP shows its step and time but not the bytes extracted, since `importAudioZipWithReport` passes no progress to the extractor
- L3107: the README's config.json paragraph and ARCHITECTURE's "a key belonging to at most one action" overstate how keys are reassigned (#1422)
- L3108: Still open after the editor-baselines merge (October 7 late): both reader metadata saves update Now Playing whatever the reader's state, so a stopped reader's save shows its book paused and takes the AirPods (board #1498
- L3108: drop both calls once the finished-book branch's `holdsMediaControls(ownerID:)` can test it)
- L3108: board finding #624 is already fixed on main and can be closed.
- L3109: the reader's two metadata saves still publish Now Playing for a reader not playing (#1498), now testable with `holdsMediaControls`
- L3109: `makeSilentAudioBook` makes the Thread Performance Checker print a priority-inversion backtrace for each silent audiobook a test makes (log noise).
- L3111: a held key repeats its action and `handleKeyEvent` still walks a dictionary (for branch B)
- L3114: whether the Shift fallback should reach every action (Shift-W speaks Where Am I?, Shift-Command-Delete removes the selected books, asking first only while `confirmBeforeDelete` is on) or only the skip actions is the user's call.
- L3115: Still open after FR11's branch A1 merge (October 10): until branch D lands, Unsubscribe deletes the feed's record while its downloads stay in `Feeds/<feed ID>/`, listed nowhere, though nothing is lost, and `FeedWording.unsubscribeMessage` still promises they stay in the feed's folder (board #1576)
- L3115: D's Move to Library writes the other way and should rely on the join's rule that keeps the row whose file is present (`joinFeedItems`)
- L3116: Still open after the now-playing-followups merge (October 10): `AsyncBridge.waitForResult`, waited on from the main thread, makes the Thread Performance Checker print a priority-inversion backtrace for each silent audiobook a test makes (110 in one run
- L3116: `clearNowPlaying(ownerID:)` takes nothing down for a reader shown but not active, as a stop from behind another window
- L3117: W pressed within 0.3 seconds of a Where Am I announcement's natural end records the book as not playing, and the pending resume then plays the book under the new announcement (older than this branch, `whereAmIAnnouncementFinished()`)
- L3117: `OffscreenTestWindow` never presents SwiftUI sheets, so no hosted test can see one open
- L3118: Unsubscribe now strands kept packages too, for branch D (#1576)
- L3118: a test through the app's own deletion path for a feed item, which the injected deletion hid, would have caught #1591.
- L3119: Still open after the October 10 documentation pass: `FeedWording.unsubscribed(title:bookCount:)` still announces that an unsubscribed feed's downloads "stay in the library", and the Unsubscribe question still says they stay in the folder (for branch D, with #1576)
- L3120: `FeedLifecycle.removeDue` is not registered as storage work, so a data-directory move is not held off (as before)
- L3121: a sleep fade on direct speech goes on from the last word the voice reported, so it may repeat a word.
- L3123: Still open after the menu-and-window-shortcuts merge (October 10): Space in a sheet is still Play / Pause, though with Full Keyboard Access Space presses the focused button (`KeyBinding.dialogKeys`)
- L3123: the `everyFieldCustomized` config fixture has no entry in the new object form
- L3123: `ReadingCheckpointTests.testClosingTheReaderWritesItsLastCheckpoint` failed once under load and passed alone (for AGENTS.md's load-sensitive list).
- L3124: `TranscriptionPresentation.cleanUp(_:library:window:)` does not itself refuse a feed item, though nothing offers it one.
- L3125: Delete Episode leaves a `.replaced-<name>` folder a crash set aside until Unsubscribe removes the feed's folder
- L3125: `updateLocalVoiceAndSpeed` stores a speed without checking its format's range, so an article given 1.5 reads back as 50 from bookInfo.json (no control sends such a value today).
- L3126: `FeedItemPolicyControls`' note says a change "takes effect" after ten seconds though the list changes at once, and the Only-the-newest hint says played items are left out though a played item still downloaded stays listed
- L3127: `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped` failed once under load (resume data with no bytes) and passed alone, for AGENTS.md's load-sensitive list.
- L3128: the legacy test target's `#else` branches in six more files cannot compile there
- L3129: Still open after the where-am-i-and-keys merge (October 10): `FeedEndToEndTests.testAnEpisodeFromItsFeedToTheDeletionOfItsDownload` and `FeedLifecycleTests.testADownloadOpenInAReaderWaitsUntilItCloses` race under load since FR11's branch B moved file removals off the main thread (each checks an item's state the moment its row is gone, while the state settles a step later
- L3129: board #1821), for `fix/feed-policy-review`, and on AGENTS.md's load-sensitive list until then
- L3129: the Now Playing session's `isCurrentlyPlaying` does not count a play waiting for its chapter's speech or download, so the AirPods leaving, a recording, or another book starting do not pause it
- L3129: a sleep timer started with "start playback" during Where Am I? goes through `togglePlayPause()` and leaves the book paused
- L3129: the legacy `TextMouthTests` target is not in the scheme, so its tests never run.
- L3130: `finishedBookKind(of:)` counts a moved episode as an episode only while its record keeps the item (bookInfo.json's feed link could serve)
- L3130: a crash between the index write and a kept package's removal in `deleteKeptPackages(of:)` leaves the place kept (nothing lost)
- L3130: `feedItemsLeft(titles:)` could mention Move to Library…
- L3130: two test docs describe the old Unsubscribe (`LibraryInfoWordingTests` about 198, `FeedRecordTests` about 388).
- L3131: Noticed by the P07 and P08 design note (October 10): the player's asset lacks precise timing and `seekPlayer` clamps to an estimated duration that can be short for some MP3s (`AudioPlaybackService.makeItem(playing:)`, read from the code)
- L3131: m4b chapter starts drift 1.4 seconds by chapter 30 (`chapterStartTime`)
- L3131: Go to Percent 100 then Play counts a finish (`clampedNavigationPosition`)
- L3131: each repeated finish restarts a feed item's delete-after-played clock (`FeedLifecycle.bookDidFinish`)
- L3131: Go to Time's three fields are known to VoiceOver only by their placeholders (`JumpToTimePanel`).
- L3132: `FeedUICommandsTests.testCancelDownloadStopsIt` timed out twice under load and passed alone (for AGENTS.md's list)
- L3132: the feed half's ARCHITECTURE wording in the agent notes names `FeedDownloadTimeEstimate`, now `TimeLeftEstimate`.
- L3134: Still open after the where-am-i-followups merge (October 10): Play/Pause during Where Am I? while an audiobook's chapter still downloads leaves the reader waiting (`endWhereAmIWithoutResuming()`
- L3134: checking `isWaitingForChapterDownload` would pause it)
- L3134: a Play during Where Am I? for a book it paused goes unanswered after an engine cancel (`holdPlayForWhereAmI()`)
- L3134: the legacy `TextMouthTests` target is not in the scheme.
- L3135: a crash between the hidden `.removing-` folder and the Trash leaves that folder in the feed's folder, swept by nothing at launch
- L3135: `finishedBookKind(of:)` reads each audiobook's record once on the main actor before caching it
- L3137: each reader toolbar item appears to accessibility as a button holding another button with a different name, such as "Headings" holding "Show heading navigator" (`toolbarItems`
- L3137: the voice sheets' section headings "Audio Speed", "Speed", and "Pitch" may be read just before a slider of the same name (`BookVoicePickerView`)
- L3138: `ShortcutConfigFileTests.testAnEditGivingAnEditedActionsKeyAwaySavesTheKeysInForce` waits the same fixed window #741's test did
- L3138: REV13 finding 8's alias helper is `feedEditableFields(in:)`, left for the feed follow-up branch.
- L3139: `FeedKeptProgress` should use `BookRow.timeRemaining(for:wpm:)` once P07 merges (#1956)
- L3140: after Release Media Controls, Play on a finished book still says "Finished" but Skip Backward only moves the cursor (B02's rule for a released book, left as it is). (`Portability.localStoreKeys` now names `library.finishedBooksAtEndVersion`, 41de77bb, and `FeedKeptProgress` uses `BookRow.timeRemaining(for:wpm:)`, 2304010c.)
- L3141: `AudioBookParser.parseSegmentedAudio`)
- L3142: in a cloud library one Mac's launch sweep could take a `.removing-` folder another Mac is filling at that instant, whose Delete Download would then report failure with its files in this Mac's Trash (`FeedCenter.sweepRemovalHolders`)
- L3142: with Removal Behavior set to delete permanently, a folder left when a refused Delete Download's files could not go back (FEED_DOWNLOAD_HELD_ASIDE) is deleted for good at the next launch (`FeedItemPackage.removeFileAndText`)
- L3142: `LibraryFolderPickerTests`' stand-in owner now tests a shape no sheet has
- L3144: a move's end or a chapter download's end in the 0.3 seconds after Where Am I? ends starts audio over the end sound, since both check only `isWhereAmISpeaking` (`resumeAudioAfterPackageMove()`, `downloadDidFinish(_:)`)
- L3144: a second AirPods Play on an audiobook waiting for its download makes the play sound again and begins a new chapter play (`playOrResume()`)
- L3145: the next documentation pass must describe `fix/rev14-reader-findings` and `fix/rev14-feed-findings` once merged (removing ARCHITECTURE's sentence on the Unsubscribe gap) and update both documents' sentences on how a past-the-end place reopens once T06's branch B merges (#2028).
- L3148: Delete Episode during a restore can leave two Trash items for one episode (`FeedLifecycle.deleteItem`)
- L3148: until the next launch a refused, stuck download's row says Downloaded with its file missing (`FeedItemPackage.removeFileAndText`)
- L3152: `TranscriptModelTests` still writes into its fixture by index, safe while `TranscriptFixtures.twoFiles` has two files
