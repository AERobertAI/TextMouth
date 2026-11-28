# Feeds on the iPhone: rows, the hub, and focus
<!-- id: phone-feeds; keys: FR53, F1, iPhone feeds, PhoneFeedsHub, PhoneFeedRows, PhoneFeedPresentations; src: TextMouth/Phone/PhoneFeedRows.swift, TextMouth/Platform/iOS/Services/PhoneFeedsHub.swift, TextMouth/Platform/iOS/App/PhoneFeedPresentations.swift -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).
The iPhone runs the Mac's feed engine ([Feeds](state/feeds.md)) and the Mac's models, commands, and words; FR53's phase F1 adds the iPhone's screens over them.
Phase F2 (background refresh and the Feeds settings), F3 (background downloads), and F4 (OPML, Feed Info's options) are planned in research/FR53-IPHONE-FEEDS-RECORDING-EDITING-2026-11-27.md.
What a person reads is in [Feeds on the iPhone](../user/feeds-on-iphone.md), and the tests in [Testing the iPhone app](../developer/testing-iphone.md).

## Rows, and what the phone offers
<!-- id: phone-feed-rows; keys: PhoneFeedRows, feedRow, itemRow, offers, FeedAction, FeedItemAction, Feeds section, PhoneLibraryOffer; src: TextMouth/Phone/PhoneFeedRows.swift, TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Phone/PhoneLibraryRows.swift, TextMouth/Phone/PhoneLibraryChoices.swift, TextMouth/Phone/PhoneRowValue.swift -->

`PhoneFeedRows` is plain code that compiles on both apps and chooses which of the Mac's commands the phone offers, putting the Mac's content in the Library's row value (`PhoneRowValue`).
- A feed's row (`feedRow`) has the Mac's label and title, its counts and last check as the detail, and the Mac's `FeedAction`s as `PhoneLibraryOffer.Command`s (`.feed(FeedCommand)`).
- An item that is not downloaded has a row of its own (`itemRow`, `.feedItem(FeedItemCommand)`); a downloaded one is a book row that offers the item's commands beside the book's own and in place of the book's removal, since Delete Download is that (`bookRowActions`).
- `offers(_:)` leaves out Show in Finder, which is the Mac's, and Move to Library…, whose sheet the phone does not have; Delete Feed's question therefore never sends a listener to it.
- `gather` collects what one Library screen holds of feeds: the Feeds section's rows, the folders (a feed's own folder is not also listed as a folder), and the feed counts a folder's row says.
  In a feed's folder it gathers the items, newest first, and the summary (`summary(of:books:wordsPerMinute:livePositions:)`).
- `feedAction` and `itemAction` build a command from the engine's record when it runs, not as the row was drawn, so a menu drawn before a download ended still acts on the item as it is, and nothing runs for a feed or item that has gone.
- `PhoneLibraryChoices.views` offers Feeds in the Library view sheet, and any view that lists feeds, once a feed exists.

## The hub and the presentations
<!-- id: phone-feeds-hub; keys: PhoneFeedsHub, PhoneFeedPresentations, FeedCommandRunner, Add Feed sheet, requestAddFeed, FeedCommandContext, presenter; src: TextMouth/Platform/iOS/Services/PhoneFeedsHub.swift, TextMouth/Platform/iOS/App/PhoneFeedPresentations.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneAddFeedSheet.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneFeedInfoSheet.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneFeedItemDescriptionSheet.swift, TextMouth/Platform/iOS/Views/Import/PhoneAddToLibrarySheet.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift -->

The Mac gives each Library window a `LibraryFeedsPresenter`; the phone has one window, so `PhoneFeedsHub.shared` holds one presenter for every Library screen stacked in it.
- The root shows the presenter's sheets and alerts (`PhoneFeedPresentations`, a modifier for each so the type checker takes the chain):
  - Add Feed, Feed Info, and an item's description;
  - the question asked before a command that can't be undone, and the notice after one.
  A Library row only hands its command to the hub, which runs it through the Mac's `FeedCommandRunner` with a `FeedCommandContext` that has no window.
- Add Feed… closes the Add to Library sheet first and opens its own once that has closed (`requestAddFeed(parentPath:)`, `showRequestedAddFeed(in:)`), since a sheet opened while another closes is refused.
  The feed's folder goes in the folder the Library showed when that can hold one, else at the top (`AddFeedPlaces.initialParent`).
- The presenter's announcements go to `PhoneAnnouncer`, queued after VoiceOver's own speech.
- Feed Info's Unsubscribe and Delete Feed… each ask in an alert of the sheet's own, and the runner says what was done once it has closed.

## Focus and announcements
<!-- id: phone-feeds-focus-announcements; keys: PhoneFeedFocusRequest, feedRowsChanged, PhoneFeedAnnouncements, opening, downloadFinished, downloadFailed, Back; src: TextMouth/Phone/PhoneFeedRows.swift, TextMouth/Phone/PhoneFeedAnnouncements.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouth/Platform/iOS/Services/PhoneFeedsHub.swift -->

- A command that takes its row away (Delete Download, Delete Episode…, Delete Feed…) records a `PhoneFeedFocusRequest` in `PhoneLibraryView`: the row, the row that takes its identity (Delete Download turns a downloaded item's book row into the item's own), and the rows as they were.
  `feedRowsChanged(to:)` acts once the row is gone, sending focus to the successor, else the row after it, else before it (`PhoneListFocus.fallback`).
  A row still there, because the command was cancelled or changed only its words, keeps focus.
- Opening a feed pushes its folder's screen, and Back returns focus to its row; a feed whose folder is gone says so (`FeedWording.folderMissing`).
- `PhoneFeedsHub.listen(to:)` hears the engine's events once, and `PhoneFeedAnnouncements.words(for:in:opening:)` says the end of a download the listener asked for, in the item row's words: "Downloaded" or "Download Failed" with the reason.
  The start is said by the command, so a download is spoken twice and no more.
  Nothing is said for a download the newest-N rule made, or for one Open asked for: `opening` holds those items, since the reader opening says their end.
- The Mac says neither, since a listener there sees the row change.

## The words that name this iPhone
<!-- id: phone-feeds-this-iphone; keys: ThisDevice, isPhone, this iPhone, this Mac, FeedDownloadProgressWording, Feed Downloads card; src: TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift, TextMouthProductionTests/PhoneFeedRowsTests.swift -->

A feed sentence that names the device says "this iPhone" on the iPhone and "this Mac" on the Mac, as `ThisDevice.isPhone` decides: a refresh, a search, or a download offline, a download waiting for a network without data limits or for room, and one with no room.
`FeedDownloadProgressWording.waits(_:isPhone:)` takes the flag so a test sets it; the Feed Downloads card at the top of the Library (`FeedDownloadProgressObserver`) is the Mac's section with its Cancel Feed Downloads.
Downloads use the engine's foreground session and stop when iOS suspends the app.

## The debug-only stand-in server
<!-- id: phone-feeds-stand-in-server; keys: PhoneUITestFeedStub, TEXTMOUTH_UI_FEED_EPISODE, feeds.textmouth.test, atlas.xml, stub protocol, FeedNetworkRefusal; src: TextMouth/Platform/iOS/Services/PhoneUITestFeedStub.swift, TextMouth/Phone/PhoneLaunchRequest.swift, TextMouth/Services/Feeds/FeedNetwork.swift, TextMouthiOSUITests/FeedUITests.swift -->

A UI test drives the app from another process, so the Mac's stub protocol (in the test target) cannot reach its sessions.
`PhoneUITestFeedStub` is a `URLProtocol` the app carries itself, compiled and installed (`FeedNetwork`) only in a debug build and only in a launch that asked for a sandbox (`PhoneLaunchRequest.sandboxVariable`); any other launch refuses every request (`FeedNetworkRefusal`).
- It answers `feeds.textmouth.test` alone: `https://feeds.textmouth.test/atlas.xml` is a small RSS feed, "The Tactile Atlas", with two episodes whose dates are fixed.
- `https://feeds.textmouth.test/audio/<name>.wav` serves the file the launch's `TEXTMOUTH_UI_FEED_EPISODE` names, whatever name is asked, a few kilobytes of silence the test wrote.
