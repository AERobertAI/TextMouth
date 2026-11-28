# Feeds
<!-- id: feeds; keys: podcast, RSS, Atom, article feed, subscription, FeedCenter; src: TextMouth/Services/Feeds/FeedCenter.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Feed records
<!-- id: feed-records; keys: FeedRecord, FeedEvent, Feeds/<id>.json, podcast, subscription store, FeedPaths; src: TextMouth/Models/Feed.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/ViewModels/LibraryViewModel+DeleteFeed.swift, TextMouth/Services/Feeds/FeedParser.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/PersistenceFailureCenter.swift, TextMouth/Services/SavedFile.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

Feed records (FR03): each subscription and the episodes and articles it keeps.

- Owner: FeedStore, on the main actor, inside FeedCenter.shared.
  Each subscription's record (FeedRecord, in format FeedRecord.currentFormatVersion, 1) holds the Feed:
  - its address, title, folder by ID, the newest item date, after which an item is new, whether it uses plain http, its size as its last read found it, its own List and download choice and delete-after override,
  - the date the listener unsubscribed, nil while subscribed (Feed.unsubscribedDate, written only once set, read through Feed.isSubscribed; FR11's branch D),
  - and, until the move to the choice clears it, a retired kept-entries number,
  - and its items, newest first (FeedItem, each with its download's state, who asked for its download last, when it played, when its download was deleted, and when the item was deleted).
  An item's state may be inLibrary(bookID:), once Move to Library… made its download a book of the library's own: FeedItemState.libraryBookID reads it, linkedBookID either kind, and bookID stays a download's alone.
  An item In Library is always listed, never new, not counted as a download, and counted among the newest N items.
  The size, Feed.entryTotal, a FeedEntryTotal, counts the entries the feed lists, each once, the ones the listener deleted among them, and says whether the feed lists more than the parser reads (listsMore, past FeedParser.maximumItems, 2,000).
  It is optional, so an older record loads without it.
  It is one file in the data directory's Feeds folder, `Feeds/<feed ID>.json` (FeedPaths), pretty-printed with sorted keys and ISO 8601 dates.
  The file's name decides the feed's ID, so a sync service's conflict copy is never read.
  Beside it, `Feeds/<feed ID>/` holds:
  - the feed's downloaded items' packages and its own index of them, which the library model owns ([Feed items](library-index-reading-feeds.md)),
  - and, hidden, a kept package set aside while a download replaces it (.replaced- and the package's name)
  - and, in a library in the cloud, the notes of launches that found the record missing (.record-absent- followed by a Mac's ID and a launch's, FeedRecordAbsence).

### Who may write feed records
<!-- id: feed-record-writers; keys: FeedReconciler, Delete Feed, applySync, leavingLibraryFolder; src: TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedCenter+Sync.swift, TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift -->

- Who may write it:
  - FeedCenter's operations (subscribing, unsubscribing and resubscribing, a feed's folder and its own settings, marking an item played or unplayed, or every item played, deleting a download or an item, and deleting the feed, below),
  - FeedReconciler's merges of a refresh,
    - each of which records the feed's size before the kept-entries rule, whose number is now the feed's listing ([List and download choice, newest-N rule](feeds-interface.md)),
    - chooses the items kept, keeping beside the newest every item downloaded or downloading, every item played (board #1412), and every item whose row the library keeps after its file went (FeedReconciler.kept, keepingRecordsOf:, FR11's branch A2),
  - the download manager,
  - the lifecycle (played downloads, below),
  - the newest-N rule and the move to the List and download choice ([List and download choice, newest-N rule](feeds-interface.md)),
  - and Move to Library…, which marks an item In Library ([Feed items](library-index-reading-feeds.md)).
  Each durable change is written atomically on the store's serial queue, as storage work (StorageWork.savingFeeds), so a data-directory move waits for it; a download's progress is never written, an item downloading or waiting to being written as not downloaded (FeedRecord.durable).
  While the data directory is unavailable, or after a write fails (FEED_RECORD_SAVE_FAILED), the change waits in memory, written with the feed's next change or once the data directory is back.
  A failed write is reported to PersistenceFailureCenter under feed subscriptions (feedRecords, keyed by the feed).
  So the banner offers Retry, which writes the record as it is now on the write queue, after every write asked for before, and waits for it (retryWrite(of:failureID:)), waiting out held storage work ([saving failures](saving-failures.md)); quitting asks first.
  The feed's next write that succeeds settles it, and removing the feed's record withdraws it (FeedStore.remove(_:), which Delete Feed… calls).
  FeedEnvironment.failureCenter names the center, so tests use their own.
  Delete Feed… (FeedCenter.deleteFeed(_:), Services/Feeds/FeedCenter+DeleteFeed.swift, FR14) is the one command that deletes a feed, subscribed or not, in an order whose every stopping point is safe.
  It refuses while one of the feed's downloads is in use, open in a reader, being transcribed, or being exported (FeedLibraryHost.feedBookUse(of:); FeedDeleteError.downloadInUse(title:use:), FEED_DELETE_REFUSED).
  A deletion another device made (FR56, [Library sync](library-sync.md)) arrives through FeedCenter.applySync(_:) in Services/Feeds/FeedCenter+Sync.swift, which calls deleteFeed(_:leavingLibraryFolder: true): the library folder is left to its own sync keys, the outcome says .none, and a feed with a download in use waits for a later sync.
  The same sync adds a feed another device subscribed to (checked at once when subscribed) and writes its changed synced fields through the engine's commands.
  Then it closes the feed's downloads (FeedDownloadManager.closeFeed(_:), below) and waits for the imports and rule removals already on the import queue (runBesideImports):
  - removes the feed's downloads and the packages it kept for removed downloads as Delete Episode removes one, the Trash or for good as the removal setting says,
    - every row of the feed (LibraryViewModel.everyRow(ofFeed:), ViewModels/LibraryViewModel+DeleteFeed.swift) leaving the library and its reading list and the indexes written before any file goes (FeedLibraryHost.removeFeedFiles(of:keepingPackages:remove:)),
    - so a failed write deletes nothing (FeedDeleteError.indexNotWritten, FEED_DELETE_PUT_OFF) and a package that can't go keeps the feed with what stayed (filesStayed, FEED_DELETE_STOPPED);
  - forgets the feed's index for good (forgetFeedIndex(of:)), so no save makes its folder anew,
  - and removes `Feeds/<feed ID>/` (FEED_DELETE_FOLDER_LEFT when it can't, for the next launch, which finds the folder without its record and, since it holds no package, deletes it, returning nothing);
  - removes the record and this Mac's fetch details last (FeedStore.remove(_:), FeedFetchStates.remove(_:)), since a launch that found the folder with its record gone would return the downloads as books;
  - and removes the feed's library folder only when nothing else is in it, no book of the library's own, folder, or other feed's items (removeFolderOfDeletedFeed(_:), FEED_DELETE_FOLDER_KEPT when it can't).
  It returns a FeedDeleteOutcome, the downloads and kept packages deleted and the folder's fate (FeedFolderFate), and writes FEED_DELETED.
  A book without the feed's link, as an item moved into the library, stays.
- How others observe it: FeedCenter republishes every change of the records and the fetch details, publishes the feeds refreshing (refreshingFeedIDs), and sends FeedEvent values:
  - a subscription, a refresh's end, the end of a refresh of every feed, a download's start, end, failure, or cancelling (downloadCancelled(feedID:itemID:)),
  - and a change of the List and download choice taking effect, itemPolicyApplied(global:feedIDs:),
  - which the interface reads ([The feed reader's interface](feeds-interface.md)).
  A record that can't be read is preserved beside itself (SavedFile.preserveUnusable, FEED_RECORD_UNREADABLE) and its feed left out; one only in the cloud is asked of the sync service and read at the next refresh of every feed (FEED_RECORD_IN_CLOUD).

## This Mac's fetch details
<!-- id: this-mac-fetch-details; keys: ETag, Last-Modified, If-None-Match, 304, conditional request, machine-local; src: TextMouth/Services/Feeds/FeedFetchState.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

This Mac's fetch details.

- Owner: FeedFetchStates, on the main actor: for each feed,
  - the ETag and Last-Modified date a refresh sends back, the SHA-256 digest of the body last read, the number of entries kept when it was merged,
  - the last check and the last success, the last failure's sentence, and whether the server said the feed is gone.
  One file per feed in this Mac's Caches folder (MachineLocalPaths.feedCaches, Fetch `State/<feed ID>.json`), written on a serial queue of its own and never synced, since a refresh changes them every time.
  A file that can't be read counts as missing, and macOS emptying Caches only means each feed is read whole once.
  It also notes the updatedDate of the record after the merge of the last body read (recordUpdatedDateOfLastBody, decoded leniently, so an older file still reads).
  And FeedRefresher.fetchAndRead counts the last body, by its digest or a 304, as merged only while the loaded record has that date, to the whole second (lastBodyIsMerged(into:)).
  Otherwise it reads the feed whole and merges again, so a merge whose write was lost, when TextMouth quit or the data directory was unavailable, never hides its new episodes behind an unchanged check.
  A merge that changed no item keeps the record's date.
- Who may write it: the refresher after each check, and subscribing.
  Unsubscribe keeps them, for Resubscribe's check (FR11's branch D); Delete Feed… removes them with the feed's record (FeedFetchStates.remove(_:), FR14).
- How others observe it: the refresher's conditional requests, and FeedCenter.fetchState(of:).

## A refresh
<!-- id: refresh; keys: FeedRefresher, RSS, Atom, JSON Feed, Refresh All Feeds, App Transport Security, digest; src: TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedNetwork.swift, TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/Feeds/FeedDates.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedDiscovery.swift, TextMouth/Services/Feeds/JSONFeedParser.swift, TextMouth/Services/Feeds/FeedJSON.swift, TextMouth/Resources/Info.plist, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

A refresh.

- Owner: FeedRefresher, inside FeedCenter.shared, which fetches through FeedNetwork: two ephemeral URLSessions, one for feeds and web pages and one for downloads, which cache nothing on disk, keep no cookies, and send TextMouth's own User-Agent.
  They are the app's only network connections, a search of the podcast directory going through them too, and App Transport Security allows arbitrary loads (Info.plist), since many feeds and episode hosts still use plain http; a feed that uses http is flagged (Feed.usesInsecureTransport).
- Who may write it: FeedCenter: at launch when feedRefreshAtLaunch is on, every feedRefreshIntervalHours hours while TextMouth runs (never while that is 0, and a turn that falls in Low Power Mode is skipped), and when the listener asks (refresh(_:) and refreshAll(origin:)).
  The refreshes TextMouth makes by itself never use an expensive or constrained network, and skip a feed the server called gone (FeedRefreshOrigin.isDiscretionary).
  At most four feeds refresh at once, and one feed's refreshes never overlap.
  A feed the listener unsubscribed from is never refreshed (FR11's branch D; FeedRefresher.isChecked(_:)):
  - refreshAll(origin:) passes over it, with no report,
  - refresh(_:origin:) returns nil before fetching,
  - and a fetch under way as the listener unsubscribed changes nothing once it ends;
  - Check Feed chosen from a menu drawn before says so (FeedWording.notChecked(title:)).
- How others observe it: a fetch sends the last ETag and Last-Modified date, and a 304, or a body whose digest matches the last, is unchanged, the feed's size kept as it was, unless:
  - the number of entries kept has changed since,
  - or the record does not know its feed's size (Feed.entryTotal nil), when FeedRefresher.fetchAndRead sends no validators and reads the feed whole once.
  FeedParser reads RSS 0.9x and 2.0, RSS 1.0, and Atom, with Apple's podcast elements and Podcasting 2.0's, up to 25 MB and 2,000 items, with XMLParser, and reads a document that isn't well-formed again through XMLDocument's tidy mode (FEED_PARSE_REPAIRED).
  A document whose first character is "{" is JSON Feed, 1.1 or 1.0, which JSONFeedParser reads, through FeedJSON, into the same ParsedFeed (format json), so it is merged, listed, and downloaded as any other; JSON that names no JSON Feed version is no feed.
  The readers share the rules for choosing an enclosure (FeedEnclosure.preferred(among:otherwise:)), an untitled item's stand-in title (ParsedItem.standInTitle(from:isHTML:)), and dropping content that only repeats the summary (ParsedItem.isRepeating(_:_:)).
  FeedDiscovery takes a page's application/feed+json alternate too, never plain application/json.
  The fetch, the parse, and a first merge (FeedReconciler) run off the main actor; a second merge on the main actor folds the result into the record as it is by then, so what the listener did meanwhile is kept.
  A feed that moved for good, by a permanent redirect or itunes:new-feed-url, is fetched from its new address from then on (FEED_MOVED).
  Each refresh ends in a FeedRefreshReport, and a refresh of every feed in a FeedRefreshSummary, which FeedCenter sends as events.
  Each refresh's end (refreshEnded) then asks for a sweep of played downloads and a pass of the newest-N rule over its feed, which downloads what the feed's List and download choice keeps downloaded ([List and download choice, newest-N rule](feeds-interface.md)).
  The transfers and fetches wait on a FeedOnceContinuation (Services/Feeds/FeedNetwork.swift), resumed once only, by whichever comes first, the task's end or its cancel, since a CheckedContinuation resumed twice traps.
  A transfer or fetch cancelled before it begins throws its cancelled failure before any URLSession task exists (even offline).
  And one cancelled between the check and the delegate is caught by URLSessionTask.resumeUnlessCancelled(otherwise:), so a cancel in the turn a download starts never leaves FeedDownloadManager.run waiting for good.

## Downloads
<!-- id: downloads; keys: FeedDownloadManager, episode, enclosure, quit, Command-Q, partial download, queue; src: TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedDownloadManager+PartialDownloads.swift, TextMouth/Services/Feeds/FeedTransfer.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Services/Feeds/FeedTextConverter.swift, TextMouth/Models/FeedBookLink.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/Book.swift, TextMouth/Services/FileImportService.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/ImportStaging.swift, TextMouth/App/QuitFinisher.swift, TextMouth/Platform/macOS/Views/QuitNotice.swift -->

Downloads.

- Owner: FeedDownloadManager, inside FeedCenter.shared, which downloads items one at a time:
  - in the order asked,
  - an item the listener opens, or a reader waits to go on to, coming first (download(_:of:origin:opening:startingNext:), which FeedCenter.download(_:of:startingNext:) calls for the reader's wait, opening nothing),
  - though never ahead of the download under way.
  An item asked for again while it waits keeps its place in the queue, unless the new ask opens it or starts it next, so a listener who asks at every Play does not send it to the back.

### Who may write downloads
<!-- id: downloads-writers; keys: cancelDownload, closeFeed; src: TextMouth/Services/Feeds/FeedDownloadManager.swift -->

- Who may write it: FeedCenter's download, open, and cancelDownload, and the newest-N rule (the List and download choice, below), whose discretionary downloads never use a network with data limits.
  A download records who asked for it as it finishes, or fails (FeedItem.downloadOrigin): the listener whenever the listener asked for it at any point, or made the item theirs meanwhile, otherwise the rule (FeedDownloadOrigin.after(_:given:), which never overwrites the listener's).
  A download stopped as its file arrives, by Cancel Download or the downloads section's Cancel, stops before its import (Task.checkCancellation() in downloadEpisode; feed review item 15), as an article stops before its book is written.
  Cancel Download makes its item the listener's, while the section's Cancel leaves each item whoever's it was (FR14).
  Each of those cancels, and the one Delete Feed… makes, sends FeedEvent.downloadCancelled(feedID:itemID:) once its item reads not downloaded (announceCancelled(_:)):
  - at once for a request taken out of the queue (FeedDownloadManager.cancel(_:of:), which cancelDownload calls, cancelEveryDownload(), closeFeed(_:)),
  - and for the download under way where its task ends (run(_:)),
  - never for the rule's put-off requests, a download stopped for quitting, or one that fails or finishes.
  The reader waiting for the next episode hears it (see [The reader](reader-navigation.md)).
  Delete Feed… closes the feed's downloads first (closeFeed(_:), closedFeedIDs):
  - the one under way stops,
  - those waiting to start and those put off go,
  - every resume data file of the feed goes with the partial file it names,
  - download(_:of:origin:opening:startingNext:) asks for none of its items,
  - commit(_:for:restoredKeptPackage:) discards the package of an import that ends meanwhile, and a restored kept package (FeedEpisodeImporter.restoresKeptPackage(_:)), through discardPackage(of:asTheListenersDeletion:because:) as Removal Behavior says,
  - closeFeed(_:) marks the items it drops not downloaded (markNotDownloaded(_:of:), shared with cancelEveryDownload() and withdrawRuleDownloads),
  - and the sweep of played downloads and the newest-N rule leave the feed alone, until reopenFeed(_:), once the feed is deleted or left as it was.
  FeedPartialDownloads (Services/Feeds/FeedDownloadManager+PartialDownloads.swift, FR14) removes resume data only together with the partial file it names, which the system keeps in the process's temporary folder.
  It reads every string of the resume data's property list, without decoding the system's undocumented layout, and removes only a plain file directly in that folder named as the system names a partial file, CFNetworkDownload_ and letters and digits then .tmp.
  Cancel Download, a transfer stopped for good, the launch's sweep of week-old resume data, the section's Cancel, and Delete Feed… all remove resume data through it.

### How downloads are observed
<!-- id: downloads-observers; keys: FeedEpisodeImporter, FeedQuitHold; src: TextMouth/Services/Feeds/FeedEpisodeImporter.swift -->

- How others observe it: an episode's file comes through a URLSessionDownloadTask, whose bytes go to the downloads' progress alone (the feed downloads' progress, below), never to its item's state or its record.
  A download that stops partway keeps its resume data in this Mac's Caches folder (Resume Data, a week).
  And the finished file waits in Feed Downloads until FeedEpisodeImporter imports it, as storage work, through the import pipeline (ImportStaging and FileImportService.publishReadableBook),
  - publishing the package in the feed's own folder, `Feeds/<feed ID>/` (destinationPackageURL),
  - and adding the book's row, with its feed link and no library folder, to the library on the main actor before that work ends (addFeedBook(_:); [Feed items](library-index-reading-feeds.md)).
  A download needs the feed's library folder all the same, which lists it: a feed whose folder is gone downloads nothing.
  An episode, audio or video, becomes an audiobook, a video one playing its sound, and an article an HTML book written from its text, or from its web page's article when its own text runs under 200 words and it links a page.
  The book's row and record name its feed and item (Book.feedLink and BookMetadata.feedLink, a FeedBookLink), which its feed's index holds and library.json never does.
  And every later save of the record keeps the link (Book.bookInfo(replacing:contentIndex:revisionFloor:)); writeVerifiedRecord checks it on read-back.
  Whatever an interrupted download left in Feed Downloads is swept away at the next launch.
  A rule download that a network with data limits refused waits (FeedItemState.waiting, FeedDownloadWait.network, with one FEED_DOWNLOAD_WAITING line) and is put off (putOff).
  The next refresh TextMouth makes by itself that wasn't skipped, which shows the network has no data limits now, asks for the downloads put off again (retryPutOffDownloads, from FeedCenter's refreshEnded).
  One that lacks room waits too (FeedDownloadWait.room), for the rule's next pass, which never removes anything to make room; a download the listener asked for still fails for want of room.
  As TextMouth quits, once the unsaved-changes guard lets it, the downloads are one piece of the quit's work (FeedQuitHold.work, kind "feed downloads"; see [Launch](../launch.md)), which ends when FeedDownloadManager.stopForQuit() ends or after three seconds (longestWait), whichever comes first:
  - stopForQuit stops every download (isStoppedForQuit),
  - lists each one asked for, the one under way first and those put off last, in this Mac's resume folder (Downloads at Quit.json, as SavedDownload, each with who asked for it),
  - and then stops the transfer under way, keeping its resume data when its server allows (FeedTransferHandle, through cancelByProducingResumeData).
  The next launch asks for them again (resumeDownloadsSavedAtQuit, after sweepLeftovers), only where the engine works on its own.
  - A quit the person asks for (0.4.4) is cancelled while the downloads keep their place, says so, and is asked again, instead of being left pending.
    - TextMouth says "TextMouth is finishing up before it quits: keeping the place of your feed downloads for next time.
      It will quit as soon as that is done." in a panel and through VoiceOver (QuitFinisher, QuitNotice).
    - A second Command-Q or the Dock's Quit during those three seconds is cancelled too and says the same words again, so it no longer quits at once with the list of downloads half written.
    - Only the system ending the session (log out, restart, shut down) is still answered .terminateLater by FeedQuitHold.hold, since cancelling it would stop the log out.
  - Downloads stopped for a quit that is then cancelled stay stopped (0.4.4).
    The work ends before the quit's last pass through the questions of step 0 and the unsaved-changes guard.
    So a Cancel there (a failed write during the wait, or a library move, a take, or an editor's edits that began meanwhile) leaves TextMouth open with isStoppedForQuit true for the rest of the session.
    Each download is listed for the next launch, which asks for it again.
    Nothing resumes them in the meantime, and FeedQuitHold's comment says so.

## Feed downloads' progress
<!-- id: feed-downloads-progress; keys: FeedDownloadProgress, progress bar, time left, Cancel Feed Downloads, VoiceOver progress, queue; src: TextMouth/ViewModels/FeedDownloadProgress.swift, TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/Models/TimeLeftEstimate.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadProgress.swift, TextMouth/Views/Feeds/FeedDownloadProgressSection.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/FeedItem.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/ViewModels/ImportProgress.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/Feeds/FeedDownloadManager+PartialDownloads.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouth/Views/Library/LibraryView.swift -->

The feed downloads' progress (FR10's feed half): what each Library window's feed downloads section shows, and what VoiceOver hears of a run of feed downloads.

- Owner: FeedDownloadManager.progress, a FeedDownloadProgress (ViewModels/FeedDownloadProgress.swift) on the main actor, whose state is a FeedDownloadProgressState: one run, from the moment the manager has work until it has none.
  It holds:
  - the downloads done and, of those, failed;
  - the download under way (its item's and its feed's titles, when it began, its file's BookDownloadProgress, nil for an article, whose page comes uncounted, and whether its book is being added to the library);
  - the sizes of the downloads waiting to start, as their feeds give them;
  - the newest-N rule's downloads waiting apart (FeedDownloadWaits: those put off for a network, FeedDownloadManager.putOff, and those waiting for room, which only their items' waiting states say), which outlast the run;
  - what the run's downloads took (WorkTiming, each timed from its start to its book in the library, a failure untimed);
  - when the run began;
  - and whether Cancel was pressed.

### Who may write the feed downloads' progress
<!-- id: progress-writers; keys: rulePauses, cancelEveryDownload; src: TextMouth/ViewModels/LibraryViewModel+FeedDownloadProgress.swift -->

- Who may write it: the manager, on the main actor.
  It tells the progress:
  - the queue after every change (publishQueue()),
  - each download's start (beginProgress(of:)),
  - every report of its bytes (receive(_:), through downloaded(_:of:estimate:for:), which changes the state without publishing),
  - its book being added (importAndCommit),
  - and how run(_:) ended (a FeedDownloadEnding: downloaded or failed, which are done, or waiting or stopped, which leave the run).
  A change that leaves nothing to run ends the run and forgets it, keeping the waits.
  Quitting clears it (stopForQuit(), through clear()), and it stays clear while the quit waits: publishQueue() and the end of the download under way tell it nothing once isStoppedForQuit (feed review item 21).
  Cancel is FeedCenter.cancelEveryDownload(), through LibraryViewModel.cancelFeedDownloads() (LibraryViewModel+FeedDownloadProgress.swift), a pause rather than a refusal (FR14).
  It calls FeedDownloadManager.cancelEveryDownload(), which:
  - cancels the task under way, unless its book is being added, which finishes;
  - empties the queue and the downloads put off;
  - sets every item it stopped back to not downloaded, the rule's waiting for room among them, which only their items' states say, in one change of each feed's record, each keeping who asked for it (FeedItem.downloadOrigin);
  - deletes every resume data file with the partial file it names (FeedPartialDownloads.discardAll(in:prefix:temporaryFolder:)) and, unless a book is being added, the files waiting in the holding folder;
  - tells the progress (cancel(), FEED_DOWNLOADS_CANCELLED);
  - and returns a Cancellation (stopped, finishing, and feedIDs).
  The center then pauses the newest-N rule for each of those feeds (rulePauses, a FeedRulePause: untilNextCheck, or untilTheCheckAfterTheOneUnderWay for a feed being checked as Cancel was pressed).
  So applyItemPolicy asks for none of its items until refreshEnded lifts the pause (endRulePause(afterCheckOf:)) at the end of a check of the feed that began after Cancel, the regular check, Check Feed, or Refresh All Feeds.
  Unsubscribe and Delete Feed… clear a feed's pause, a change of its List and download choice doesn't, and none outlives the process, so the next launch's pass covers every feed.
  The listener's own Download is never held back.
  The section's Cancel goes through LibraryWindowView.cancelFeedDownloads(of:in:), which:
  - moves VoiceOver's focus to the Library window's list once the section has gone, VoiceOverAnnouncer.afterSheetDelay later (focusListAfterCancel; feed review item 19),
  - and only once those focus attempts have been posted announces what Cancel did (FeedDownloadProgressWording.cancelled(stopped:finishing:comingBack:), REV13 item 3).
  cancelTargets and Cancellation.Stopped (feed, item, title) back cancelEveryDownload() and downloadsCancelWouldStop.
  FeedCenter.comingBack(of:) counts as a FeedCancelReturn those the rule downloads again by itself (ruleWouldDownload(_:) among countedItemIDs(in:under:)).
  So FeedDownloadProgressWording.comingBack(_:) says only what will happen, in cancelled(stopped:finishing:comingBack:) and cancelButtonHint(_:).
  FeedCenter.cancelButtonHint() feeds FeedDownloadProgressSection's hint.
  A download that begins after Cancel, as one the listener asks for while the one Cancel let finish is being added, ends the cancelling (FeedDownloadProgressState.begin(_:); feed review item 13).
  Before it writes its book, downloadArticle checks for cancellation, so an article stopped while its page was fetched is not written from its summary, by Cancel Download either.

### How the feed downloads' progress is observed
<!-- id: progress-observers; keys: FeedDownloadProgressObserver, TimeLeftEstimate; src: TextMouth/Views/Feeds/FeedDownloadProgressSection.swift -->

- How others observe it: only FeedDownloadProgressObserver (Views/Feeds/FeedDownloadProgressSection.swift) observes it, through a ProgressObserver (Views/ContentView.swift), as the import and text overlays observe theirs.
  And LibraryWindowView (Views/ContentView.swift) attaches it below LibraryView with safeAreaInset, so it insets the list rather than covering it.
  It draws FeedDownloadProgressSection only while downloads run, inside a TimelineView that shows it anew every 5 seconds from the run's start (FeedDownloadProgressWording.refreshInterval), which brings the bytes the state keeps without publishing.
  So a download's bytes never compare a feed's record (#1410) or redraw a list or a feed row (PERF12), and FeedItemState.downloading carries no progress: an item's row says "Downloading" without a percent, and a kept place beside it is spoken as "42 percent read" (FeedKeptProgress).
  The section is a container labelled with all its lines (spokenStatus(at:)), holding its heading, its bar (overallBarLabel), its lines, and Cancel (cancelButtonLabel, "Cancel Feed Downloads", and cancelButtonHint), dimmed once pressed.
  TimeLeftEstimate (Models/TimeLeftEstimate.swift) gives the time left once one download has reached the library (secondsLeft(at:)), and none once Cancel is pressed.
  A run the newest-N rule began, which nobody heard begin, is announced once as it has lasted ImportProgress.announcedAfter, at medium priority, with the downloads under way and the time left (FeedDownloadProgressWording.underWay(_:secondsLeft:)).
  The announcement comes from announceStartIfDue(at:), for a run whose first download began byItself, unless a quarter was heard or Cancel pressed first (feed review item 17).
  A run that has lasted ImportProgress.announcedAfter, 10 seconds, announces each quarter of its downloads once, at medium priority, and its end, naming the download of a run of one, unless Cancel was pressed or nothing downloaded, failed, or waits.
  What Cancel stopped is said by the window it was pressed in, once its focus has moved (above):
  - the downloads stopped,
  - the download that finishes all the same,
  - and when TextMouth downloads again by itself (FeedDownloadProgressWording.retryAfterCancel), which the Cancel button's hint says too.
  ShortcutAction.speakDownloadProgress, under Information with no default key, working in every window but an audio editor's, and Library > Speak Download Progress post speakDownloadProgress, which the library model hears (observeDownloadProgressRequests()).
  The library model answers with FeedDownloadManager.spokenProgress(), which counts the waits anew first, since a wait for room lives only in its item's state.

## Played downloads and their deletion
<!-- id: played-downloads-their-deletion; keys: playedDate, downloadDeletedDate, Delete Download, delete after, bookDidFinish, Trash; src: TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouthProductionTests/FeedItemRecordTests.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Models/FeedBookUse.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/ViewModels/TranscribedBooks.swift -->

Played downloads, and their deletion.

- Owner: each item's playedDate and downloadDeletedDate, in its feed's record.
- Who may write it: ReadingStatsService.markBookFinished posts bookDidFinish, and FeedCenter marks the item whose download finished played (FEED_ITEM_PLAYED), so a finished episode or article counts among Books Finished too.
  The listener sets or clears it with markPlayed(_:of:) and markUnplayed(_:of:), and markAllPlayed(of:) sets it for every item of a feed not played yet, in one change of its record.
  A sweep (requestSweep()) runs at launch, after each refresh, when an item plays to its end or is marked played, and whenever the books open in readers change, as when a reader closes.
  It deletes the file of each download played at least feedDeleteDownloadsDaysAfterPlayed days ago, or the feed's own number (0 at once, -1 never), for good, with dataless files left in the cloud.
  It keeps the package, with an article's content.md in it (FeedItemPackage.staysWithoutTheFile(_:)), while it holds the listener's state, in the order the feed items entry gives ([Feed items](library-index-reading-feeds.md)).
  It deletes under these limits:
  - never a book in use, which the sweep leaves for its next pass (FeedLibraryHost.feedBooksInUse:
    - one open in a reader, one an export is reading, BookExportModel.booksBeingExported, the one being transcribed, TranscribedBooks.shared.transcribingBookID,
    - and a book whose text is being edited with Edit Text, LibraryViewModel.textEditSessions.bookIDs, which the rules wait for but the listener's own deletions do not, since an editing session ends only when TextMouth quits and a refusal would stand until then;
    - FeedDueRemovalOutcome.inUse and the reports' inUseBookIDs; REV11 F1),
  - never while the library's index is being recovered, never a download made before FR11 that has not moved into its feed's folder,
  - and, in a library in the cloud, only a package this Mac holds whole, as the packages' cloud states, read off the main thread first, say (packagesHeldWhole, FEED_SWEEP_LEFT_IN_CLOUD).
  The removal goes through removeDue(_:from:by:at:putOffEvent:), which the newest-N rule shares ([List and download choice, newest-N rule](feeds-interface.md)):
  - the records and the feeds' indexes are written and waited for on the main actor (LibraryViewModel.readyFeedFilesForRemoval(of:keepingPackages:)),
  - the files are removed off the main thread, on the download manager's import queue (FeedDownloadManager.runBesideImports(_:)), inside StorageBoundary.perform as StorageWork.removingFeedDownloads,
  - so a data-directory move waits for a removal under way and a removal waits while a move holds the work (it logs FEED_DOWNLOAD_DELETE_WAITING while held),
  - reading TextMouthPaths.root only after any wait so it removes from the data directory as the move left it,
  - and the outcome is settled on the main actor (settleFeedFileRemovals(_:failures:)).
  No removal races a download restoring an item into its kept package, though not for the thread it runs on: a due download's row is among the books, while a restore is asked for only once its row is on the feed's shelf, and the restore's import then waits on that queue behind the removal.
  Each removal writes FEED_DOWNLOAD_DELETED, saying whether the package was kept and which rule removed it.
  A failed index write puts the sweep off (FEED_SWEEP_PUT_OFF), and the newest-N rule's removals (FEED_RULE_PUT_OFF), whose passes log what they asked for (FEED_RULE_DOWNLOADS) and the downloads they left in the cloud (FEED_RULE_LEFT_IN_CLOUD).
  And an item whose book the library no longer lists is noted not downloaded (FEED_DOWNLOAD_FORGOTTEN).
  A rule's removal notes its item not downloaded only while the item still names the book it removed (FeedCenter.noteDownloadGone(_:of:at:byListener:removing:), REV11 F5).
  So an item asked for again meanwhile, as Open asks for one, says so for its whole transfer, as is an item In Library whose book has left the library (FEED_LIBRARY_BOOK_GONE, FR11's branch D).
  A book In Library is the library's own, which no rule of its feed removes.

### The listener's deletions
<!-- id: listener-deletions; keys: deleteDownload, Delete Episode; src: TextMouth/Services/Feeds/FeedCenter.swift -->

  The listener's Delete Download (deleteDownload(_:of:)) and the library's Remove of a feed item (deleteDownload(ofBook:in:)) remove the file in the same order, keeping the package, but all on the main actor, through removeFeedFiles(of:keepingPackages:remove:).
  They take an article's content.md with the file.
  Delete Episode (deleteItem(_:of:)) removes the package whole, kept or not, each following the removal setting's choice of the Trash and refusing a download in use (FeedLibraryHost.feedBookUse(of:), FeedBookUse; the feed follow-ups after FR14, item 1).
  The removal throws FeedDownloadInUseError, whose sentence names the download and what to do (FEED_DOWNLOAD_DELETE_REFUSED).
  The listener's deletions refuse a download in use rather than wait for its use to end, as the rules leave it for their next pass, since a deletion carried out minutes later, unannounced, could take a download the listener had since decided to keep.
  Delete Feed… refuses the same way (FeedDeleteError.downloadInUse(title:use:)), and LibraryFeedsPresenter.refusal(for:) words the alert.
- How others observe it: the item stays in its feed's record, not downloaded, and a kept package's row on its feed's shelf; and an item deleted (deleteItem(_:of:)) stays in the record too, out of every list, so no refresh brings it back.
  The record of a deleted item the feed no longer lists is kept, deleted, for FeedReconciler.deletedItemRetention, 90 days from its deletion, decided by keepsUnlisted(_:at:keepingEveryDeletion:).
  When a read lists none of the record's items, every deleted record is kept whatever its age, so one empty or cut-short channel forgets no deletion.
  The retention counts from the deletion, not from when the feed last listed the item, which would need a date in the feed index.
  FeedDownloadManager.cancel(_:of:) returns whether the download stopped or finishes, .finishing for the one whose book is already being added (isAddingToLibrary), and FeedCenter.cancelDownload(_:of:) makes the item the listener's only when it stopped.
  Only while its task is not cancelled does download(_:of:origin:opening:startingNext:) merge a new ask into the download under way; otherwise it queues a fresh request, which run's catch leaves alone.
