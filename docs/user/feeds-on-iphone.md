# Feeds on the iPhone
<!-- id: feeds-on-iphone; keys: iPhone, podcast, Add Feed, Feeds section, Feed Info, Show Description, Feed Downloads, episode rows; src: TextMouth/Phone/PhoneFeedRows.swift, TextMouth/Phone/PhoneFeedAnnouncements.swift, TextMouth/Platform/iOS/Services/PhoneFeedsHub.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneAddFeedSheet.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneFeedInfoSheet.swift; status: incomplete; issues: FR53 -->

Part of [TextMouth's documentation](../../README.md).
The iPhone subscribes to podcasts and article feeds, lists their episodes and articles in the Library, downloads them, and plays them in the reader.
It uses the Mac's feed engine and the Mac's words, so [Podcasts and article feeds](feeds.md) says what each row, count, and command means; this page says where they are on the iPhone.
If you sync (see [Syncing on the iPhone](syncing-on-iphone.md)), feeds you subscribe to on the Mac arrive too, and each device keeps its own downloads.

## Subscribing
<!-- id: iphone-feeds-subscribing; keys: Add to Library, Add Feed, address, search, folder; src: TextMouth/Platform/iOS/Views/Import/PhoneAddToLibrarySheet.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneAddFeedSheet.swift, TextMouth/Platform/iOS/Services/PhoneFeedsHub.swift -->

Choose Add to Library, then Add Feed….
The sheet closes and the Add Feed sheet opens, with focus on the address field.
Its order is its heading, Cancel, the address, Subscribe, the row naming the folder the feed's own folder goes in, and then the results of a search, each one element with its title and author.
It is the Mac's sheet, and the feed's folder goes in the folder the Library was showing when it can.

## Feeds in the Library
<!-- id: iphone-feeds-library; keys: Feeds section, Library view, feed folder, episode rows, Back, Delete Download; src: TextMouth/Phone/PhoneFeedRows.swift, TextMouth/Phone/PhoneLibraryChoices.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift -->

- A Feeds section lists each feed in one row, in the Mac's words: its title, Feed, its episodes counted, and its last check.
  The Library view sheet offers Feeds, and any view that lists feeds, once there is a feed.
- Opening a feed's row opens its folder, which lists its episodes or articles, newest first, under a summary line; Back returns focus to the feed's row.
- An episode's row says its state in the Mac's words ("Not downloaded", "Downloading, 40 percent", "Downloaded", "Played") and the place you stopped at.
  A double tap opens an episode in the reader, downloading it first when it isn't here; the reader opening says that download's end.
- Each row's commands are on VoiceOver's Actions rotor and in its context menu, under the Mac's names:
  - a feed's: Check Feed, Feed Info…, Mark All Played, Unsubscribe… or Resubscribe, and Delete Feed…;
  - an episode's: Open, Download, Cancel Download, Delete Download, Mark Played or Mark Unplayed, Show Description…, and Delete Episode….
  A downloaded episode's book row offers the same, beside the book's own.
- A command that takes its row away, Delete Download, Delete Episode…, or Delete Feed…, leaves focus on the row now in its place: the row that took its identity, else the next row, else the one before.
- Not on the iPhone yet: Move to Library… and Show in Finder, which is the Mac's.

## Feed Info and Show Description
<!-- id: iphone-feeds-info; keys: Feed Info, Show Description, description, Unsubscribe, Delete Feed, address, web site; src: TextMouth/Platform/iOS/Views/Feeds/PhoneFeedInfoSheet.swift, TextMouth/Platform/iOS/Views/Feeds/PhoneFeedItemDescriptionSheet.swift -->

- Feed Info… reads its title as a heading, Done, rows for the address, web site, author, items, last check, subscription date, and a warning for a plain-http address, then the description, then Unsubscribe or Resubscribe and Delete Feed….
  Each of those two asks first, as the Mac does, and says what it did once its alert has closed.
  The feed's own settings and its download folder are not here yet.
- Show Description… reads the episode's title as a heading, Close, a line of its feed, date, and duration, and its text, where VoiceOver's text navigation works, and then its web page.
  Focus starts on the text.

## Downloads
<!-- id: iphone-feeds-downloads; keys: Feed Downloads, Cancel Feed Downloads, background, suspended, data limits, room; src: TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouth/Phone/PhoneFeedAnnouncements.swift, TextMouth/Models/FeedDownloadProgressWording.swift -->

- Downloads run while TextMouth is open and stop when iOS suspends it; nothing is refreshed or downloaded in the background yet.
- A Feed Downloads card at the top of the Library says how many are done and which is under way, with Cancel Feed Downloads after it.
  A download that waits says why in the Mac's words, naming this iPhone: for a network without data limits, or for room.
- VoiceOver says "Downloading" as a download you asked for starts and its result as it ends, as in "A map you can touch, Downloaded" or "Download Failed" with the reason.
  A download the newest-episodes rule made by itself says nothing.

## What is not here yet
<!-- id: iphone-feeds-not-yet; keys: OPML, Feeds tab, feed settings, refresh in the background, Feed Info options; src: TextMouth/Phone/PhoneFeedRows.swift; status: incomplete; issues: FR53 -->

- Settings has no Feeds rows: the iPhone checks and lists by the standard choices, or by a feed's own choices synced from the Mac.
- Checking feeds and downloading in the background, importing and exporting subscriptions (OPML), a feed's own settings in Feed Info, and a folder's listening options come with later phases.
