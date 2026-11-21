# Listening on, feed settings, and transcripts
<!-- id: feeds-listening-settings-overview; keys: next episode, feed settings, podcast transcript, chapters; src: TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Services/Feeds/FeedEpisodeExtras.swift -->

Part of [TextMouth's documentation](../../README.md).

## Listening on to the next episode
<!-- id: feeds-listening-next; keys: continue to next book, play next episode, autoplay, queue; src: TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift -->

### The listening controls in Feed Info
<!-- id: feeds-listening-controls; keys: When an episode ends, Open the next episode in, ListeningOptions, per-feed options, folder settings sheet; src: TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

Feed Info's This Feed's Settings ends with four controls for how listening goes on from one of the feed's episodes to another.
Each is worded with what the feed's items are called, "episode" here, "article" or "item" for a feed whose items are those, and each is saved as you make it.
- The pop-up button "When an episode ends" offers "Use the global setting (…)", which names the Playback tab's When book ends choice, as in "Use the global setting (Stop)", then "Play the episode below", "Play the episode above", and "Stop".
  Its hint is "Chooses what happens when one of this feed's episodes ends".
- The pop-up button "Open the next episode in" offers "Use the global setting (…)", which names the Playback tab's Open the next book in choice, as in "Use the global setting (This Window)", then "This Window" and "A New Window".
  It says "article" or "item" in place of episode for a feed whose items are those, as in "Open the next article in".
  Its hint is "Chooses where this feed's next episode opens.", with "article" or "item" in place of "episode" for a feed whose items are those.
  It is dimmed while the feed's episodes do not go on to another episode when one ends, which is when the pop-up button above says Stop, or says Use the global setting and the global choice is not Continue to Next Book.
  Its hint then is "Available only while this feed's episodes go on to another episode when one ends", and it keeps its choice for when they do.
  A dimmed choice is not in effect: Next in Folder and Previous in Folder then follow the global setting.
  What the choice does is under Where the next book opens, in [Reader windows](reader-book-end.md).
- The checkbox "Skip finished episodes", checked unless you clear it, has the hint "Applies when listening goes on to another episode".
- The checkbox "Download the next episode before this one ends", checked unless you clear it, has the hint "When 10 minutes or less are left, downloads the next episode if it is not on this Mac yet".
  It is dimmed while the feed's episodes do not go on to another episode when one ends, which is when the pop-up button says Stop, or says Use the global setting and the global choice is not Continue to Next Book.
  Its hint then is "Available only while this feed's episodes go on to another episode when one ends", and it keeps its setting for when they do.

### The episode below and the episode above
<!-- id: feeds-episode-below-above; keys: order, newest first, Next in Folder, Previous in Folder, moved to library; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/ListeningOptionsWording.swift -->

The episode below is the next one down the feed's list as its folder shows it, newest first, so the next older episode, and the episode above is the next newer one.
An episode you moved into the library is passed over, since it is a book of your own library now.
Which of the book's own choice, the feed's, and the global setting decides what happens when an episode ends, and what VoiceOver says then, are under When a book ends, in [Reader windows](reader-book-end.md).

### Skip finished episodes
<!-- id: feeds-skip-finished; keys: finished, already played, rests at its end; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/ListeningOptionsWording.swift -->

Skip finished episodes passes over an episode that is downloaded and rests at its end, and over an episode that is not on this Mac but that you played, whose download has been deleted.

### When the next episode is not on this Mac
<!-- id: feeds-next-not-on-mac; keys: download next, queue first, network, stream; src: TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/Models/EndOfBookRule.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

When an episode ends and the one that follows it is not on this Mac, TextMouth downloads it, at once and on any network, as Download does, and goes on with it when it arrives.
That download goes first in the queue, ahead of the downloads waiting before it, though not ahead of the one under way.
This counts as a download you asked for (see [Listing and downloading](feed-downloads.md)).

### Downloading the next episode ahead of time
<!-- id: feeds-download-ahead; keys: predownload, 10 minutes left, time left, reading list; src: TextMouth/ViewModels/ReaderViewModel+Predownload.swift, TextMouth/Models/ListeningOptionsWording.swift -->

Download the next episode before this one ends asks for that download ahead of time, the first time 10 minutes or less of the episode are left while it plays in a window, as the reader's time left shows it.
It asks only when listening would go on to another episode, and that one is not on this Mac and not downloading already; a download TextMouth put off, for a network without data limits or for room, is asked for all the same, and the ask takes its place.
The reader says nothing when it asks, and the download shows like any other (see [Downloads under way](feed-downloads.md)).
A book read from the reading list never asks, since the reading list goes on to books that are on this Mac.

## The Feeds tab of Settings
<!-- id: feeds-settings-tab; keys: Settings window, feed settings, FeedSettings, config.json; src: TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Models/FeedSettings.swift -->

### Refreshing
<!-- id: feeds-settings-refreshing; keys: feedRefreshAtLaunch, refresh interval, feedRefreshIntervalHours, hours, Refresh All Feeds Now; src: TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Models/FeedSettings.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedThresholdControl.swift -->

Refreshing: Refresh every feed when TextMouth opens, on by default; Refresh feeds every 1 to 168 hours, 1 by default, or Only at launch and when I ask; and Refresh All Feeds Now, also in the Library menu as Refresh All Feeds, which says what came, as in "Refreshed 3 feeds: 2 new episodes."
Each checks only the feeds you subscribe to; with every feed unsubscribed from, Refresh All Feeds says "Every feed in your library is unsubscribed, so none was checked.
Choose Resubscribe on a feed's row, or in its Feed Info, to check it again."

### Episodes and Articles
<!-- id: feeds-settings-episodes-articles; keys: feedItems, feedNewestCount, feedDeleteDownloadsDaysAfterPlayed, number field, stepper, ten seconds; src: TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/Views/Feeds/FeedThresholdControl.swift, TextMouth/Models/FeedItemPolicy.swift, TextMouth/Models/FeedSettings.swift -->

Episodes and Articles: List and download, a pop-up menu, decides what every feed lists and what downloads by itself (see [Listing and downloading](feed-downloads.md)): Every item listed, newest 5 downloaded, the default; Every item listed, downloads by hand; or Only the newest 5 listed.
The first and third titles say the number in force.
And VoiceOver speaks the choice as the menu's value and the choice's own sentence as its hint.
The screen shows the hint under the number, as in "Lists every episode and article, keeps the newest 5 downloaded, and removes older downloads it made, keeping their place, bookmarks, and settings."
How many of the newest, a number field and a stepper, sets that number, from 1 to 2,000, 5 by default, a number typed outside moving to the nearer bound.
The stepper speaks it with its unit, as in "5 items", and both are dimmed under Every item listed, downloads by hand, which counts none and keeps the number for a choice that does.
A line under them, which VoiceOver reads, says "The list follows a change of List and download at once; what downloads or goes waits until the change has stayed for ten seconds, and VoiceOver announces it then."
A feed's list follows a change at once, and TextMouth downloads and removes by it once it has stayed unchanged for ten seconds, so typing 15 never passes through 1.
VoiceOver then says, as in "List and download is now in effect: Only the newest 3 listed.", after a change made in config.json too, and then says the same of each feed whose own choice you changed within those ten seconds.
Then Delete downloads after playing, from 0, at once, to 365 days, 1 by default, or Never delete played downloads.
A feed can have its own List and download choice and its own days, in its Feed Info.

### When new episodes arrive
<!-- id: feeds-settings-arrivals; keys: feedRefreshAlert, feedNotifications, notification permission, alert; src: TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Views/Feeds/FeedArrivals.swift, TextMouth/Models/FeedSettings.swift -->

When New Episodes Arrive: Show an alert when a refresh brings new episodes, and Post a notification for each feed with new episodes, both off by default.
They follow only the refreshes TextMouth makes by itself, at launch and on the interval; a refresh you ask for is answered by VoiceOver instead.
The alert names each feed and what came, in the Library window in front, and a notification shows even while TextMouth is in front. macOS asks permission for notifications the first time they are turned on, and while they are refused, the setting says how to allow them in System Settings.

## An episode's own transcript and chapters
<!-- id: feeds-podcast-transcripts; keys: podcast:transcript, podcast:chapters, Podcasting 2.0, ads, Book Information; src: TextMouth/Services/Feeds/FeedEpisodeExtras.swift, TextMouth/Parsers/PodcastTranscriptReader.swift, TextMouth/Parsers/PodcastChapters.swift, TextMouth/Models/FeedItem.swift -->

- From version 0.4.2, a podcast episode brings the transcript and chapters its feed links, once its audio has downloaded.
  This is on for every feed.
  There is no switch yet.
- Transcript: TextMouth tries up to three of the episode's transcript links, in this order of format: WebVTT, Podcasting 2.0 JSON, then SubRip.
  A link to an HTML page or to plain text is never fetched, since it holds no times.
- Chapters: a Podcasting 2.0 chapters file becomes the episode's headings when its audio has none of its own.
  A chapter's title is cut to 200 characters.
- The episode then has text and headings at once.
  Its Book Information says "The podcast's own transcript, downloaded with the episode on …" (see [Transcribing an audiobook](transcribing.md)).
- Limits: a transcript may be 5 MB and a chapters file 1 MB.
  No link inside a file is followed or opened.
  The whole fetch stops after 2 minutes.
- A file that can't be fetched or read is left out.
  The episode's download never fails because of it, and the debug log names the episode and why.
- Downloading an episode again: its own transcript gives way to the newly fetched one, because a host that inserts different ads into each download makes the kept one stale.
  A transcript you made by recognition, edited, or cleaned up is always kept.
- Not yet: HTML and plain-text transcripts are not fetched, and a quit during the fetch downloads the episode again at the next launch.
