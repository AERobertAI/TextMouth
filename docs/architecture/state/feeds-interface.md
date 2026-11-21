# Feed options, interface, and arrivals
<!-- id: feed-options-interface-arrivals; keys: podcast, RSS, Library window, Feeds tab, listening options, notifications; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Views/Feeds/FeedRows.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## List and download choice, newest-N rule
<!-- id: list-download-choice-newest-n; keys: FeedItemPolicy, keep newest, Settings Feeds tab, delete after, List and download, Choice, aged out; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Models/FeedSettings.swift, TextMouth/Models/Feed.swift, TextMouth/Models/FeedItem.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedFetchState.swift, TextMouth/Services/ConfigService.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouthProductionTests/FeedItemPolicyTests.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Models/FeedDownloadProgressWording.swift -->

The List and download choice, and the newest-N rule (FR11's branch B): which of each feed's items the library lists, and which download by themselves.

- Owner: FeedItemPolicy (Models/FeedItemPolicy.swift), a value holding:
  - a Choice (everyListedNewestDownloaded, the default, everyListedDownloadsByHand, or onlyNewestListed, saved by those raw values)
  - and newestCount (a number kept within SettingsPolicy.feedNewestCount, a WholeNumberSettingRule: 1 to 2,000, 5 by default),
  - from which it derives listing (every, or newest(n), whose keptEntries, -1 or n, the refresher hands the reconciler where the retired kept-entries number went, and FeedFetchState.keptEntriesOfLastBody records)
  - and downloading (newest(n), or byHand), so no fourth combination can be stored.
  The choice for every feed is FeedSettings.itemPolicy, kept in the preferences under feedItems and feedNewestCount (FeedSettings.itemsPreference and newestCountPreference, read together by FeedSettings.itemPolicy(in:)) and mirrored in config.json.
  A feed's own is Feed.itemPolicyOverride, nil to follow it, written into the feed's record only once set, as itemPolicyOverride holding items and newestCount, and read leniently, a value it can't read counting as the default, so one bad value never makes a record unreadable.
  Who asked last for an item's download is FeedItem.downloadOrigin (FeedDownloadOrigin: listener, or window, the rule's discretionary downloads), nil for an item no download has been asked for since the rule came, whose download counts as the listener's.
  A rule download that a network with data limits refused, or that lacks room for the size its feed gives beside the 1 GB TextMouth keeps free, waits (FeedItemState.waiting, with the reason FeedDownloadWait gives: network, or room(bytes:)), which FeedRecord.durable writes as not downloaded.
  So a feed's record never holds a wait.
  The waits for a network are kept, in order, in FeedDownloadManager.putOff, which quitting lists in this Mac's Downloads at Quit.json ([Downloads](feeds.md)).
- Who may write it: the Feeds tab of Settings (FeedItemPolicyControls, through SettingsViewModel.feedSettings) and config.json, for the choice for every feed.
  Feed Info, through FeedCenter.setItemPolicy(_:of:), which sets a feed's own, a change of which the list follows at once while the rule waits the ten seconds, and itemPolicy(of:) reads the one a feed follows.
  The retired settings move once.
  FeedSettings.moveToItemPolicyIfNeeded(in:), first thing in FeedCenter.start(library:), writes the choice from feedKeepEntries and feedAutoDownload through FeedItemPolicy.migrated(keepEntries:autoDownload:): kept as shipped, or with automatic downloads on, the default.
  Every entry kept, everyListedDownloadsByHand.
  Any other number n, onlyNewestListed with n.
  Writing the choice's key marks the move done, and a number the store already holds is kept.
  FeedCenter.moveKeptEntriesOverrides(), as the records load and again at each refreshAll(origin:), gives each feed whose record still holds the retired Feed.keepEntriesOverride the choice it asks for, through migrated(keepEntriesOverride:under:), and clears it.
  A number n gives onlyNewestListed with n; every entry gives the global choice while that lists every item, and everyListedDownloadsByHand otherwise.
  An item becomes the listener's (downloadOrigin listener) when:
  - the listener asks for its download, even while the rule's waits or runs,
  - cancels it (cancelDownload(_:of:)),
  - deletes it (Delete Download, the library's Remove, and Delete Episode, through noteDownloadRemoved),
  - or when a download the listener asked for fails.

### How the list and download choice is observed
<!-- id: item-policy-observers; keys: listedItems, newest-N rule; src: TextMouth/Services/Feeds/FeedNewestRule.swift -->

- How others observe it: FeedCenter.listedItems(of:) lists a feed's items by its listing (FeedRecord.listedItems(under:hasFile:): every item not deleted, or the newest n less those played without their file here, beside every item whose file is here or that downloads or waits, wherever it falls).
  And a feed's folder and its counts read it.
  The newest-N rule (Services/Feeds/FeedNewestRule.swift: FeedCenter.applyItemPolicy(to:retrying:), which returns a FeedItemPolicyPassReport) serves each feed whose choice downloads by itself:
  - it takes back its downloads not yet under way whose items no longer count (FeedDownloadManager.withdrawRuleDownloads),
  - asks for each of the newest n not played that it may download (ruleMayDownload(_:): never an item the listener asked for, deleted, or stopped, nor one whose download made before the rule went; and an item that failed only in a pass that follows a refresh of its feed),
  - and, holding more of its own downloads than n, removes the files of its oldest outside the newest until it holds n, for good, through removeDue(_:from:by:at:putOffEvent:), as the after-playing sweep does ([Played downloads and their deletion](feeds.md)),
  - the removal passing over a download the listener asked for, one on the reading list, one in use (feedBooksInUse, as the sweep), and, in a library in the cloud, one this Mac doesn't hold whole, until a later pass.
  A download that waits or fails removes nothing.
  For a feed that downloads by hand it takes back the rule's downloads not yet under way and removes nothing, and no pass runs while the library's index is being recovered.
  For a feed the listener unsubscribed from (FR11's branch D), whose rules stay in force while checking stops, it takes back its downloads not yet under way and asks for none, while its removals act as above, so its downloads beyond the newest still go.
  An item In Library counts among the newest and is never asked for (ruleDownloads, FeedItemState.libraryBookID).
  FeedCenter.countedItemIDs(in:under:) (Services/Feeds/FeedNewestRule.swift) defines what the rule counts: the newest n not played, while the feed is subscribed to and its choice downloads by itself.
  Each pass withdraws every rule download it no longer counts, those queued, put off, or waiting for room, and those that failed (FeedDownloadManager.withdrawRuleDownloads(of:where:), FeedItem.hasRulesFailedDownload; REV11 F4), so no row says Download Failed of a download nobody asked for.
  The download under way, and the listener's, are never taken back.
  Mark Played and Mark All Played request a pass for their feed, and a refresh's end requests one before it asks again for the downloads put off for a network, only those the rule still counts (retryCountedPutOffDownloads(); REV11 F3).
  A pass requested runs as soon as any sweep or pass under way has finished.
  Being offline is a wait for a network (FeedDownloadWait.network) for the rule's downloads alone, its row giving the one reason that covers both, FeedDownloadWait.network's "it downloads once this Mac is on a network without data limits".
  As the downloads section counts both as "2 waiting until this Mac is on a network without data limits" (FeedDownloadProgressWording.waits(_:), REV13 item 4).
  And a rule's article whose own text is a short summary, whose page a network with data limits or no network refuses, waits likewise rather than being written from its summary (FeedDownloadManager.waitsForANetwork(_:); feed review item 14).
  Passes run one at a time, after the sweep (requestItemPolicyPass(for:retryingFailures:), the passes asked for meanwhile running as one), and only in an engine that works on its own:
  - at launch,
  - after subscribing,
  - after each refresh (trying failed downloads again when the refresh was not skipped, and, after one TextMouth made by itself that was not skipped, first asking again for the waits for a network, retryPutOffDownloads()),
  - when a rule download finishes,
  - and once a change of the choice or the number has stayed unchanged for FeedCenter.itemPolicyQuietTime, ten seconds (itemPolicyChanged(for:));
  - never when a reader closes, which asks for a sweep alone.
  An import whose item was deleted while it ran adds no row and deletes the package it had just published, for good, only inside its feed's folder (FeedDownloadManager.commit, reached at that moment in tests through beforeCommit).

## A feed's listening options
<!-- id: feed-listening-options; keys: ListeningOptions, When an episode ends, Open the next episode in, Feed Info, Folder Settings, next episode; src: TextMouth/Models/ListeningOptions.swift, TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Models/NextBookWindow.swift, TextMouth/Views/NextBookWindowPicker.swift, TextMouth/Models/Feed.swift, TextMouth/Models/BookFolder.swift, TextMouth/Models/Library.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/ViewModels/LibraryViewModel+ListeningOptions.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Views/Library/FolderSettingsSheet.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/ReadingList.swift, TextMouth/Models/EndOfBookRule.swift -->

A feed's listening options (FR19): how listening goes on from one of its episodes to another, and the same for a plain folder's books.

- Owner: Feed.listeningOptions (Models/Feed.swift), in the feed's record: an optional ListeningOptions (Models/ListeningOptions.swift) of
  - a continuation (a ReadingList.Continuation: play the one below, play the one above, or stop; nil is "Use the global setting"),
  - skipsFinished,
  - and predownloadsNext, the last two true by default,
  - and, since 0.2.5, nextBookWindow, an optional NextBookWindow (This Window or A New Window; nil is "Use the global setting", which follows the Playback tab's Open the next book in, in [Windows](windows.md)),
  - which an older TextMouth ignores and drops when it next saves the feed or folder.
  Nil is the standard options, which are never stored, so a feed left as it was has a record exactly as it was.
  The field is read through decodeIfPresent, and ListeningOptions itself reads leniently, a value that is no object as the standard options and a missing or unknown key as its default, so options can never make a feed's record, or the library index, unreadable.
  A plain folder keeps its own the same way, in BookFolder.listeningOptions, in library.json.
  They follow the folder when it is renamed or moved, which change its name and parentPath in place, and Library.mergeEquivalentFolders gives a surviving folder the first duplicate's options when it has none of its own.
- Who may write it: FeedCenter.setListeningOptions(_:of:), which stores nil for standard options and writes the record only when its durable form changed, from Feed Info (FeedInfoModel.episodeEnd, nextEpisodeWindow, skipsFinishedEpisodes, and predownloadsNextEpisode).
  And, for a folder, LibraryViewModel.setListeningOptions(_:ofFolder:), which saves the library once, and saves nothing for a folder that is gone or for options it already has, from the Folder Settings sheet (FolderSettingsModel, in [Windows](windows-sheets.md)).
- How others observe it: LibraryViewModel.listeningOptions(of:) finds the options that govern a book: its feed's for an item of a feed (nil when the feed's record is gone), and otherwise those of the folder that holds it directly, never those of a folder above it (nil at the top of the library).
  The reader weighs them against its book's own choice and the global setting (EndOfBookRule, in [The reader](reader-navigation.md)).
  ListeningOptions.goesOn(under:) says whether listening would go on from one item to another under them, which dims Feed Info's download checkbox (FeedInfoModel.continuesToAnotherEpisode) and the window pop-up of both sheets.
  The pop-up is NextBookWindowPicker, whose isAvailable is FeedInfoModel.continuesToAnotherEpisode or FolderSettingsModel.continuesToAnotherBook; NextBookWindowRule.choiceIsAvailable words the same rule.
  So a dimmed choice is in effect nowhere: NextBookWindowRule.choice then gives the global setting, for the end of a book and for Next and Previous in Folder alike (folderMoveWindowChoice, in [The reader](reader-navigation.md)).
  ListeningOptionsWording words the three older controls once, and NextBookWindowWording the window pop-up (label, choices, hint, and dimmed hint), for Feed Info and Folder Settings.

## The feed reader's interface
<!-- id: feed-reader-interface; keys: Add Feed, Feed Info, Library window, context menu, VoiceOver actions, podcast; src: TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Library/LibraryView.swift -->

The feed reader's interface in a Library window (FR03).

### Interface: what owns it
<!-- id: feed-interface-owner; keys: Folders rotor, LibraryFeedsSection, Delete Folder, feed row, unsubscribed feeds, folder rows; src: TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Models/RemovalWording.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

- Owner: each Library window's views.
  LibraryView observes only LibraryFeedFolders.shared, which knows which library folders hold feeds and which feeds the listener unsubscribed from (unsubscribedFeedIDs).
  It publishes only when a feed is subscribed, unsubscribed from, resubscribed, given another folder, or deleted, never for a download's progress or a refresh.
  The Feeds section (LibraryFeedsSection), a feed folder's rows (FeedFolderSections), and its summary bar (FeedFolderSummaryBar) observe FeedCenter themselves.
  So a download's start and end redraw them and nothing else of the list, and its bytes, which reach the feed downloads' progress alone ([Feed downloads' progress](feeds.md)), redraw none of them.
  Which feeds the section lists at a location is LibraryFeedsSectionRows.feeds(at:center:)'s rule:
  - every feed at the top of the library and in All Items,
  - in a folder the feeds whose folders are inside it,
  - in Unopened a feed only while it has a new item (FeedItemCounts.new above zero, which counts the items listed that FeedCenter.isNew calls new:
    - published, or, undated, first seen, after the subscription began,
    - never played, and never opened,
    - whether its file is here or its row was kept after its file went; FR11, question 8),
  - and none in Recently Opened or the Reading List.
  Which folders the Folders section shows, and what VoiceOver's Folders rotor offers, is LibraryFeedFolders.folderRows(_:at:bookCount:)'s rule, which Speak Info's selection reads too.
  A LibraryFolderRows, the folders shown and a FolderRotorEntry, a label and the ID of a row the list shows, for each folder directly inside the location.
  Outside the Folders category there are neither.
  A feed's folder whose feed the Feeds section lists there has no row, the feed's row standing for it, and its rotor entry names the feed as entering its folder does and carries the feed's ID, which is that row's.
  Any other folder keeps its row, which,
  - for a feed's folder, FeedFolderRow draws, observing the feed engine, as FolderRow(feedCounts:), counting the feed's items, never its downloads as books,
  - and which, for any other folder, names the feeds whose folders are below it beside its books (FolderRow's feedsBelow, from LibraryFeedFolders.feedCount(below:), FR11).
  In Folders the section lists every feed whose folder is inside the location, so no feed's folder keeps a row today.
  LibraryFeedsSection is generic over a folderMenu the window supplies, so a feed's row's context menu ends with its folder's Rename Folder… and Move Folder….
  A feed's own folder holding only its items offers no Delete Folder… (LibraryViewModel.offersDeleteFolder(_:)), since Delete Feed…, among the feed's own commands, deletes the feed and, when nothing else is in it, its folder, so a feed has one command that deletes it (FR14).
  One that also holds books or folders offers it, its question naming the feed as staying without a folder (feedTitles(of:) fills FolderRemovalWording.ownFeedTitles).
  Delete Folder… on a folder holding feeds' folders at any depth asks first (LibraryViewModel.folderHasContents(_:)), its two questions naming each feed and what becomes of it (FolderRemovalWording.feedTitles, from feedTitles(inside:)), and never deletes a feed.
  Move Contents Out moves the feed's folder with the rest, and Delete Everything leaves the feed, with its downloads, without a folder until Feed Info gives it another.
  LibraryFeedsPresenter, one for each window, kept in @State and never observed, runs the commands (FeedCommandRunner.swift) and holds:
  - the sheets (Add Feed, Feed Info, an item's description, and Import OPML),
  - the questions asked before a command that can't be undone,
  - and the notices that follow the commands, which LibraryFeedsWindowSupport shows on the window, applying its parts in turn, each type-checked on its own (body(content): withArrivalsAlert, withMenuCommands, withSheets, and withAlerts).

### Interface: who may write it
<!-- id: feed-interface-writers; keys: Subscribe, Unsubscribe, Resubscribe, Delete Feed, Mark All Played, OPML, Add Feed; src: TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Views/Feeds/OPMLImportSheet.swift, TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Models/Feed.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/Services/Feeds/FeedOPML.swift, TextMouth/Views/Feeds/FeedWording.swift -->

- Who may write it: the listener, through the rows' context menus and VoiceOver actions, under the same names: FeedAction, for a feed, on its row and on its folder's row, where it has one, and FeedItemAction, for an item, on its row or, beside the book's own commands, on its book's row.
  LibraryFeedsWindowSupport also takes the Library menu's:
  - Add Feed… (Shift-Command-F unless changed, ShortcutAction.addFeed, a menu command's key that works in Library windows),
  - Refresh All Feeds, Import OPML…, and Export OPML…,
  - which post addFeed, refreshAllFeeds, importOPML, and exportOPML, for the window that takes commands (WindowCommandRouting, through LibraryView's takesCommand(_:)).
  Subscribing makes the feed's folder only once the feed has been read.
  FeedCenter.subscribe(to:into:), with FeedFolderChoice.newFolder(inParentPath:), asks FeedLibraryHost.makeFeedFolder, which LibraryViewModel answers with createFolderReturningFolder, naming the folder after the feed and numbering it while the name is taken (FeedFolderNaming).
  The call subscribe(to:folderID:) remains for an existing folder.
  Mark All Played changes one record (FeedCenter.markAllPlayed(of:)).
  Unsubscribe asks first when it would delete what the feed kept for removed downloads (FR14).
  LibraryFeedsPresenter.requestUnsubscribe(_:in:) decides as it is chosen, from FeedCenter.keptRowsUnsubscribeDeletes(of:), the kept rows but those whose items wait in the download queue or download, unsubscribing at once when there are none and otherwise returning the question.
  FeedItemCounts.keptForRemovedDownloads gives the menus the same answer, titling the command "Unsubscribe…", destructive, or "Unsubscribe" (FeedAction.actions(for:counts:), FeedWording.unsubscribeTitle(asksFirst:)).
  And Feed Info's one button follows the feed's state, Unsubscribe, Unsubscribe…, or Resubscribe, its title, role, and hint from FeedSubscriptionToggle, so the button VoiceOver is on stays as the state changes (REV13 item 2).
  Unsubscribing stops checking and keeps the feed (FeedCenter.unsubscribe(_:deletingKeptOf:), FR11's branch D:
  - Feed.unsubscribedDate set;
  - the rule's downloads not yet under way withdrawn, FeedDownloadManager.withdrawRuleDownloads, while the one under way and the listener's go on;
  - and the packages kept for removed downloads deleted through FeedCenter.deleteKeptPackages(_:of:), in Services/Feeds/FeedLifecycle.swift, as Delete Episode deletes one, the Trash or for good as the removal setting says, a package whose item downloads again staying; FEED_UNSUBSCRIBED),
  - and returns a FeedUnsubscribeOutcome, which FeedWording.unsubscribed(title:outcome:keptParts:noun:) words,
  - naming the parts the kept packages held as keptRowsUnsubscribeDeletes(of:) gave them just before (FeedWording.KeptParts: place, bookmarks, own settings, transcript; REV13 item 5).
  Its question is FeedWording.unsubscribeMessage(downloadCount:keptCount:keptParts:noun:), counting and naming the rows keptRowsUnsubscribeDeletes(of:) gives as it is asked, and Feed Info stays open across it.
  FeedConfirmation.Kind.unsubscribe(feedID:keptItemIDs:) carries the items the question named.
  LibraryFeedsPresenter.unsubscribe(_:deletingKeptOf:in:afterAlert:) and FeedCenter.unsubscribe(_:deletingKeptOf:) delete only those, the rows decided by keptRowsUnsubscribeDeletes(of:among:) before withdrawRuleDownloads, through deleteKeptPackages(_:of:).
  Feed Info's onUnsubscribe passes the confirmed question to confirm(_:in:).
  What a confirmed command did is said once its alert has closed, VoiceOverAnnouncer.afterSheetDelay later.
  And at once when nothing was asked (LibraryFeedsPresenter's say(_:afterAlert:in:), through VoiceOverAnnouncer.afterSheetCloses(_:); REV13 item 1): Unsubscribe, Delete Episode, and Delete Feed….
  Delete Feed…, last among a feed's commands (FeedAction.actions(for:noun:isSubscribed:unsubscribeAsks:)) and in Feed Info, asks first (deleteFeedConfirmation(for:in:)).
  The question and message (FeedWording.deleteFeedQuestion(title:) and deleteFeedMessage(downloads:kept:keptParts:noun:folderPath:mode:)) name what goes, to the Trash or for good, the folder that goes when nothing else is in it, and Move to Library… for a download to keep.
  Delete Feed… then runs FeedCenter.deleteFeed(_:) ([Feed records](feeds.md)) through deleteFeed(_:in:), which first closes Feed Info should it show the feed.
  Its FeedDeleteOutcome is worded by FeedWording.deletedFeed(_:noun:keptParts:), with keptParts(ofFeed:in:) serving both the question and the announcement, and a FeedDeleteError by deleteFeedRefused(_:title:mode:) in an alert (the presenter's notice) alone.
  Both refuse(message:) and the OPML notices set notice only, as an alert speaks for itself.
  Resubscribe (FeedCenter.resubscribe(_:)) clears the date and checks the feed at once, as Check Feed does (FEED_RESUBSCRIBED, FeedWording.resubscribed(title:)); FeedAction.actions(for:in:) offers one or the other by the feed's state, and Check Feed only while subscribed.
  Add Feed with an unsubscribed feed's address is refused with FeedSubscribeError.unsubscribedAlready, which points to Resubscribe.
  Delete Episode's question (deleteItemMessage(isArticle:keepsListenerState:isInLibrary:)) says when the kept place goes too, or, for an item In Library, that its book stays (itemDeleted(title:isInLibrary:) says so again after).
  FeedOPML reads OPML with XMLParser, loading no external entity, reads a damaged file again through XMLDocument's tidying, and writes OPML 2.0.
  OPMLImportModel subscribes to each feed it lists in turn, as Add Feed does, and names apart those in the library already that the listener unsubscribed from, leaving them unsubscribed (FeedWording.importFoundUnsubscribed(_:)).
  Export OPML writes only the feeds subscribed to, saying how many it left out (FeedWording.exported(count:fileName:unsubscribedCount:), or nothingSubscribedToExport when none is left).

### Interface: how others observe it
<!-- id: feed-interface-observers; keys: FeedWording, row label, accessibility label, VoiceOver announcement, sort order, Feed Info sheet; src: TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Platform/macOS/Views/ReadOnlyTextArea.swift, TextMouth/Platform/macOS/Views/SilentKeyEquivalent.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedLibraryWording.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Views/Feeds/OPMLImportSheet.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Services/Feeds/FeedOPML.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/ContentView.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/FeedItem.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/FolderNavigationHistory.swift, TextMouth/Models/LeadingArticles.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Platform/iOS/Views/ReadOnlyTextArea+iOS.swift -->

- How others observe it: FeedWording words every row, sheet, command, and announcement, each label made by a function the hosted tests pin, since SwiftUI builds the spoken labels of its own text and buttons only for a connected assistive app.
  FeedWording.countsPhrase is the one count of a feed's items:
  - its size first (sizePhrase(listed:total:noun:), the items listed, FeedItemCounts.listed, of FeedItemCounts.total, with the word FeedWording.listedNote: "10 of 381 episodes listed", "10 of more than 2000 episodes listed", or, while every entry is listed or the size is unknown, "12 episodes"),
  - then the items downloaded, downloading, and new,
  - and last those not played (unplayedNote: "unread" for articles),
  - each count of 0 left out but the size.
  The Feeds rows, FeedCenter.folderSummary for the summary bar, entering the folder, Feed Info's items line, Speak Info (LibraryInfoWording adds nothing of its own), FolderRow(feedCounts:), and the Folders rotor all say it, and FeedWording.subscribed(title:counts:) says the size alone.
  A feed the listener unsubscribed from says so (FeedItemCounts.isSubscribed):
  - "unsubscribed" after Feed on its row, its folder's row, entering its folder, and the Folders rotor (FeedWording.unsubscribedNote, also an Unsubscribed badge on screen),
  - "Unsubscribed" in Speak Info,
  - and its last check as not checked since then (FeedWording.check(_:isRefreshing:isSubscribed:now:calendar:locale:), "Not checked since" and the date and time of the check).
  Feed Info adds the date it was unsubscribed (unsubscribedLabel) and offers Resubscribe in place of Unsubscribe.
  An item In Library says "In Library" (FeedItemState.visibleNote), and its row's hint is "Opens its book in your library" (itemRowHint(_:keptPlace:)).
  FeedWording.sectionTitle(_:count:total:) heads an open feed's items, "Episodes (10 of 381 listed)", given FeedFolderListing.total, which is nil while a search narrows them: "Episodes (2)".
  An item's row content (FeedItemRowContent) carries the item's kept row as FeedKeptProgress (from feedItemRows(of:).kept, by item identity):
  - its progress and time left in the book row's own words (BookRow.progressText, spokenProgress, remainingText, and timeRemaining(for:wpm:), which are nonisolated), so a kept item at its end says "Finished" alone, unless the item is played,
  - and its bookmark count (CountWording.bookmarks).
  Its itemRowLabel adds FeedItemState.reason, a failure's or a wait's, and the kept parts, and itemRowHint(_:keptPlace:) gives the hint.
  FeedFolderSections and FeedFolderListing.make take SettingsViewModel.wordsPerMinute, at which book rows estimate an article's time left.
  FeedItemAction.actions offers Download and Cancel Download for a waiting item.
  And the runner words a waiting item's cancel (waitingDownloadCancelled(title:)) and a kept package's Delete Download (downloadDeleted(title:kept:), naming only what the kept package holds, FeedWording.KeptParts.of(_:package:); feed review item 18).
  ReadOnlyTextArea (Platform/macOS/Views/ReadOnlyTextArea.swift) is the read-only NSTextView both sheets read descriptions in, labelled FeedWording.descriptionTextLabel(title:), with the feed's title in Feed Info, under a Description heading, and with the item's in Show Description.
  And SilentKeyEquivalent (Platform/macOS/Views/SilentKeyEquivalent.swift) is an NSViewRepresentable of no size and no accessibility element whose NSView takes one unmodified key in performKeyEquivalent, which AppKit offers to every view of a window before the focused view sees the key.
  Show Description's Close answers Escape through it while its one SwiftUI shortcut is Return (the default action): a SwiftUI button carries one shortcut, and onExitCommand, sent from an AppKit text view's responder chain, never reaches SwiftUI (measured in a hosted test).
  Any sheet with one button can use it, and the report of a speech refusal ([Speech refusal report](reader-playback.md)) uses both it and ReadOnlyTextArea.
  A feed's folder's row, where it has one, and its rotor entry say the note Feed and the feed's count (FolderRow.accessibilityLabel(name:bookCount:feedCounts:), which is FeedWording.folderAnnouncement(name:counts:)).
  As entering the folder announces it (FolderNavigationHistory.announcement(for:library:feedFolders:)).
  The Leading articles setting ([Titles as the lists read them](library-index.md)) reaches the feeds' rows too.
  LibraryFeedsSectionRows.rows(at:center:now:articles:) lists the section's feeds by title as the feeds are kept, or, while sorting passes over articles, by each title's filing key (LeadingArticles.sortKey(of:language:), localizedStandardCompare, ties keeping the feeds' order).
  And each FeedRowContent then carries shownTitle ("Digital Antiquarian, The") beside title, so rowTitle and label show and speak the shown title while commands and announcements keep naming the feed by title.
  A feed names no language, so English's articles count (language nil), and a feed's item shows its title the same way (FeedItemRowContent.shownTitle, from FeedFolderListing.make's articles parameter), in the feed's own order, newest first.
  And a search of a feed's folder finds an item by its title as written or as its row shows it (FeedFolderListing's matches(_:query:articles:)).
  The Folders rotor's entry for a feed whose row stands for its folder reads the title as the row shows it (LibraryFeedFolders.folderRows(_:at:articles:bookCount:)), and a plain folder's name stays as written.
  LibraryView's typed rows for letter navigation take the section's feeds in that order (LibraryTitleTyping, in [Letter navigation in the Library list](windows.md)).

## Searching the podcast directory
<!-- id: searching-podcast-directory; keys: iTunes Search, Apple podcast directory, FeedDirectory, Add Feed sheet, AddFeedModel, search results; src: TextMouth/Services/Feeds/FeedDirectory.swift, TextMouth/Services/Feeds/FeedJSON.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Services/Feeds/FeedDiscovery.swift, TextMouth/Services/Feeds/FeedNetwork.swift -->

Searching the podcast directory (FR03): the Add Feed sheet's search.

- Owner: AddFeedModel, one for each Add Feed sheet, on the main actor:
  - the words typed (searchTerm),
  - the podcasts the last search found (searchResults, each a FeedDirectoryResult: its title, publisher, episode count, and feed),
  - and what the sheet says when it found none (searchNote) or failed (searchFailure).
- Who may write it: search(), from the Search button or Return in the Search field, through FeedCenter.searchDirectory(for:) and the directory the engine's environment names (FeedEnvironment.directory: FeedDirectory.apple, Apple's iTunes Search API, or a test's stub server).
  FeedDirectory asks for podcasts alone, at most 50 (media=podcast, entity=podcast, limit=50), with the term percent-encoded beyond the unreserved characters, through the feed engine's connections, as a request the listener made, on any network.
  It reads the answer through FeedJSON (results(in:)), keeping each podcast that names a web feed once (FeedAddress.comparisonKey).
  A failure is a FeedSearchError, worded by FeedFetchError.searchMessage, as when the directory refuses more than about 20 searches a minute. subscribe(to:) puts a result's feed in the address field and subscribes as Subscribe does.
- How others observe it: AddFeedSheet lists the results, each read as one line beside a Subscribe button of its own, and VoiceOver hears how many were found, or why none were (FeedWording).

## New items arriving: alert and notifications
<!-- id: new-items-arriving-alert-notifications; keys: FeedArrivals, new episodes alert, UNUserNotificationCenter, notification, pendingAlert; src: TextMouth/Views/Feeds/FeedArrivals.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Services/Feeds/FeedRefresher.swift -->

New items arriving: the alert and the notifications (FR03).

- Owner: FeedArrivals.shared, on the main actor: the alert waiting to be shown (pendingAlert, a FeedArrivalAlert), and the Library window showing it (alertWindow).
- Who may write it: FeedArrivals itself, from FeedCenter.events.
  A refresh of every feed that TextMouth made by itself (FeedRefreshOrigin.isDiscretionary: at launch or on the interval) and that brought new items makes the alert, while feedRefreshAlert is on.
  It posts a notification for each feed through its FeedNotifying, while feedNotifications is on and notifications are allowed.
  A refresh the listener asked for is answered where it was asked, by VoiceOver (FeedWording.refreshedAll and FeedWording.checked).
  Turning notifications on asks permission the first time (FeedArrivals.settingTurnedOn).
  FeedArrivals also speaks FeedEvent.itemPolicyApplied(global:feedIDs:), which FeedCenter.itemPolicyChanged(for:) sends as its ten-second wait ends, after a change in Settings, Feed Info, or config.json.
  FeedWording.itemPolicyApplied(global:feedIDs:in:) gives the global setting's sentence when it changed, then one for each feed whose own changed within that wait that the library still holds, an unsubscribed one included.
  Since its rules still act (feed review item 20; FeedCenter keeps globalItemPolicyChanged apart from the feeds changed, so neither hides the other).
  Its announce is injectable, for the tests.
- How others observe it: the first Library window in front to ask takes the alert (claimAlert(by:isKeyWindow:)), so it shows once, and waits while no Library window is in front; dismissing it forgets it.
  SystemFeedNotifier posts through the system's notification center, whose delegate (FeedNotificationPresenter) shows banners while TextMouth is in front too; a process hosting tests uses InertFeedNotifier, which posts nothing and never asks.

## A podcast episode's transcript and chapters
<!-- id: podcast-episode-transcript-chapters; keys: podcast:transcript, podcast:chapters, FeedEpisodeExtras, SRT, VTT, JSON chapters, Podcasting 2.0; src: TextMouth/Services/Feeds/FeedEpisodeExtras.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/Feeds/FeedNetwork.swift, TextMouth/Models/TimedText.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/TranscriptInstallation.swift -->

A podcast episode's own transcript and chapters (FMT25; 0.4.2).

- Owner: FeedEpisodeExtras (Services/Feeds/FeedEpisodeExtras.swift) fetches, once an episode's audio has downloaded and for every feed, the files its item links as Podcasting 2.0's podcast:transcript and podcast:chapters (FeedItem.transcripts and FeedItem.chapters).
- Who may write it: the download.
  It tries at most three transcript links (maximumTranscriptTries), in the order WebVTT, JSON, SubRip, by the link's MIME type and then its address's extension; HTML and plain text are never fetched.
  Files are fetched under the download's own network rules (FeedNetwork.fetch): no cookie, redirects to http and https only, no link inside a file followed, and a body cap of 5 MB for a transcript and 1 MB for chapters (TimedTextLimits).
  The whole fetch stops after FeedNetwork.feedResourceTimeout, 2 minutes (timeLimit).
  FeedEpisodeImporter puts the chapters into the staged package as podcastChapters.json (TextMouthPaths.podcastChaptersFileName, titles cut to 200 characters), where they become the episode's headings when its audio has none.
  Then attach(_:to:) makes the transcript the episode's once its book is listed, with Origin podcast.
- A podcast's own transcript does not keep an aged-out download's package (2a398017).
  When an episode downloads again, TranscriptInstallation replaces an untouched podcast transcript (givingWayToAnUntouchedPodcastTranscript); a transcript recognition made, or that the listener edited or cleaned up, is kept.
  This is one commit that can be dropped on its own (fda87492, with 42daa613).
- How others observe it: the debug log has one line for a file left out, naming the episode, its feed, the server by its host alone, and why, never a word of the file.
  Nothing here can fail the episode's download.
- Not done: a switch for each feed, HTML and text transcripts, and the audio's checksum stamped in the kept chapters file, so that a later re-analysis can't reuse chapters a failed removal left.
  A quit during the fetch downloads the episode again at the next launch.
