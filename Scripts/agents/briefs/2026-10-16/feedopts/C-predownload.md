# Task C, `feedopts-predownload`: download the next episode before this one ends

Branch `feedopts/predownload`. Read `00-contract.md` first (rules 2, 3, 4, and 7 are this task). Tasks A, B1, B2, and B3 are on the team branch: `ListeningOptions` (with `predownloadLeadTime`, ten minutes), `EndOfBookRule` (`behavior`, `direction`, `skipsFinished`, `predownloadsNext`), `ReaderViewModel.endOfBookRule`, `LibraryViewModel.succession(after:going:skippingFinished:)` returning `.episodeToDownload(feedID:item:)` for the next listed episode whose file is not here. **When the episode playing has ten minutes or less left and listening would go on to another episode, download that episode now** if its file is not here and nothing is downloading it, so the next episode is ready when this one ends.

## What exists (read by line range)

- `ReaderViewModel.timeRemaining` (`ReaderViewModel.swift:783`): the time left in the book at the current speed.
- `ReaderViewModel.publishLivePosition(now:)` (`ReaderViewModel.swift:1969-1988`): runs about once a second while the position moves (`scheduleLivePositionPublish`, `:1954`); the natural place to look at the time left. `isPlaybackUnderWay` (`ReaderViewModel+Playback.swift:3272`) is true while speech or audio plays.
- `FeedCenter.download(_:of:)` (`FeedCenter.swift:984`): asks for a download with origin `.listener`, so the newest-N rule never removes the episode (`FeedNewestRule.swift:217-248` removes only `.window` downloads). `FeedItem.state.isTransient` is true while an item downloads or waits.
- `hasClosed`, `isOpenedFromReadingList`, `book.feedLink` as before.

## What to build

1. **Two stored properties** in `ReaderViewModel`'s class body (extensions cannot hold them), beside `hasFinishedBook` (`ReaderViewModel.swift:426`), each documented: `var hasAskedForPredownload = false` and `var predownloadLeadTime: TimeInterval = ListeningOptions.predownloadLeadTime` (a test lowers it; production never changes it).
2. **New `TextMouth/ViewModels/ReaderViewModel+Predownload.swift`**, `func predownloadNextEpisodeIfDue()`, with every guard in the order cheapest first, each commented:
   - not closed, the book is a feed's item (`book.feedLink`), not read from the reading list (its neighbors are books of the library, always here), nothing asked for yet by this reader, content loaded, playback under way (`isPlaybackUnderWay`);
   - the rule (`endOfBookRule`) goes on to another book (`behavior == .continueNext`) and `predownloadsNext` is on;
   - `0 < timeRemaining <= predownloadLeadTime`;
   - then, once, `libraryViewModel.succession(after: book, going: rule.direction, skippingFinished: rule.skipsFinished)`: if it is `.episodeToDownload(feedID, item)` and `item.state.isTransient` is false, call `libraryViewModel.feeds.download(item.id, of: feedID)`; trace it with `DiagnosticLog.event(.feeds, "FEED_PREDOWNLOAD: <next title> before <this title> ends")`. **Set `hasAskedForPredownload` whatever the search found** (a book already here, nothing after), so the search runs once per reader, not every second.
3. **Call it** from `publishLivePosition(now:)`, after the position is published (one line).
4. No new setting, no new control: Feed Info's checkbox (task D) writes `ListeningOptions.predownloadsNext`.

## Tests (new `TextMouthProductionTests/NextEpisodePredownloadTests.swift`, needs `xcodegen generate`, `project.pbxproj` committed with it)

Use `FeedTestWorld` (`FeedTestSupport.swift:439`) with episodes served by the stub server, and a reader opened on the playing episode as `FeedEndToEndTests.swift:125` opens one, with a private notification center and request store (`ContinueToNextBookTests.swift:23-60`); silent audio only. Call `predownloadNextEpisodeIfDue()` directly for the guards; one test lets playback run and shows `publishLivePosition` calls it (wait for the download to be requested, at most a few seconds). The fixtures' episodes are seconds long, so `timeRemaining` is always under ten minutes: lower `reader.predownloadLeadTime` to test "more than the lead time left".
1. It starts one download, of the next listed episode, with origin `.listener` (read the request from `world.center` while it runs, or the item's `downloadOrigin` after), once: a second call, and later publishes, start nothing more.
2. Not started: more than the lead time left; paused or not started playing; the rule stops (feed option Stop; or standard options and the global setting at Stop); the next episode already downloaded; its download already running or waiting; "Skip finished episodes" on and the next episode finished (played and not downloaded; or downloaded and at its end), in which case the one after it is downloaded instead; "Skip finished" off and the next episode played: that one is downloaded; the feed's pre-download option off; a book that is not a feed's; a book read from the reading list; nothing after the last episode.
3. Direction: with "Play the episode above", the episode above is the one downloaded.
4. The newest-N rule leaves it: with "newest N downloaded" smaller than the number of episodes and the pre-downloaded episode outside the newest, a pass of the rule (`FeedNewestRuleTests` show how to run one) does not remove it.
5. `ListeningOptions.predownloadLeadTime` is 600 seconds (pinned).

## Tests to run

`NextEpisodePredownloadTests`, `EpisodeDownloadContinuationTests`, `EpisodeSuccessionTests`, `ContinueToNextBookTests`, `FeedEndToEndTests`, `FeedNewestRuleTests`. Do not run the benchmarks or performance baselines; the call runs about once a second, so check by reading that nothing past the cheap guards runs until the time left is under the lead time.

## Commits

1. `predownloadNextEpisodeIfDue()` with its stored properties and tests.
2. The call from `publishLivePosition(now:)`, with its test.

## Do not touch

`FeedDownloadManager.swift`, `FeedCenter.swift`, `FeedNewestRule.swift`, `LibraryViewModel+Succession.swift`, the sheets, every existing test.
