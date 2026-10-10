# Task brief: feeditemui — FR11's branch C, the interface for the List and download choice

Slug `feeditemui`; branch `feature/feed-item-policy-ui`. Read `common.md` beside this file first (its usage section: the user overrode the usage rule; work until the API refuses you, committing each item as soon as it is green; the orchestrator resumes you after the 8:00 a.m. Eastern reset if you are cut off). Main is at 80184c55 or later: FR11's branches A1 (de0839c5), A2 (4887c21b), and B (87d8857c) are merged; use main's latest suite count as your baseline.

## Why this branch matters now
Branch B left the old feed controls ("Keep the newest … entries", "Download new episodes and articles by themselves", Feed Info's entries number) on screen, doing nothing: the user must not install until this branch replaces them. Read the feeditempolicy agent's notes in `AGENT-NOTES-2026-10-04.md`, especially "What branch C needs", which names every type you build on (`FeedItemPolicy.Choice`, `newestCount`, `FeedCenter.setItemPolicy(_:of:)`, `itemPolicy(of:)`, `listedItems(of:)`, `FeedItemState.waiting` and `waitingReason`, `FeedItem.downloadOrigin`, `FeedCenter.itemPolicyQuietTime`).

## The design and the user's answers
`FEED-ITEMS-RESEARCH-2026-10-07.md` sections 4 ("The three choices, worded"), 7 ("Accessibility"), and 9's "Branch C"; `FEED-ITEMS-ADDENDUM-2026-10-07.md` sections 3 and 4 and 7's "C". The user's answers (FR11's entry in the TODO quotes them all):
- Question 2, yes: a "List and download" pop-up menu with "Every item listed, newest 5 downloaded" (the default), "Every item listed, downloads by hand", and "Only the newest 5 listed", with one number, 5 by default, in the Feeds settings and in each feed's Feed Info with "Use the global setting". The number's words follow the number ("newest 3").
- Question 8, yes: a feed shows in Unopened only while it has a new episode or article, not any unplayed one.
- Question 10, yes: "10 of 381 episodes kept" reads "10 of 381 episodes listed".
- Late question 4, yes: while an item belongs to its feed, Book Info is read-only (no field can be edited, and the reader's metadata editor is not offered), and Clean Up Transcript (Experimental)… and Undo Cleanup are not offered; it keeps Open, Speak Info, the reading list, Export…, Transcribe Audio…, Delete Transcript…, Show in Finder, and the feed item's own commands.

## Items, one commit each, each with its tests
1. The pop-up menu and the number in the Feeds settings, replacing "Keep the newest … entries" and "Download new episodes and articles by themselves"; the same in Feed Info with "Use the global setting", replacing the entries number. Accessible: each a labelled pop-up button whose value VoiceOver speaks, the number a field with a stepper, labelled and hinted as section 7 words them; a change applies after the ten-second quiet time (B's), and VoiceOver hears when it takes effect.
2. Remove what the old controls used, once nothing reads it: `FeedSettings.keepEntries` and `autoDownload` (their stored keys stay for B's move), `Feed.keepEntries(under:)`, `FeedCenter.setKeepEntries`, `FeedThresholdWording.keepEntries`, `FeedSettingsWording.autoDownload` and its hint; list `feedKeepEntries` and `feedAutoDownload` in `ConfigService.Portability.retiredStoreKeys`, updating the line of `ShortcutConfigFileTests` that pins the list (`menukeys` owns that test's shortcut lines: change only the retired-keys line, and say so on the board).
3. Item rows: a kept record's progress and bookmarks ("Ep. 368, Not Downloaded, 42 percent, 16 minutes remaining, 2 bookmarks"), a waiting item's reason after "Waiting to Download", and Cancel Download offered for a waiting item; "listed" in every count ("10 of 381 episodes listed"), spoken as shown.
4. Unopened's rule (question 8): a feed shows there only while it has a new item.
5. The commands an item in its feed loses (late question 4): Book Info read-only for a feed item, in the Library and the reader, with a line saying why ("An episode's details come from its feed; Move to Library… makes it a book you can edit" once branch D adds that command, until then without the second half); the reader's metadata editor not offered; Clean Up Transcript and Undo Cleanup not offered. `feedindexfixes` is removing Edit Audio…, Edit Text…, and Move to Folder… for feed items and rewording Remove for them: leave those to it, and ask it on the board before you touch the same files (`LibraryAudioCommand.swift`, `BookTextEditor.swift`, `LibraryViewModel+BookOperations.swift`, `RemovalWording.swift`, `FeedCommands.swift`).

## Files you own
The feed settings and Feed Info views (`FeedSettingsView.swift`, `FeedInfoSheet.swift`), the feed rows and their wording (`FeedRows.swift`, `FeedLibraryWording`, `FeedLibraryPresentation.swift`), the Unopened filter's feed rule, the Book Info sheets and the reader's metadata editor's offer, the transcript cleanup commands' offer, the retired settings in `FeedSettings`, `Feed`, and `FeedCenter`, and their tests. Leave the keyboard and menu files (`menukeys`) and the playback files (`playbackfixes`) alone.

## Verify or report as unverified
- Live VoiceOver and braille on the pop-up menus, the number, and the rows are unverified; say so, and list what the user should try.
- Say what the user's Feeds settings and their two feeds' Feed Info show after your build's first launch.
- Report the README and ARCHITECTURE wording, including the README's paragraphs on `feedKeepEntries` and `feedAutoDownload`, which change.
