# Task brief: feeddownloadprogress — FR10's feed half, progress for feed downloads

Slug `feeddownloadprogress`; branch `feature/feed-download-progress`. Read `common.md` beside this file first. Its usage section described the night of October 9 to 10; the weekly window reset at 8:00 a.m. on October 10, so the normal rule applies again: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count (the TODO's last "After the … merge" sentence) as your baseline.

## What the user asked for
FR10 in TODO-2026-09-04.md: "I would also like maybe some more progress bar sections like the reading cash for like downloading stuff or extracting zips if there isn't already (I extracted about a 100 book zip earlier and it finished but I wasn't sure how long it would take or if it was stuck)". The ZIP half merged on October 7 (f2b39d7f, `feature/import-progress`); read the importprogress agent's notes in `AGENT-NOTES-2026-10-04.md` first, and build the feed half the same way: "one for feed downloads under way (items done of total, the current item's percent), each with its counts spoken by VoiceOver at intervals and on request, and a Cancel where one exists". It is timely: FR11's newest-N rule (87d8857c) downloads each feed's newest 5 at the first launch of the new build, about 316 MB for "Finish It!", and the user should be able to hear how far that has got.

## Required behavior
1. A feed-downloads progress section where the import overlay lives (or beside it, as the ZIP half's `ImportProgressObserver` does): items done of the total queued, the current item's title and percent, and an estimate once one item is done; it shows only while downloads run, the rule's waiting downloads ("Waiting to Download" for a network without data limits or for room) counted apart with their reason.
2. VoiceOver hears the progress at intervals, as the ZIP half's rules say (only for a run of at least 10 seconds, each quarter once at medium priority, and the end), and on request through a new action, "Speak Download Progress", with no default key, in the Library menu beside Speak Import Progress; adding the action follows the one-file recipe the menukeys agent wrote ("Adding an action", in its notes).
3. Cancel stops the downloads under way and the queue, saying what it stopped; a download the listener asked for and one the rule made are both cancelled, and the rule does not start them again by itself (`FeedItem.downloadOrigin`, as B made Cancel Download the listener's).
4. Nothing redraws the Library's lists for a download's progress (PERF12, and `FeedStore.update`'s cost, board #1410): only the progress view observes the progress.

## Files you own
`FeedDownloadManager.swift` (only its progress publishing), a new progress model for feed downloads, the progress view and its observer beside `ImportProgressObserver`, the Library menu item, `ShortcutAction`'s new case, and their tests. `feeditemui` (FR11's branch C: feed rows, Feed Info, feed settings) and `feedfollowups` (feed packages, the importer's restore, the lifecycle) are working: leave their files alone and ask on the board if you must touch one.

## Verify or report as unverified
Real downloads, a real network, and live VoiceOver are unverified; no test touches the network (`FeedEnvironment` is injectable). Report the README and ARCHITECTURE wording and the TODO sentence.
