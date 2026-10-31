# bughunt-feeddownloads: Cancel Download says what happens, and a download asked for again while one stops is not lost

Worker slug `bughunt-feeddownloads`, branch `bughunt/feeddownloads` (from `team/bughunt`). Read `README.md` beside this file first. Two fixes in `TextMouth/Services/Feeds/FeedDownloadManager.swift`, one commit each, each with its tests.

## 1. Cancel Download while the episode's book is being added says "Stopped downloading", but the book arrives and becomes the listener's for good
`FeedDownloadManager.cancel(_:of:)` (lines 322-341), for the download under way, only calls `currentTask?.cancel()`. Once the transfer is done, the import runs in `importAndCommit` (`:815-856`) on the import queue, where a task's cancellation means nothing ("an import is never stopped partway"), and `commit` (`:870-887`) adds the book. Meanwhile `FeedCenter.cancelDownload` (`FeedCenter.swift:1025-1028`) made the item the listener's (`downloadOrigin = .listener`), so the newest-N rule never removes it, and `FeedCommandRunner` (`TextMouth/Views/Feeds/FeedCommandRunner.swift:285-292`) announced "Stopped downloading “X”." The downloads section's Cancel already handles this moment: `cancelTargets` (`:440-456`) treats the current download as `finishing` when `progress.state.download?.isAddingToLibrary == true`, keeps whoever asked for it, and `FeedDownloadProgressWording.cancelled(stopped:finishing:comingBack:)` (`TextMouth/Models/FeedDownloadProgressWording.swift:199-219`) says "“X” is already being added to the library."

Fix:
1. One computed property saying whether the current download's book is being added (the test `cancelTargets` makes today), used by `cancelTargets` and by `cancel` (DRY).
2. `cancel(_:of:)` returns, `@discardableResult`, a small enum: `stopped`, or `finishing` when the item is the current download and its book is being added. In the `finishing` case it does nothing else: no task cancel, no state change, no resume data to discard. Every other case is as now and returns `stopped`.
3. `FeedCenter.cancelDownload(_:of:)` returns that outcome, `@discardableResult`, and makes the item the listener's only when it `stopped`; its doc comment says so. `FeedLifecycle.deleteItem` (`FeedLifecycle.swift:279`) keeps ignoring the outcome: a deleted item's import is already discarded at `commit`.
4. `FeedCommandRunner`'s `.cancelDownload` announces, for `finishing`, the same sentence the downloads section's Cancel says. Move that sentence into one function, `FeedWording.alreadyBeingAdded(title:)` in `TextMouth/Views/Feeds/FeedCommands.swift` beside `downloadCancelled(title:)` (doc comment: what VoiceOver hears when Cancel Download comes too late, the book already being added), and have `FeedDownloadProgressWording.cancelled` call it, so the words exist once: "“\(title)” is already being added to the library."

Tests, in `FeedDownloadTests` (grep `beforeCommit` there and in `FeedNewestRuleTests` for how a test acts at the commit): a download the newest-N rule asked for (`origin: .window`), with `center.cancelDownload` called in `beforeCommit`: the outcome is `finishing`, the item ends downloaded with its origin still the rule's, and its book is in the library. A cancel of a download still transferring is `stopped` and makes the item the listener's, as today. Pin the sentence: `FeedWording.alreadyBeingAdded(title: "Ep. 3")` is exactly "“Ep. 3” is already being added to the library.", and the existing tests of `FeedDownloadProgressWording.cancelled` pass unchanged. If a test class drives `FeedCommandRunner`'s `.cancelDownload` (grep `FeedUICommandsTests`), add the finishing announcement there too.

## 2. A download asked for again while a cancelled one winds down is lost
`download(_:of:origin:opening:startingNext:)` (`:268-313`) merges a new ask for the current item into `current` (`:287-294`) even when `cancel` has already cancelled `currentTask`. The dying run then ends in `run`'s cancelled branch (`:657-663`), which marks the item not downloaded and announces the cancellation; the new ask, its opening included, is gone. The listener who chooses Cancel Download and then Download or Open at once, or a reader waiting for its next episode, ends with nothing and nothing opens.

Fix:
1. In `download`, merge into `current` only when its task is not cancelled (`currentTask?.isCancelled != true`); otherwise queue a fresh request exactly as an item not under way is queued (opening or starting next puts it first), and mark the item downloading as today.
2. In `run`'s cancelled branch, when the same item waits in the queue again, leave its state as it is and announce nothing for the stopped request (the new ask speaks for itself); log one trace line saying it was asked for again. `startNext()` then runs the new request.

Tests, in `FeedDownloadTests`, beside `testCancellingStopsADownload` (`:511`): start E's download with a transfer the test holds open (as that test does), cancel it, and before the cancellation settles ask to open E (`center.open` or `downloads.download(..., origin: .listener, opening: true)`); E ends downloaded and its book was opened (the class's open hook). The same with a plain Download ends downloaded. Cancel alone still ends not downloaded and announces the cancellation (the existing test).

## Run
`FeedDownloadTests FeedNewestRuleTests FeedDownloadProgressEngineTests FeedDownloadProgressWordingTests FeedUICommandsTests EpisodeDownloadContinuationTests FeedLifecycleTests` (grep each name; drop any that does not exist and say so in your report).

## Do not touch
`cancelEveryDownload()`'s behavior, the transfer code, `FeedLibraryPresentation.swift` (team `views` owns it tonight), and any wording other than moving the one sentence.
