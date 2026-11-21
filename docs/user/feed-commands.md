# Feed, episode, and article commands
<!-- id: feeds-commands-overview; keys: feed commands, episode commands, context menu, Actions menu; src: TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

Part of [TextMouth's documentation](../../README.md).

## Commands
<!-- id: feeds-commands; keys: context menu, VoiceOver Actions, VO-Command-Space, row commands; src: TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

### A feed's commands
<!-- id: feeds-feed-commands; keys: Check Feed, Unsubscribe, Resubscribe, Mark All Played, Command-I, Feed Settings button, orphaned feed folder; src: TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Views/Feeds/FeedWording.swift -->

For a feed, on its row:
- Check Feed, which says what came;
- Feed Info…, which Command-I opens too, as does the Feed Settings button in the Library window's toolbar, in the feed's folder (see [The Library window](library-window.md));
- Mark All Played (Mark All Read for articles);
- Unsubscribe, or, for a feed you unsubscribed from, Resubscribe in place of Check Feed and Unsubscribe;
- and, last, Delete Feed… (below).

When unsubscribing would delete what the feed kept of downloads you removed, the command is Unsubscribe…, with an ellipsis, and asks first, saying what happens, as in "TextMouth stops checking this feed for new episodes.
The feed stays in your library with its settings and its 2 downloaded episodes, and Resubscribe checks it again.
It also deletes the place and bookmarks kept for 1 removed download."; Unsubscribe without an ellipsis acts at once.
Unsubscribing only stops checking: the feed keeps its folder, its list, its settings, and its downloads, and VoiceOver says so, once any question has closed, as in "Unsubscribed from Finish It!: TextMouth no longer checks it for new episodes; its 2 downloaded episodes stay.
The place and bookmarks kept for 1 removed download were deleted.", or, for a feed with one download, "its downloaded episode stays".
What it kept of downloads you removed is deleted, to the Trash or for good as Removal Behavior in Storage settings says, except for an item downloading again.
And the downloads TextMouth had asked for by itself and not yet started are taken back, while the one under way, and any you asked for, go on.
Unsubscribe deletes only the kept places its question named; when it asks nothing it deletes nothing, and a kept place whose waiting download it takes back stays kept.
While you are unsubscribed, TextMouth never checks the feed; its rules still delete played downloads and those beyond its newest, but download nothing by themselves, and Download still works when you ask.
Resubscribe checks the feed again from then on, and at once, on any network, as in "Resubscribed to Finish It!.
Checking it now…", then says what came; under a List and download choice that downloads by itself, the newest items it lacks then download, on a network without data limits.
Add Feed… with an unsubscribed feed's address says "Finish It! is in your library, unsubscribed.
Choose Resubscribe on its row, or in its Feed Info, to check it again."
A launch that finds a feed's folder in the data directory with no record of the feed, as after a lost record or an Unsubscribe made by an earlier version, returns its downloads as books at the top of the library, without an announcement.
The books keep their place, playback times, bookmarks, settings, transcript, place on the reading list, and history in Stats.
The launch also deletes what the feed kept of removed downloads and then, once nothing else is in it, the feed's own folder.
It does so at once in a library outside the cloud, and in a library in the cloud only once this Mac has found the record missing at two of its own launches, since a feed you subscribe to on another Mac can reach this one before its record does.
Another Mac's launches don't count, a record only in the cloud counts as there, and a launch that finds it again starts the count over; meanwhile no folder lists those downloads.

### Delete Feed
<!-- id: feeds-delete-feed; keys: remove subscription, Trash, Removal Behavior, Storage settings, open in a reader, being transcribed; src: TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift, TextMouth/ViewModels/LibraryViewModel+DeleteFeed.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift -->

Delete Feed…, the last of a feed's commands on its row, among its VoiceOver actions, and in Feed Info, for a feed you subscribe to or one you unsubscribed from, is the one command that deletes a feed.
It asks first, as in "Delete the feed “Finish It!”?", saying what goes, to the Trash or for good as Removal Behavior in Storage settings says: "The feed leaves your library, with its list of episodes and its settings.
It deletes its 5 downloaded episodes and the place and bookmarks kept for 1 removed download: they go to the Trash, where you can recover them until the Trash is emptied.
Its folder “Podcasts/Finish It!” goes too when nothing else is in it.
To keep an episode, choose Move to Library… on its row first."
Once the question has closed, VoiceOver says what went, as in "Deleted the feed “Finish It!”, its 5 downloaded episodes, and the place and bookmarks kept for 1 removed download.
Its folder “Podcasts/Finish It!” is gone too.", or that the folder stays, as something else is in it.
A kept episode downloading again as the feed is deleted goes as Removal Behavior says, with its place, bookmarks, and transcript, and if Delete Feed… stops short, no episode stays Downloading or Waiting to Download.
The feed's downloads stop first, and what they had downloaded goes.
- then its downloads and what it kept of downloads you removed, which leave the reading list;
- then its own folder in the data directory;
- then its record, with its list and what you played, so subscribing to it again starts afresh;
- and last its library folder, when nothing else is in it, another feed's episodes included.

Stats keep their history, and an episode or article you moved into the library stays a book of yours.
While one of the feed's downloads is open in a reader, being transcribed, or being exported, Delete Feed… deletes nothing and says why in an alert, which VoiceOver reads; it is not announced besides, as in "“Ep.
368” is open in a reader.
Close it, then choose Delete Feed… again."; a download that can't be deleted keeps the feed, with whatever wasn't deleted, the alert naming each and why.

### An episode's or article's commands
<!-- id: feeds-episode-commands; keys: Open, Download, Mark Played, Show Description, Show in Finder, Delete Article, Edit Audio, Edit Text; src: TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Models/FeedBookUse.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedLifecycle.swift -->

For an episode or article:
- Open, which downloads it first;
  Return on the selected row does the same as VoiceOver-Space: an episode not downloaded downloads and then opens, a feed's or folder's row opens, and with nothing selected it says so;
  Command-Delete on an episode not downloaded no longer reaches the nearest book;
- Download, or Cancel Download while it downloads, and both for one waiting to download by itself,
  where Download downloads it at once, on any network, and Cancel Download leaves it to you, saying, as in "“Ep.
  368” no longer waits to download; it downloads when you choose Download.";
- Mark Played or Mark Unplayed (Mark Read or Mark Unread for an article);
- Show Description…;
- for a downloaded one, Show in Finder and Delete Download;
- and Delete Episode… (Delete Article…), which asks first, deletes everything kept for it, its download included, and keeps it out of the list for good.
  When TextMouth keeps anything of yours for the item, such as its place, the question adds "The place, bookmarks, and transcript kept for it are deleted too."
  And once the question has closed VoiceOver says, as in "Deleted “Ep.
  368”."

Delete Download, the library's Remove of episodes and articles, Delete Episode…, and Delete Feed… refuse a download that is open in a reader, being transcribed, or being exported, so no transcript or export under way is lost, and say why and what to do, as in "“Ep.
368” is being transcribed, and deleting its download now would lose the transcript.
Wait until the transcription ends, or cancel it, then try again."; TextMouth's own rules wait for such a download instead, and for an episode whose text is open in an editor with Edit Text, which your own deletions don't wait for.
A downloaded episode's book row offers these beside the book's own commands, less Move to Folder… and Edit Audio…, which an episode or article never offers while it belongs to its feed.
Edit Text in Default Editor and Edit Text With… are left out too: an article never offers them, and an episode offers them once it is transcribed (see [Transcribing an audiobook](transcribing.md)).

### Cancel Download while a book is being added
<!-- id: feeds-cancel-download-adding; keys: already being added, Stopped downloading, offline, cancelled download, restart; src: TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/ViewModels/FeedDownloadProgress.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Views/Feeds/FeedCommands.swift -->

Cancel Download chosen on an episode whose book is already being added to the library changes nothing, since the book arrives all the same, and VoiceOver says "“Ep.
368” is already being added to the library." instead of "Stopped downloading", the sentence the Feed Downloads section's Cancel says too; the episode stays as TextMouth's own rule asked for it, and is not made yours.
Download or Open chosen right after Cancel Download downloads the episode, and opens it for Open.
A download, or a check of a feed, that is cancelled just as it begins ends as cancelled, even while this Mac is offline.

### Deleted episodes stay deleted
<!-- id: feeds-deleted-episodes; keys: 90 days, deleted record, empty feed read, newest-episodes rule, check result; src: TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

An episode you deleted stays deleted when its feed lists less than it did.
TextMouth keeps the record of a deleted episode that the feed no longer lists for 90 days after you deleted it.
And when a read lists none of the feed's items, as a publisher's server sometimes sends, it keeps every deleted episode's record whatever its age, so none comes back as a new, unplayed episode that the newest-episodes rule downloads.
New episodes a check found are not lost when TextMouth quits, or the library can't be saved, before the check's result is written: the next check reads the feed whole again and adds them.

### Move to Library
<!-- id: feeds-move-to-library; keys: Move to Folder, In Library, folder picker, book of the library, Book menu, episode becomes a book; src: TextMouth/Views/Feeds/MoveToLibrarySheet.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedWording.swift -->

Move to Library…, on a downloaded episode's or article's book row, among its VoiceOver actions, and in its reader's Book menu, makes it a book of the library's own.
It has no key until you give it one in the Shortcuts tab of Settings, under Library, and then acts on the episodes and articles selected in a Library window, or on a reader's book.
It opens the folder picker Move to Folder… uses, under a heading such as "Move “Ep.
368” to Library" and the line "Moves this episode into a library folder as a book you can edit; it leaves the feed", which VoiceOver reads once, as text; the Move button gives no hint that says it again.
It takes only an episode or article still downloaded in its feed.
The book keeps its place, playback times, bookmarks, settings, transcript, place on the reading list, and history in Stats, where Books Finished still counts it as an episode, and VoiceOver says what happened a moment after the sheet has closed, as in "Moved “Ep.
368” into Podcasts/Keepers.
It's a book of your library now, and its feed lists it In Library."
A move that moves only some of the items keeps the sheet open and says both what moved and what stayed, and why, as in "Moved “Ep.
1” into Podcasts/Keepers.
It's a book of your library now, and its feed lists it In Library.
“Ep.
2” stays in its feed: The file couldn't be moved."
Book Info, Edit Text, and Move to Folder… then work on it as on any book.
The feed lists the item "In Library", as in "Ep.
368, In Library", the episode's date, and its duration, "1 hour, 4 minutes", and its row's hint is "Opens its book in your library":
- Open opens the book;
- it counts among the newest and is never downloaded again by itself;
- Mark Played, Show Description…, and Delete Episode… stay, Delete Episode… asking "The episode leaves the list for good; the book it became in your library stays.
  Checking the feed won't bring it back.";
- and once the book leaves the library, the item becomes not downloaded.

A book you move into the feed's own folder is listed there once, as its book's row, offering the episode's commands beside the book's.
A move cut short never loses the book: the next launch finds it in its feed or in the folder chosen.

### Delete Download keeps your place
<!-- id: feeds-delete-download; keys: Delete Downloads, Remove from Library, Confirm before removing a book, Command-Delete, kept place, package, Trash; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Models/RemovalWording.swift, TextMouth/Models/FeedBookUse.swift -->

Deleting a download keeps your place.
Delete Download removes the download's file, and an article's text, to the Trash or for good as Removal Behavior in Storage settings says, an article's file and its text going to the Trash together, as one item.
It deletes for good anything else made from the file, and keeps in the feed's own folder in the data directory the episode's or article's place, playback times, bookmarks, its own settings, any details you edited by hand, its transcript, and any copies Edit Text kept of an edited text.
A download you never opened, holding none of these, goes entirely, to the Trash or for good as that setting says.
VoiceOver then says what it kept, naming only what the download held, as in "Deleted the download of “Ep.
368”.
Its place and bookmarks are kept for when you download it again.", or, when nothing was kept, "Deleted the download of “Ep.
368”.
It can be downloaded again."
The rule that deletes played downloads, and the one that removes TextMouth's own downloads beyond a feed's newest (see [Listing and downloading](feed-downloads.md)), keep them the same way, though they delete the file for good.
And they keep an article's text as well, since it may hold an edit you made before feed items lost Edit Text, while an article holding nothing of yours goes entirely, its text included.
The item then shows as not downloaded, and leaves Recently Opened and the Reading List; after Delete Download, TextMouth never downloads it again by itself.
Downloading it again brings back the same book, opening where you left off, and its transcript shows its text again when the new file holds the same audio; a host that inserts different advertisements in each download makes it stale until you transcribe the episode again.
A save of the episode's text that no Edit Text session took, as one made in your editor after its download was deleted, is kept in the new download's package as content.md.edited- followed by the date and time.
Downloading an article again replaces the text kept for it with the new download's, keeping the earlier text in the article's package as content.md.edited- followed by the date and time when the two differ.
If TextMouth can't look inside the folder it kept for an episode or article, as when that folder is only in the cloud, as iCloud Drive leaves a package whose download was removed, or can't be read, downloading the item again fails.
Downloading it again keeps failing until the folder is on this Mac, which TextMouth doesn't download first.
Its row says Download Failed, then "Creating its package failed" and why, nothing is announced, and your place, bookmarks, and transcript stay as they were.
An episode's file is downloaded in full before this happens, and is then discarded.
TextMouth saves the feed's list of its downloads before any file goes, and when it can't, keeps the download, saying in an alert, which VoiceOver reads; it is not announced besides, "TextMouth couldn't save its list of this feed's downloads, so the download was kept.
Try again once the library can be saved."
A download that hasn't yet moved into its feed's own folder (see [Downloads kept from an earlier version](feeds.md)) isn't deleted this way, and says so.
An episode's or article's book row offers Delete Download among its own commands, and no Remove from Library….
For episodes and articles alone, the library's Remove is their Delete Download.
With several selected, the context menu offers Delete 3 Downloads…, and the edit bar's button reads Delete Downloads…, or Delete Download… for one, each without its ellipsis while Confirm before removing a book is off.
The Library menu's Remove reads the same, Delete Download… or Delete Downloads…, without its ellipsis while that setting is off, and does the same, as does Command-Delete.
With Confirm before removing a book on, it asks "Delete Download?", or "Delete 3 Downloads?" for several, as in "The download of “Ep.
368” will be deleted.
Its files go to the Trash, where you can recover them until the Trash is emptied.
Its place, bookmarks, and transcript, if it has any, are kept, and it can be downloaded again.", with Delete Download and Cancel and no Remove from Library Only.
And VoiceOver hears what it did a moment after the question has closed, naming only what each kept download holds, as in "Moved the download of “Ep.
368” to the Trash.
Its place and bookmarks are kept.", or "Deleted 3 downloads permanently.
The places and transcripts of 2 of them are kept."; with that setting off it deletes at once, and VoiceOver hears the same at once.
A selection holding books too asks as for any books, and its Remove from Library Only leaves the episodes and articles, saying "It belongs to its feed while it is downloaded.
Delete Download removes its file and keeps its place and bookmarks."
A feed's record keeps every item you played, and every item whose place it keeps, whatever its List and download choice lists.

### Feed Info
<!-- id: feeds-feed-info; keys: This Feed's Settings, feed address, publisher, Use the global setting, Description, Unsubscribe button; src: TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/Views/Feeds/FeedThresholdControl.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

Feed Info… shows the feed's address, web site, publisher, episodes, counted as its row counts them, last check, the date you subscribed, and the date you unsubscribed, while you are unsubscribed.
Its last check then reads "Not checked since …".
It also shows a plain-http warning when it applies.
Each of these is read as one line.
And its description, under a Description heading, in a text area labelled with the feed's title, as "Description of Planet Money", so VoiceOver says Description once.
It chooses the library folder that lists the feed's episodes and articles, its downloads included, all of them at once, since the downloads stay in the feed's own folder in the data directory; a feed whose library folder is gone downloads nothing until you choose another.
It holds This Feed's Settings:
- the feed's List and download choice and number, worded with its own items, as in "Every episode listed, newest 5 downloaded" and "5 episodes", under Use the global setting (Every item listed, newest 5 downloaded).
  That checkbox dims them while checked and, unchecked, gives the feed the global choice as its own to change;
- and how many days after playing its downloads are deleted, under its own Use the global setting;
- and, last, its four listening controls (see [Listening on to the next episode](feed-listening-and-settings.md)).

Below the settings is one button, Unsubscribe, or Unsubscribe… while it would ask first, or Resubscribe for a feed you unsubscribed from, whose name and hint follow the feed's state, so pressing it never takes away the button VoiceOver is on, and Feed Info stays open after either.
- then Delete Feed…, which closes Feed Info once you confirm it;
- and Done, which Escape presses.

Return stays with the number fields, entering the number typed, except while the folder picker's New Folder fields are shown, when it presses their Create, and Escape closes the fields before it presses Done.
Each change is saved as you make it.
The feed's list follows a change of its List and download choice at once.
And what downloads or is removed follows ten seconds after the last change, when VoiceOver says, as in "List and download for Finish It! is now in effect: Every episode listed, newest 3 downloaded."
Once the box is checked again, VoiceOver says "List and download for Finish It! now follows the global setting: Every item listed, newest 5 downloaded."

### Show Description
<!-- id: feeds-show-description; keys: episode text, show notes, text area; src: TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift -->

Show Description… shows an episode's text in a text area that VoiceOver reads by line, word, and character; Return or Escape closes it.

### Book Information of an episode
<!-- id: feeds-book-info-episode; keys: read-only Book Info, Show book information, Transcribe Audio, Edit Text With, album, genre; src: TextMouth/Views/Library/FeedItemBookInfoSheet.swift, TextMouth/Models/FeedBookUse.swift -->

While an episode or article belongs to its feed, its Book Info, from the Library (Command-I or Book Info) or from its reader, is read-only: under the heading Book Information and the line "An episode's details come from its feed; Move to Library… makes it a book you can edit."
(an article's says "An article's details"), it gives its title, artist or author, feed, an episode's album, genre, year, duration, and format, an article's format and word count, and when it was added and last opened.
Each is read as one line whose value can be selected and copied, and a detail without a value is left out.
The duration shows as a clock, as in "1:04:00", and is spoken in words, as in "1 hour, 4 minutes", and for an episode only in the cloud the sheet adds "Some details appear once the book is downloaded."
No field takes typing, and Done, Return, or Escape closes it.
VoiceOver calls its reader's Book Info button "Show book information", where for any other book it says "Edit book metadata".
An episode in its feed has the transcript commands of any audiobook:
- Transcribe Audio…, or Retranscribe Audio… once it has a transcript;
- Clean Up Transcript (Experimental)…, with Undo Cleanup in its sheet;
- Delete Transcript…;
- and Edit Text in Default Editor and Edit Text With…, since a transcript is your own work (see [Transcribing an audiobook](transcribing.md)).
