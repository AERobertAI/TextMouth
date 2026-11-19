# Downloading feed episodes and articles
<!-- id: feeds-downloads-overview; keys: download, newest episodes, waiting, cancel, quit, auto download; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

Part of [TextMouth's documentation](../../README.md).

## Listing and downloading
<!-- id: feeds-listing-downloading; keys: List and download, newest-N rule, auto download, feedItems; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Models/FeedSettings.swift -->

### The List and download choices
<!-- id: feeds-list-download-choices; keys: feedItems, feedNewestCount, global setting, per feed, ten seconds, 1 to 2,000; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Models/FeedSettings.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift -->

Every feed follows one List and download choice, the one for every feed, set in the Feeds tab of Settings, or one of its own, set in its [Feed Info](feed-commands.md):
- Every item listed, newest 5 downloaded, the default;
- Every item listed, downloads by hand;
- or Only the newest 5 listed, where 5 stands for the number that goes with the choice, from 1 to 2,000, 5 unless you change it.

A feed's list follows a change of the choice or the number at once; what downloads, and what is removed, follows once neither has changed for ten seconds.

### Newest downloaded by default
<!-- id: feeds-newest-downloaded; keys: newest-N rule, automatic download, oldest downloads removed, played downloads, Cancel Download, serial show; src: TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedLifecycle.swift -->

Under the default, a feed's folder lists every episode and article the feed lists, and TextMouth keeps downloaded those of the newest 5 not yet played, newest by publication date, a serial show's too.
It downloads each of them by itself, at launch, after you subscribe, after each refresh, and once one of its own downloads finishes, an episode only on a network without data limits.
Played ones count among the newest 5, so playing one never downloads an older one, while deleting one with Delete Episode… brings the next older one in.
When TextMouth holds more than 5 of its own downloads of a feed, as once a newer episode has arrived, it deletes for good the files of its oldest downloads beyond the newest 5 until it holds 5.
It keeps, as Delete Download keeps them, the place, bookmarks, settings, and transcript of any you opened (see [Commands](feed-commands.md)).
This rule never removes a download you asked for, one made before the rule existed, one on the reading list, or one open in a reader, being transcribed, or being exported, or whose text is open in an editor with Edit Text, which it leaves for a later pass.
Nor does it remove, in a library in the cloud, one not wholly on this Mac.
A download that waits or fails removes nothing.
Opening or playing one of TextMouth's own downloads doesn't make it yours: it still goes once it falls beyond the newest 5, its place kept.
An item becomes yours when you ask for its download, even while TextMouth's own download of it waits or runs, when you choose Cancel Download or Delete Download on it (the Feed Downloads section's Cancel doesn't make it yours, below), or when a download you asked for fails.
From then on the rule never downloads it by itself, nor removes its download, though the rule that deletes played downloads still does (see [Commands](feed-commands.md)).
Nor does it download an item whose download was deleted before the rule existed.

### Downloads that wait
<!-- id: feeds-downloads-that-wait; keys: Low Data Mode, data limits, constrained network, offline, 1 GB free, no room, retry; src: TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Models/FeedDownloadProgressWording.swift -->

A download TextMouth makes by itself waits rather than failing.
An episode on a network with data limits waits for the next refresh TextMouth makes by itself on a network without them, as does an article that must fetch its page because its feed gives only a short summary.
And a download without room on this Mac for the size its feed gives, beside the 1 GB TextMouth keeps free, waits for a later pass that finds room.
While this Mac is offline, such a download waits in the same way, for the next refresh TextMouth makes by itself that reaches the network, rather than failing; its row's one reason covers both: "it downloads once this Mac is on a network without data limits".
A download refused on a network with data limits says the same, as in "“Ep.
368” downloads once this Mac is on a network without data limits."
A download you ask for yourself fails when there is no room, and one TextMouth made by itself that failed is tried again only after a later refresh of its feed that reaches the network.
A download TextMouth asked for by itself that hasn't started, waits, or failed is taken back, the item no longer downloaded, once the rule no longer wants it, as when the item is played or falls out of the newest.
Mark Played, Mark All Played, and the end of a refresh ask for the rule's pass at once, which runs as soon as any sweep or pass already under way has finished, so no row keeps a failure nobody asked for.
A download you asked for is never taken back.

### Downloads by hand and only the newest listed
<!-- id: feeds-downloads-by-hand; keys: manual downloads, newest listed only, hidden items, feed record; src: TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedReconciler.swift -->

Every item listed, downloads by hand, lists every episode and article the feed lists, and downloads nothing by itself.
Only the newest 5 listed lists the newest 5, less those you have played or read that aren't downloaded, and every item downloaded, downloading, or waiting to, wherever it falls, and downloads nothing by itself either.
Choosing either takes back the downloads TextMouth asked for and hadn't started, and removes none of those it made.
Under Only the newest 5 listed, the feed's record keeps only the newest of that number, beside every item downloaded or downloading, played, or whose place is kept.
So when you choose a longer list, the items it hid are listed again at once, and those it no longer holds come back at the feed's next refresh, which then reads the whole feed.

### Settings moved over from earlier versions
<!-- id: feeds-settings-moved-over; keys: feedKeepEntries, feedAutoDownload, upgrade, migration, Keep every entry; src: TextMouth/Models/FeedSettings.swift, TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

The first launch after an update moves the earlier settings over, once:
- Keep the newest 10 entries, as TextMouth shipped it, or Download new episodes and articles by themselves turned on, becomes the default;
- Keep every entry becomes Every item listed, downloads by hand;
- and any other number of entries becomes Only the newest of that number listed, at least 1.

A feed's own number of entries, from its Feed Info, becomes its own Only the newest of that number listed, 10 included, and a feed's own Keep every entry makes it follow the choice for every feed when that lists every item, and otherwise gives it Every item listed, downloads by hand.
So, in a library whose settings were as TextMouth shipped them, that launch downloads each feed's newest 5 not yet played or downloaded, its episodes on a network without data limits, and removes nothing.

## Downloads under way
<!-- id: feeds-downloads-under-way; keys: Feed Downloads section, progress, cancel, Speak Download Progress; src: TextMouth/Views/Feeds/FeedDownloadProgressSection.swift, TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/ViewModels/FeedDownloadProgress.swift -->

### The Feed Downloads section
<!-- id: feeds-downloads-section; keys: progress bar, Download 4 of 9, time left, waiting reason, every 5 seconds; src: TextMouth/Views/Feeds/FeedDownloadProgressSection.swift, TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/ViewModels/FeedDownloadProgress.swift -->

While episodes and articles download, each Library window shows a Feed Downloads section at its bottom, below the list, which it never covers.
It shows only while downloads run: its heading and a Cancel button, a bar for the whole run, how many of the run's downloads are done, as in "3 of 9 done", with "1 failed" when one did, and the download under way, with its feed and how far its file has come, as in "Download 4 of 9: “Ep.
368” from Finish It!, 40% of 63 MB", then "adding it to the library" while its book is added.
Once one has downloaded, it gives the time left, as in "About 4 minutes left", worked out by size where the feeds give sizes, and, for an article or an episode whose feed gives no size, by the time such downloads took, as the import overlay works out its own.
Downloads TextMouth asked for by itself that wait are counted apart, by their reason, as in "2 waiting until this Mac is on a network without data limits" or "1 waiting for room on this Mac".
How far a file has come, and the time left, are shown anew every 5 seconds.

### What VoiceOver reads for downloads
<!-- id: feeds-downloads-voiceover; keys: announcement, quarter of the run, run finished, section label, Cancel Feed Downloads; src: TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/ViewModels/FeedDownloadProgress.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadProgress.swift, TextMouth/Views/Feeds/FeedDownloadProgressSection.swift -->

VoiceOver reads every line as the section's label, as in "Feed Downloads: 3 of 9 done.
Download 4 of 9: “Ep.
368” from Finish It!, 40% of 63 MB.
About 4 minutes left.", and calls its Cancel button Cancel Feed Downloads.
For a run of 10 seconds or more, VoiceOver also hears, wherever you are, each quarter of the run's downloads, as in "Feed downloads: 3 of 12 done, about 4 minutes left."
And how the run ended, as in "Feed downloads finished: 8 downloaded, 1 failed.", or, for a run of one download, "Finished downloading “Ep.
368”."
A run TextMouth began by itself, which nobody heard start, is announced once, after ten seconds, with how many downloads are under way and the time left, as in "Feed downloads: 9 under way, about 4 minutes left.", unless a quarter has been heard or Cancel pressed by then.

### Cancelling feed downloads
<!-- id: feeds-cancel-downloads; keys: Cancel Feed Downloads, stop downloads, pause, partial files, Cancelling; src: TextMouth/Views/Feeds/FeedDownloadProgressSection.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/ViewModels/FeedDownloadProgress.swift, TextMouth/Models/FeedDownloadProgressWording.swift -->

Cancel stops every feed download, whether you or TextMouth asked for it: the one under way, those waiting to start, and those TextMouth asked for that wait for a network or for room; and it deletes what they had downloaded, partial files included.
A download whose book is already being added to the library finishes, as in "“Ep.
368” is already being added to the library."; meanwhile the section says "Cancelling..." in place of the time left, and its Cancel is dimmed, until the run ends or a download you ask for meanwhile begins, which gives Cancel back.
Cancel is a pause: for a feed whose List and download choice downloads by itself, TextMouth downloads its newest again by itself once a check of the feed that began after Cancel has ended, the regular check, Check Feed, or Refresh All Feeds, or the next time TextMouth opens.
Download on an item still downloads it at once, and Cancel Download on an item's row is still how you keep TextMouth from downloading that item by itself.
A moment after Cancel, VoiceOver's focus moves to the Library window's list, since the section goes once the run ends, and only then does VoiceOver say what Cancel did, as in "Stopped 6 feed downloads.
TextMouth downloads each feed's newest again at its next check, or the next time it opens."
VoiceOver says how what Cancel stopped comes back: that line when the feeds will download all of it by themselves; "To download it again, choose Download on its row."
(or "them", "their rows") when none would come back by itself, as an older episode you asked for, or a feed that downloads by hand or that you unsubscribed from; and for a mix, as in "TextMouth downloads 1 of them again at its feed's next check, or the next time it opens.
To download the other one again, choose Download on its row."
The button's hint begins "Stops every feed download, including those waiting, and deletes what they had downloaded." and then says the same of how they come back before you press it.

### Speak Download Progress
<!-- id: feeds-speak-download-progress; keys: Library menu, shortcut, Information shortcuts, status request; src: TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadProgress.swift, TextMouth/Models/FeedDownloadProgressWording.swift -->

Library menu, Speak Download Progress has VoiceOver speak the section's lines on request, or say "No feed download is under way.", followed by the downloads waiting, if any, as in "No feed download is under way.
2 waiting until this Mac is on a network without data limits."
Give it a key in the Shortcuts tab of Settings, under Information, to use it in every window but an audio editor's (see Works in, under the Shortcuts tab).

### A row that is downloading
<!-- id: feeds-row-downloading; keys: Downloading badge, percent read, episode row; src: TextMouth/Views/Feeds/FeedLibraryWording.swift, TextMouth/Views/Feeds/FeedRows.swift -->

An episode's or article's row says "Downloading" while its download waits to start or runs, without a percent, since the section says how far it has got; a place kept for it is read beside it as "42 percent read".

## Saving and quitting
<!-- id: feeds-saving-quitting; keys: quit, unsaved feed record, downloads at quit; src: TextMouth/App/QuitFinisher.swift, TextMouth/Services/Feeds/FeedDownloadManager+PartialDownloads.swift, TextMouth/Services/Feeds/FeedStore.swift -->

### Saving a feed's record
<!-- id: feeds-saving-record; keys: banner, Retry, Dismiss, unsaved change, library.json; src: TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

A feed's record that can't be saved is reported as any unsaved change is: the Library window's banner names the feed, with Retry and Dismiss, and quitting asks first.
If you press Retry while TextMouth is moving its data directory, rebuilding it, or moving books between folders, nothing is lost and nothing hangs: the row says when the changes will be saved, and TextMouth saves them itself once that ends.
The words are "TextMouth saves them once the move of its data directory ends.", "TextMouth saves them once it has finished rebuilding its data directory.", or "TextMouth saves them once it has finished moving books between folders."
While TextMouth is opening again on another library, the row says "TextMouth is opening again on another library, so they stay unsaved in this one."
When the save has ended, VoiceOver says "Feed subscriptions saved.", or "Retry did not succeed." if it failed again.

### Quitting while episodes download
<!-- id: feeds-quit-while-downloading; keys: Quitting TextMouth window, Command-Q, Quit Anyway, log out, shut down, resume data, three seconds; src: TextMouth/App/QuitFinisher.swift, TextMouth/Platform/macOS/Views/QuitNotice.swift, TextMouth/Services/Feeds/FeedDownloadManager+PartialDownloads.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

Quitting while episodes download, or wait to, keeps their place.
The one under way keeps what it has downloaded, when its server allows, and at the next launch they are asked for again, that one going on from where it stopped, while one TextMouth downloads by itself still waits for a network without data limits, and for room.
Quitting waits at most three seconds for this.
- You see and hear it (0.4.4).
  A small window titled "Quitting TextMouth" appears, and VoiceOver says: "TextMouth is finishing up before it quits: keeping the place of your feed downloads for next time.
  It quits when that is done."
  TextMouth then quits by itself.
- Pressing Command-Q again, or choosing Quit in the Dock again, in those seconds says the same words again and does not cut the downloads off.
- If you quit with changes that could not be saved and chose Quit Anyway, TextMouth finishes the downloads' place first and then quits, with no second alert.
- If a question stops the quit after the downloads have stopped (Cancel in an alert about unsaved changes, or an editor or a library move that began meanwhile), TextMouth stays open and the downloads stay stopped for the rest of that session.
  They are asked for again at the next launch.
- Logging out, restarting, or shutting down waits for the downloads, with the same words, and is not cancelled.
