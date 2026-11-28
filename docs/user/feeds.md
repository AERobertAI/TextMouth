# Podcasts and article feeds
<!-- id: feeds-overview; keys: podcast, RSS, Atom, JSON Feed, subscription, feed folder, episodes, articles; src: TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedStore.swift -->

Part of [TextMouth's documentation](../../README.md).

TextMouth subscribes to podcasts and article feeds, and lists each feed's episodes and articles in a library folder of its own.
It keeps their downloads in a folder of the feed's own in the data directory, with an index of their own, so the library's index lists books only ([What TextMouth reads](reads-transcripts-and-feeds.md) gives the formats, the refreshes, and the downloads).
A feed's commands, and an episode's, are in their rows' context menus and among the rows' actions in VoiceOver's Actions menu (VO-Command-Space), under the same names.

## The other feed pages
<!-- id: feeds-other-pages; keys: Commands, Listing and downloading, Downloads under way, Saving and quitting, Listening on to the next episode, Feeds tab of Settings; src: docs/user/feed-downloads.md, docs/user/feed-commands.md, docs/user/feed-listening-and-settings.md, docs/user/feeds-on-iphone.md -->

- Listing and downloading, Downloads under way, and Saving and quitting are in [Downloading feed episodes and articles](feed-downloads.md).
- Commands are in [Feed, episode, and article commands](feed-commands.md).
- Feeds on the iPhone are in [Feeds on the iPhone](feeds-on-iphone.md).
- Listening on to the next episode, The Feeds tab of Settings, and An episode's own transcript and chapters are in [Listening on, feed settings, and transcripts](feed-listening-and-settings.md).

## Subscribing
<!-- id: feeds-subscribing; keys: subscribe, add podcast, RSS, Atom; src: TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedWording.swift -->

### Adding a feed
<!-- id: feeds-add-feed; keys: Add Feed sheet, Shift-Command-F, feed URL, web page address, feed discovery, New Folder; src: TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Services/Feeds/FeedDiscovery.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedWording.swift -->

Library menu, Add Feed… (Shift-Command-F), or the Add Feed… button of the toolbar's Add to Library sheet (see [Adding books](adding-books.md)), opens the Add Feed sheet.
Type or paste the feed's address, or the address of a web page that names its feed, and choose where the feed's folder goes with the Move dialog's folder picker, whose New Folder makes one; it offers every folder but a feed's own, starting at the folder the window shows.
Return presses Subscribe, and Escape presses Cancel.
While the picker's New Folder fields are shown, Return presses their Create instead, and nothing until a name is typed; once they close, Return presses Subscribe again, as in the Move dialog.
Escape closes the New Folder fields first, and presses Cancel only once they are closed.
In the Search field, Return searches, and never makes a folder, even with the fields shown.

### Searching for a podcast
<!-- id: feeds-search-podcast; keys: Apple podcast directory, iTunes search, directory search, 50 results, rate limit; src: TextMouth/Services/Feeds/FeedDirectory.swift, TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Views/Feeds/FeedWording.swift -->

Below the address, Search for a podcast searches Apple's podcast directory for the words you type, from a podcast's title or its publisher's name, when you choose Search, or press Return, which in that field searches instead of subscribing; only those words go to Apple.
Up to 50 podcasts are listed, each with its publisher and number of episodes, which VoiceOver reads as one line, beside a Subscribe button of its own, which puts its feed's address in the address field and subscribes to it.
VoiceOver hears how many were found, as in "3 podcasts found for “braille”."; a search that finds nothing, or fails, as when the directory refuses more than about 20 searches a minute, says so in the sheet and to VoiceOver.

### After you choose Subscribe
<!-- id: feeds-after-subscribe; keys: damaged feed, UTF-7, too many attributes, entities, plain http, subscription failed; src: TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Views/Feeds/FeedWording.swift -->

TextMouth reads the feed first, then makes a folder named after it, numbered when the name is taken, so a failure leaves the library as it was: the failure stays in the sheet with its reason, which VoiceOver hears.
A page naming several feeds lists them, to choose one.
A feed, and an OPML file, that has a tag of more than 1,024 attributes, or is written in an encoding TextMouth can't read safely (UTF-7, say, or an ISO-2022 or EBCDIC one), fails with the reason that any damaged feed gives.
The reason reads, as in "The feed is damaged at line 1: it has a tag with too many attributes for TextMouth to read safely." or "The feed is damaged at line 1: it is written in the UTF-7 encoding, which TextMouth cannot read safely."
An OPML file fails with "That OPML file is damaged at line 1: " and the same reason.
The check is made before the feed is read, so a feed built to stall the reader costs nothing.
A feed that defines entities of its own, as some old feeds do, is still read.
A moment after the sheet closes, VoiceOver hears what came, as in "Subscribed to Planet Money: 381 episodes.", or, under Only the newest 10 listed, "Subscribed to Planet Money: 10 of 381 episodes listed."
(see Feeds in the library, below), or, for a feed that uses plain http, an alert warns once, saying the subscription was made.

### Importing and exporting OPML
<!-- id: feeds-opml; keys: OPML 2.0, import subscriptions, export subscriptions, feed reader export; src: TextMouth/Views/Feeds/OPMLImportSheet.swift, TextMouth/Services/Feeds/FeedOPML.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Views/Feeds/FeedWording.swift -->

Library menu, Import OPML… subscribes to each feed in another feed reader's export, each into a folder of its own inside the folder you pick, taking the first feed of a web page that names several, and then says which were subscribed already, which failed and why, and which use plain http.
A feed it lists that is in your library, unsubscribed, stays unsubscribed and is named, as in "Finish It! is in your library, unsubscribed.
Choose Resubscribe on its row, or in its Feed Info, to check it again."
Cancel stops it after the feed under way.
Return presses Import, and Escape presses Cancel; while the picker's New Folder fields are shown, Return presses their Create instead, and Escape closes them before it presses Cancel, and once the import has ended Return presses Done.
Export OPML… saves every feed you subscribe to as OPML 2.0, leaving out those you unsubscribed from and saying how many, as in "Exported 3 subscriptions to TextMouth Subscriptions.opml.
1 feed you unsubscribed from was left out.", or says there is none to export.

## Feeds in the library
<!-- id: feeds-in-the-library; keys: Feeds section, Feeds view, feed folder, library rows; src: TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift -->

### The Feeds section
<!-- id: feeds-section; keys: Unopened, feed row, Unsubscribed badge, Actions menu, row description, last check; src: TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedLibraryWording.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift -->

Where there are feeds, a Feeds section follows the folders:
- at the top of the library and in All Items it lists every feed, in a folder the feeds whose folders are inside it;
- and in Unopened a feed only while it has a new episode or article among those it lists, until its last new one is played, opened, marked played, deleted with Delete Episode… (Delete Article…), or no longer listed;
- Recently Opened and the Reading List list none.

Each row says, in one sentence, the feed's title, Feed, its episodes counted, and its last check, or why it failed, as in "Planet Money, Feed, 381 episodes, 5 downloaded, 1 downloading, 2 new, 370 unplayed, checked today at 3:05 PM".
Opening the row opens the feed's folder; when that folder is gone, VoiceOver says so and Feed Info opens, where you can choose another.
A feed you unsubscribed from says so after Feed, and since when it hasn't been checked, as in "Finish It!, Feed, unsubscribed, 10 of 381 episodes listed, 2 downloaded, not checked since", then the date and time of the last check.
Its row and its folder's row show an Unsubscribed badge, and entering its folder says "unsubscribed" after Feed too.

### The Feeds view
<!-- id: feeds-view; keys: View pop-up, When Applicable, custom view, Has New Episodes or Articles, New Items; src: TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Models/LibraryViewEditorWording.swift, TextMouth/Views/Feeds/FeedRows.swift -->

The Feeds view lists every feed, subscribed or not, each by title and each row as the Feeds section says it, and nothing else.
Choose it in the Library window's View pop-up (see [The Library window](library-window.md)).
As shipped it is offered When Applicable, so the pop-up offers it only while there is a feed, and it comes last in the pop-up.
Opening a feed's row there opens the feed's folder, in Folders.
The Library tab of Settings can move it, offer it always, or hide it.
A view of your own can list feeds too: one set to list Feeds with the condition New Items, "Has New Episodes or Articles", lists the feeds with a new episode or article, as Unopened lists them beside the books.

### How a feed's episodes are counted
<!-- id: feeds-episode-counts; keys: episode count, 10 of 381, unplayed, 2000 entries, Speak Info, Folders rotor, summary bar; src: TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedLibraryWording.swift, TextMouth/Models/FeedItemPolicy.swift -->

A feed's episodes are counted the same way wherever TextMouth counts them: on its row, on its folder's summary bar, entering its folder, in VoiceOver's Folders rotor, in Feed Info, and in Speak Info.
The count begins with how many of the feed's entries TextMouth lists, of how many the feed lists, as in "10 of 381 episodes listed": under the first two List and download choices, every entry you haven't deleted.
Under Only the newest 10 listed, the newest 10, less those played whose download isn't here, beside every one downloaded, downloading, or waiting to download, wherever it falls (see [Listing and downloading](feed-downloads.md)).
Then come the episodes downloaded, downloading, and new, and last those not yet played, each left out when it is 0; one waiting to download counts as neither downloaded nor downloading.
When TextMouth lists every entry the feed lists, the count is the number alone, as in "381 episodes"; a feed longer than the 2,000 entries TextMouth reads says "more than 2,000", as in "10 of more than 2,000 episodes listed"; and articles count "unread" rather than "unplayed".
The feed's size counts the episodes you deleted too, since the feed still lists them.
A feed whose record doesn't hold its size yet, as one subscribed in an earlier version, gives its size after its next check, which reads the whole feed once.

### A feed's folder and its episodes
<!-- id: feeds-folder-episodes; keys: episode rows, Episodes heading, Delete Folder, Rename Folder, Move Folder, Waiting to Download, Download Failed; src: TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Views/Feeds/FeedLibraryWording.swift, TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift -->

Each feed is listed once.
In Folders, a feed's folder has no row of its own, since the feed's row in the Feeds section stands for it: the row opens the folder, and its context menu ends with the folder's Rename Folder… and Move Folder….
A feed's folder holding only its items offers no Delete Folder…: Delete Feed… (see [Commands](feed-commands.md)) deletes the feed, and its folder when nothing else is in it, so a feed has one command that deletes it.
A feed's folder that also holds books or folders of your own does offer Delete Folder…; its first question ends
"It is the folder of the feed “Finish It!”.
Either way, the feed and its downloads stay, listed in no folder until Feed Info gives the feed another; Delete Feed… on its row deletes it.", and its second names the feed as staying without a folder.
Delete Folder… on a folder holding feeds' folders, at any depth, asks first and never deletes a feed: its first question ends, as in "It holds the folder of the feed “Planet Money”.
With Move Contents Out, the feed's folder moves with the rest.
With Move Everything to Trash, the feed and its downloads stay, listed in no folder until Feed Info gives the feed another; Delete Feed… on its row deletes it.", and its second, "The feed “Planet Money” stays, with its downloads, without a folder until Feed Info gives it another."
VoiceOver's Folders rotor still lists the feed, as in "Planet Money, Feed, 381 episodes, 5 downloaded", and moves to its row.
Entering the folder says its name, Feed, and its episodes counted.
It lists the episodes newest first, under a heading that counts them, as in "Episodes (12)", or "Episodes (10 of 381 listed)" when the feed lists more than TextMouth does, and "Episodes (2)" while a search narrows them:
A downloaded one as its book's row, and any other with, in this order:
- Played (Read for an article);
- its download's state, with why a download failed or waits, as in "Waiting to Download, it downloads once this Mac is on a network without data limits" or "Waiting to Download, it needs room for 61 MB on this Mac";
- for one whose download went after you opened it, the place kept for it as its book's row said it, as in "42 percent, 16 minutes remaining", or "Finished" alone for one kept at its end (none for a played one), and its bookmarks, as in "2 bookmarks";
- New;
- its date;
- and its duration.

The screen shows the same details, in shorter forms such as "42%" and "16:00 left", and a row that says a place has the hint "Downloads it again, then opens it where you left off".
The folder's other books follow, under Books.
The summary bar gives the feed's count and its last check, as its row does, beside the listening time left in the folder's books.

### When an episode is New
<!-- id: feeds-when-new; keys: New badge, unplayed, newly published; src: TextMouth/Models/FeedItem.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift -->

An episode is New when it was published after you subscribed, and has been neither played nor opened.

### Downloads kept from an earlier version
<!-- id: feeds-earlier-downloads; keys: upgrade, migration, downloaded episodes, Feeds folder, not downloaded; src: TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedIndex.swift -->

At the first launch of a version that keeps downloads in the feed's own folder, an episode or article downloaded earlier, which the library listed as a book in the feed's folder, moves into the feed's own folder in the data directory.
It keeps its place, bookmarks, settings, place in the reading list, and history in Stats.
A download of a feed whose record is gone, as one an earlier version unsubscribed you from, stays a book of the library, where it was.
An older version of TextMouth doesn't see the downloaded episodes and articles, which its library's index no longer holds, and marks them not downloaded.
A newer version marks them downloaded again at its next launch, each whose file is on this Mac, while one whose file is only in the cloud stays not downloaded until a launch finds its file here.
