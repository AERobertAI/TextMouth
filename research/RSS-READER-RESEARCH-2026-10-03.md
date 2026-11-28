# A podcast and article reader fed by RSS and Atom feeds

Research for the October 3 request, from the code on main (a0bad26), the feed specifications, Apple's documentation, and small probe programs run on this Mac (macOS 26.3.1) in the session's scratchpad, never in the repository. Nothing in the app or the library was changed. Bracketed numbers cite the sources at the end.

The request: "a way to include a basic Podcast / article reader into the app based off of an RSS Feed (all the episodes or articles or whatever go into a special folder of that type) with the same type of states as the Cloud books might have but controlled app side... A way to search for feeds could come later but for the first draft I just want a reader / listener."

## Summary

- **Feasible with Foundation alone.** URLSession fetches feeds and episodes, XMLParser reads well-formed feeds, and XMLDocument's tidy mode reads the broken ones. No package is needed, so the app stays small. FeedKit, the usual library, is about 15,500 lines and parses with the same XMLParser.
- **Recommendation: option B.** A feed is a folder. Each episode or article becomes an ordinary book in that folder once it is downloaded, so the reader, reading positions, bookmarks, the sleep timer, statistics, search, and the library in the cloud work unchanged. Items not yet downloaded are listed in the same folder from the feed's own record, with states TextMouth controls: Not Downloaded, Downloading 40%, Download Failed, Downloaded, and Played.
- **library.json keeps its format.** A new book format or sort field would make an older TextMouth fail to read the index, so feed data lives in a Feeds folder beside it. An older build sees a plain folder of audiobooks and HTML books.
- **The app's first network code.** TextMouth has never made a request. Plain http feeds and episodes need an App Transport Security exception, and feed addresses (a private feed's carries a token) must never reach the logs.
- **The first draft:** subscribe by address (a feed's, or a web page's that names one), refresh at launch and on demand, list items with their states, download one at a time, then play or read, mark played, and delete. OPML, scheduled refresh, rules for keeping and deleting downloads, search, transcripts, and chapters from feeds come later.
- **Measured here:**
  - XMLParser stopped at each common fault, and XMLDocument's tidy mode read every one.
  - With its default options, XMLDocument read a local file into a feed through an external entity.
  - AVFoundation read ID3 chapters from MP3 files, and called Ogg Opus, Ogg Vorbis, and MP4 video playable. Imports accept none of those three extensions today.
  - One of three real podcast feeds answered a conditional request with 304 Not Modified.

## 1. What TextMouth has today

### The library

- **Folders and books:**
  - library.json lists folders (BookFolder: an ID, a name, and its parent's path, at most 4 deep) and books (Book).
  - Each book is a .tmb package holding its file, bookInfo.json, contentIndex.json, and, for a text book, content.md.
  - LibraryViewModel holds the library on the main actor and makes every change to it. LibraryView shows a location's folders and books, and BookRow each book.
- **No publication date to sort by:** the sort fields (LibrarySortField) are Title, Author, Date Added, Last Opened, File Size, and Manual Order, saved per folder in library.json.
- **Strict decoding:**
  - A book's format (BookFormat) and a folder's sort field are decoded strictly (Book.init(from:), FolderSortSetting.init(from:)).
  - A case written by a newer build, such as a feed format or a Published sort, makes an older build's whole library.json unreadable, and that build enters index recovery.
- **One copy of any content:** Library.addBook silently skips a book whose md5Hash matches a listed book's, and imports ask the duplicate question first (addBookCheckingDuplicate).
- **Continue to Next Book** follows the folder's manual order (nextBookInFolder(after:), ManualBookOrder).
- **Finishing a book:** handleEndOfBook (ReaderViewModel+Playback.swift) calls ReadingStatsService.markBookFinished when a book stops or continues at its end, and the Stats tab counts Books Finished.
- **What VoiceOver hears in the list:**
  - A folder's row says "Fiction, 12 books" (FolderRow), and so does entering a folder (FolderNavigationHistory.announcement).
  - The Folders rotor says the same, but always with "books", so a folder of one book is "1 books" (LibraryView.swift, line 380, bypasses CountWording; posted to the board as finding #867).
  - The summary bar (TimeRemainingBar) speaks the number of books, the time remaining at the current speed, and the books not opened yet. In a library in the cloud, it adds the books in the cloud and those kept on this Mac.

### Cloud states: the nearest model

- **The states:**
  - BookCloudState (Models/CloudStorageContract.swift) is local, downloaded, inCloud, downloading with a BookDownloadProgress, downloadFailed with a reason, or waitingForSync.
  - Each state has a visible note ("Downloading 40%") and a spoken one ("Downloading, 40 percent").
- **Rows:** BookRow speaks the note after New or Now Reading. Beside a download percentage, the reading progress becomes "42 percent read".
- **Only in a cloud location:** BookCloudStates.shared shows notes only while libraryLocation.isCloud, so it can't carry feed states in a library on this Mac.
- **Commands:**
  - LibraryCloudCommand offers Download Now, Remove Download, Keep on This Mac, Stop Keeping on This Mac, and Show in Finder, from the context menu and as VoiceOver actions.
  - A selection's titles count its books ("Download 3 Books"), and downloads run one at a time.
- **Tied to sync services:**
  - BookCloudStorage is installed once for the whole app (CloudServices.bookStorage).
  - BookCloudError's sentences name the sync service ("…can't be downloaded from Dropbox").
  - PublishedFileProgress hears the progress a sync service publishes. URLSession reports its own.
- **The reader:** a book only in the cloud downloads in its reader window first (ReaderCloudPhase, ReaderCloudWording), with 25, 50, and 75 percent announced.

### Imports

- **The path:**
  - FileImportService.importFileWithReport stages an empty package (ImportStaging.makeEmpty), copies the file in, and calls publishReadableBook.
  - publishReadableBook reads the book as the reader will, writes and re-reads bookInfo.json, and publishes the package with one rename.
  - ImportScratchSpace stages in this Mac's Import Staging folder while the data directory is on the same volume as that folder: the startup disk, where iCloud Drive's and File Provider's folders are too.
- **Formats by extension:** BookFormat.detect(from:) goes by the file's extension. Audio means mp3, m4a, m4b, wav, aiff, aif, flac, alac, or aac.
- **Free space:** ArchiveBudget already reads volumeAvailableCapacityForImportantUsageKey before extracting an archive.

### Readers for what feeds carry

- **Audio:** AudioBookParser.parse(url:) makes a chapter for each chapter marker that AudioPlaybackService.extractChapters finds (AVAsset's chapter metadata groups), or one chapter for the whole file.
- **HTML:**
  - HTMLParser and HTMLToMarkdownConverter (through SwiftSoup) drop scripts and styles.
  - An image is read as its alt text and never fetched.
- **XML:** PackageSAXParser drives XMLParser for DOCX and DAISY files, with namespaces off and external entities off. It stops at the first error and words it plainly ("a closing tag does not match the element it closes").
- **Text encodings:** TextFileDecoder reads a file's declared encoding.

### Network, folders, and logs

- **No networking yet:**
  - TextMouth makes no network request. Nothing uses URLSession, Info.plist has no App Transport Security keys, and the app is unsandboxed (TextMouth.entitlements), so it needs no network entitlement.
  - The only network code is NetworkReachability, one NWPathMonitor.
- **What syncs:**
  - Everything under the data directory syncs when the directory is in a cloud folder, and a data-directory move copies the whole tree (DataDirectoryCopyPlan).
  - MachineLocalPaths are this Mac's own folders, never synced, including a Caches folder that macOS may empty.
- **Logs and tests:**
  - DiagnosticLog never writes book text, and LogContentPolicyTests pins every event tag.
  - UncheckedConcurrencyPolicyTests pins the counts of `@unchecked Sendable` (25) and `nonisolated(unsafe)` (13). A URLSession delegate class guarded by a lock would change the first count.

## 2. The feed formats

- **RSS 2.0** [1][2]:
  - A channel needs a title, a link, and a description. An item needs a title or a description, and everything else is optional.
  - An enclosure has a url, a length in bytes, and a MIME type. Publishers are told to give an item at most one [2].
  - Dates follow RFC 822, with two- or four-digit years.
  - ttl is the number of minutes the channel may be cached. skipHours and skipDays are hints.
  - A description may hold HTML, entity-encoded or in CDATA, and shouldn't use relative URLs [2]. content:encoded (http://purl.org/rss/1.0/modules/content/) holds the full content [2].
- **Atom** (RFC 4287) [4]:
  - Every feed and entry has an id, a title, and an updated date (RFC 3339).
  - An id "MUST NOT change" when the document moves, and entries sharing an id are the same entry.
  - Content and summary are text, html, or xhtml, or the content points elsewhere with src.
  - An enclosure is a link with rel="enclosure", whose length should be given and whose type is advisory.
- **Apple Podcasts** [5][6][7][8]:
  - The itunes namespace is http://www.itunes.com/dtds/podcast-1.0.dtd.
  - Each episode needs an enclosure, a guid that "never changes", and a pubDate.
  - A moved feed answers 301 and names its new address in itunes:new-feed-url, both for at least four weeks.
  - Episodic shows list the newest episode first, and serial shows the first episode first. Feeds say which in itunes:type: LibriVox said serial, NPR and Anchor episodic.
  - Apple reads chapters from MP4 headers, ID3 tags, and podcast:chapters.
- **Podcasting 2.0** (https://podcastindex.org/namespace/1.0) [9]:
  - podcast:transcript links a transcript (text/plain, text/html, text/vtt, application/json, or application/x-subrip).
  - podcast:chapters links a JSON chapters file, whose chapters give startTime in seconds.
  - podcast:alternateEnclosure offers other files of an episode (type, length, bitrate, and podcast:source addresses).
  - podcast:guid is the show's UUIDv5, made from the feed URL without its scheme or trailing slashes, and kept when the feed moves.
- **JSON Feed 1.1** [12] needs a version, a title, and items with an id and content_html or content_text. Attachments carry the episodes. It is optional, and Codable reads it.
- **What real feeds hold** (each fetched once into the scratchpad):
  - An Anchor podcast: 120 KB, 23 items, HTML in every description, and durations such as "00:20:03".
  - NPR's Planet Money: 2.2 MB, 355 items, content:encoded on every item, durations in seconds ("1780"), and the podcast namespace.
  - A LibriVox audiobook: 57 items with no guid and no pubDate, so identity must fall back to the enclosure URL.
  - WordPress News: RSS with content:encoded and no enclosures.
  - swift.org: Atom with full content in each entry. Its server sent gzip without being asked, which URLSession decodes.
- **Finding the feed on a web page:**
  - RSS autodiscovery puts `<link rel="alternate" type="application/rss+xml" href="…">` in the page's head, the first being the site's main feed [3]. HTML says the same of application/atom+xml, and that the first such link is the default [11].
  - WordPress News's page names three feeds (posts, comments, and a podcast), NPR's show page one, and swift.org's home page none.
  - SwiftSoup, which HTMLParser already links, can read the page's head. Walking its link elements directly, as HTMLToMarkdownConverter walks documents, avoids SwiftSoup's selector cache.
  - An Apple Podcasts link carries the show's ID, and the iTunes lookup API returns its feedUrl (tried once) [27].

## 3. Parsing

### What the probes found

- **Faults that stop XMLParser:**
  - With namespaces on and external entities off [21], it stopped at an HTML entity such as `&nbsp;` (error 26), a bare ampersand (23), a blank line before the XML declaration (64), a control character (9), a Latin-1 byte in a feed declared UTF-8 (9), and a truncated file (5).
  - Every event before the stop arrived.
- **Faults it handled:** a byte order mark, and feeds declared ISO-8859-1 or windows-1252. Under the old Netscape RSS 0.91 DOCTYPE, an undeclared `&nbsp;` was dropped silently.
- **Tidy mode:**
  - XMLDocument with documentTidyXML [22] read every one of those feeds.
  - It kept "Q&A", turned `&nbsp;` into U+00A0, replaced the bad byte with U+FFFD, and kept the truncated feed's complete item.
- **External entities:**
  - With default options, XMLDocument read /etc/hosts into an item's description through `<!ENTITY x SYSTEM "file:///etc/hosts">`. Apple documents that, for apps linked on macOS 10.7 or later, "all entities that don't require network access are loaded" [22].
  - With nodeLoadExternalEntitiesNever, nothing was read. XMLParser read nothing either way.
- **Speed and memory, on NPR's 2.2 MB feed:**
  - XMLParser took 14.5 ms.
  - XMLDocument took 22.9 ms plain and 101.3 ms tidied, and the probe's resident memory grew from 7.6 MB to 26 MB over the two parses.
- **Dates:**
  - A DateFormatter fixed to en_US_POSIX, as Apple's QA1480 advises [23], with "EEE, d MMM yyyy HH:mm:ss zzz", parsed GMT, UT, Z, EST, PDT, and +0200. It accepted a wrong day name.
  - It read the two-digit year "02" as the year 2, so a two-digit year needs "yy".
  - A date without its day name, its seconds, or its zone needs a pattern of its own.
  - ISO 8601 needs ISO8601DateFormatter, with fractional seconds as an option.
  - Localized names ("Mittwoch, 02 Okt") failed.
  - Date.HTTPFormatStyle exists only from macOS 26 [24], and the app supports macOS 14.

### Options

- **P1, the app's own parser on XMLParser, falling back to XMLDocument's tidy mode (recommended):**
  - Its handler matches elements by namespace URI and local name, so any prefix works. PackageSAXParser strips prefixes instead, which feeds can't rely on.
  - When the strict parse fails, the same handler runs over a tidied XMLDocument, walked as the same events, and a FEED_PARSE_REPAIRED line records it.
  - It covers RSS 2.0, Atom, the itunes and content namespaces, and the podcast namespace's transcript and chapters links.
  - An estimated 600 to 900 lines, adding nothing to the app's size worth measuring.
- **P2, FeedKit** (MIT) [28]:
  - For: it covers RSS, RDF, Atom, JSON Feed, the itunes and podcast namespaces, and Podlove chapters, for macOS 12 and later, with no further dependencies.
  - Against: about 12,800 lines, plus 2,700 in its XMLKit target. It parses with XMLParser too (XMLKit/XMLReader.swift on main), so broken feeds fail there as well. Its models would still need mapping onto items.
- **P3, XMLDocument alone, always tidied:**
  - For: the least code.
  - Against: it holds the whole tree, takes about 7 times as long as streaming (101 ms against 14.5 ms on NPR's feed), and its silent repairs hide the faults the log should record.

### Rules whatever the option

- **Off the main actor:** parsing runs off the main actor.
- **Caps:** a feed is capped at 25 MB and 2,000 items.
- **Entities:** external entities are never resolved, and XMLDocument always gets nodeLoadExternalEntitiesNever.
- **Identity:** an item's key is its guid (Atom's id), or else its enclosure URL, or else its link, or else a digest of its title and date.
- **Dates:** RFC 822 patterns are chosen by the year's digit count, with ISO 8601 as the fallback. An item whose date can't be read sorts by the date it was first seen.
- **Durations:** "HH:MM:SS", "MM:SS", or plain seconds.
- **HTML:** read through the existing HTML code, which never fetches an image.

## 4. Networking

- **Fetching a feed:**
  - A URLSession data task, off the main actor, with a 30-second request timeout and a User-Agent naming TextMouth and its version.
  - It sends the saved ETag in If-None-Match and the saved Last-Modified in If-Modified-Since. A server ignores the second when the first is present, and 304 means nothing changed [13].
  - Of three real feeds, Anchor answered 304, NPR sent an ETag but answered 200 anyway, and LibriVox sent no validators. So a digest of the body also decides whether anything changed, and a feed that answers with the same bytes is neither parsed again nor saved.
- **Moves and endings:**
  - After a 301 or 308, a client "can permanently replace references to the target URI" [13]. The task delegate hears the redirect [18], and the feed's saved address changes, as it does for itunes:new-feed-url [6].
  - A 410 means the feed is gone for good [13], so refreshing stops and says why.
- **App Transport Security:**
  - ATS requires https for URLSession in apps built against macOS 10.11 or later [14].
  - An http address could be tried as https first.
  - Feeds and episodes on hosts without https need NSAllowsArbitraryLoads, which also turns off ATS's extra TLS checks [14]. NSAllowsArbitraryLoadsForMedia covers only media AVFoundation loads itself, not URLSession [14].
- **When to refresh:**
  - At launch, once the library has loaded, and whenever the listener asks.
  - Every few hours while TextMouth runs, through NSBackgroundActivityScheduler, which picks "the most efficient time to execute based on energy usage, thermal conditions, and CPU use" and can be told to defer [19].
  - A feed's ttl, when longer, stretches its own interval. skipHours and skipDays are ignored at first.
  - Scheduled refreshes and automatic downloads set allowsConstrainedNetworkAccess and allowsExpensiveNetworkAccess to false and waitsForConnectivity to true, as Apple advises for discretionary work [17], and they skip while Low Power Mode is on [20]. What the listener asks for runs at once.
- **Offline:**
  - NetworkReachability answers first, so a refresh asked for while offline fails at once with the reason, and a scheduled one waits for its next turn.
  - waitsForConnectivity matters only while connecting. A connection that drops fails with NSURLErrorNetworkConnectionLost [17].
- **Downloads:**
  - A queue runs one URLSessionDownloadTask at a time, as Download Now does, and each waiting row says Downloading 0%.
  - Progress is bytes against Content-Length, from the delegate or the task's progress [16]. An enclosure's length attribute is often wrong, so it serves only as an estimate before the download starts.
  - The finished temporary file must be moved before the delegate returns, and the async download(for:delegate:) leaves the file for the app to delete [16].
  - A paused or failed download resumes from its resume data only for a GET of an unchanged resource whose server sends an ETag or Last-Modified and supports byte ranges, and while the system keeps the partial file [15]. Hosts that insert advertisements into each download may not qualify.
  - Before a download starts, its size is checked against the volume's available capacity for important use, by ArchiveBudget's rule.
- **Publishing a download:**
  - The file is moved into a package staged by ImportStaging.makeEmpty, and published by publishReadableBook with one rename.
  - The extension comes from the MIME type: mp3 for audio/mpeg; m4a for audio/mp4, audio/x-m4a, and audio/m4a; aac for audio/aac; m4b for audio/x-m4b.
  - The book takes the item's title, the show as author and album, and its feed's folder. The ID3 title is often only the show's name, so it doesn't win.
  - An article is published the same way, from an HTML file TextMouth writes: the title as a heading, then the author, the date, the content (content:encoded, Atom content, or the description), and the link. The existing HTML path then makes content.md.
- **Errors in words,** written like BookCloudError's but naming the host, never the full address:
  - Offline: "This Mac is offline, so Planet Money can't be refreshed. Connect to the internet and try again."
  - An unknown host: "The server feeds.example.com couldn't be found. Check the address."
  - A timeout: "feeds.example.com didn't answer for 30 seconds."
  - 404: "There's no feed at that address any more."
  - 401 or 403: "This feed needs a password, which TextMouth can't send yet."
  - 410: "The publisher has removed this feed."
  - A page without a feed: "That page doesn't name a feed."
  - Too little space: "There isn't room on this Mac for this episode (52 MB)."
  - A damaged feed, using PackageSAXParser's descriptions once they are shared: "The feed is damaged at line 4: a closing tag does not match the element it closes. TextMouth read the 12 items before it."
- **Privacy:**
  - A private feed's address carries a token, so logs name hosts only.
  - New event tags (FEED_REFRESH_…, FEED_DOWNLOAD_…) join LogContentPolicyTests.
  - Artwork and images are never fetched, which saves time and disk.

## 5. How feed items map onto the library

### Options

- **A. Every item is a book from the start, in a package that lacks its file until downloaded.**
  - For: one kind of row. Positions and bookmarks stay with the book through a removed download. It is the closest to the cloud model.
  - Against: a package without its file breaks what the code assumes of a book.
    - The startup repair hunts for the missing file, and the cache and statistics passes try to read it.
    - File Size can't sort it, and every stub needs an md5Hash of its own.
    - NPR's feed alone would add 355 packages, each uploaded in a library in the cloud, and an older TextMouth would list 355 broken books.
- **B. An item is listed from the feed's record and becomes a book once it is downloaded (recommended).**
  - For:
    - library.json and packages keep their meaning.
    - Downloaded episodes are ordinary books in All Items, Recent, Continue Listening, and search.
    - An older TextMouth sees a plain folder.
  - Against: a feed folder lists two kinds of rows, and a deleted download's position and bookmarks wait in the record until it is downloaded again.
- **C. A separate Feeds area outside the library.**
  - For: a free hand.
  - Against: it isn't what was asked. It repeats the list and its commands, and its episodes are missing from All Items, Recent, and search.

### The recommendation in detail: B

- **A feed is a folder:**
  - Subscribing creates a BookFolder named after the feed (through BookFolder.normalizedName, adding " 2" when the name is taken). The feed's record names the folder by ID.
  - The ID survives renames and moves: renameFolderThrowing and moveFolderThrowing keep it.
  - A folder edit moves the packages one by one (performLibraryTransition), so a record kept in the folder's own directory would be left behind.
  - A feed folder holds no subfolders.
- **Two records per feed, split by what may sync:**
  - **In the data directory, synced:** `Feeds/<feed ID>.json`.
    - It holds the subscription: its address, folder ID, title, and settings.
    - It holds each item the listener has acted on, by key: its book's ID, whether it is played or read, whether it was deleted, and a deleted download's position and bookmarks.
    - It is written only when that state changes and read through SavedFile, and its failed saves reach PersistenceFailureCenter. A data-directory move carries it, and Rebuild Directory never touches it.
  - **On this Mac, re-creatable:** a Feeds folder in MachineLocalPaths.caches holds each feed's latest parsed items, its ETag, Last-Modified, and body digest, when it was checked, and its last error.
    - Writing these into the synced file would upload every feed after every refresh.
    - When macOS empties Caches, the next refresh fetches each feed whole.
- **Item states:**
  - A FeedItemStates store on the main actor keeps them, as BookCloudStates keeps cloud states, with a begin and an end around each download.
  - Not Downloaded: the item has no book.
  - Downloading 40%: a BookDownloadProgress counted in bytes.
  - Download Failed: with its reason.
  - Downloaded: the item's book is in the library.
  - Played (Read, for an article) is a separate flag. handleEndOfBook sets it when the book ends, and so does Mark as Played.
  - New means published after the subscription began, and neither opened nor played, so subscribing doesn't mark 355 items new.
  - In a library in the cloud, a downloaded item's row shows its book's cloud note instead of Downloaded, so In Cloud means a downloaded episode whose files the sync service holds.
- **Commands:**
  - Download, and Cancel Download.
  - Delete Download, which deletes the book and keeps the item. It isn't called Remove Download, which in a library in the cloud keeps a book in the cloud.
  - Mark as Played and Mark as Unplayed, or for an article, Mark as Read and Mark as Unread.
  - Delete Episode or Delete Article: the item and its download go, and a refresh never brings the item back.
  - Episode Info, which shows the show notes as text.
  - Copy Link, and Show in Finder for a downloaded item.
  - Unsubscribe, in the feed folder's menu, which either deletes the downloads or keeps them as a plain folder.
- **A refresh merges by key:**
  - New items join, and changed titles and dates update.
  - An item the feed no longer lists stays while it has a book, a position, or a played flag, and otherwise goes.
  - A deleted key stays deleted.
  - A new guid with the enclosure URL of a listed item counts as that item, so a feed that renumbers its guids doesn't double every episode.
- **What must differ from an ordinary folder:**
  - **Order:** the folder lists items by publication date, newest first, or oldest first for a serial show [7], since library.json has no such sort.
  - **Continue to Next Book,** in a feed folder, plays the next downloaded and unplayed item in that order, not in manual order.
  - **Duplicates:** an episode's book skips the duplicate question and Library.addBook's md5Hash rule, since two shows can carry one file.
  - **Date Added** is the download's date. The publication date stays in the feed's records.
  - **Keeping and deleting:** a feed's limit on kept downloads, and its rule to delete a download once played, never delete a book open in a reader (LibraryViewModel.openBookIDs). They wait until its reader closes.
  - **Formats:** the enclosure is chosen by its type: the first one that AVURLAsset.audiovisualMIMETypes() lists [25] and an extension in BookFormat.audio can name.
  - **Chapters:** run here on probe files, the AVFoundation calls behind AudioBookParser found the chapters of an M4A file and of MP3 files with ID3 chapters. Chaptered episodes therefore get chapters, and the sleep timer's End of chapter, with no new code.
  - **Articles:** the full text comes from content:encoded or Atom content. A feed of summaries gives a book holding the summary and its link, until fetching the page is added.
  - **Images** are read as their alt text, as in every HTML book.
  - **Statistics:** finished episodes would count as Books Finished unless kept apart (question 8).

## 6. The interface, VoiceOver and keyboard first

- **Subscribe to Feed…** (Library menu):
  - The sheet has one field, "Feed or web page address", focused when it opens, with Subscribe on Return and Cancel on Escape.
  - An address in the feed, pcast, or itpc scheme, as some sites write subscribe links, becomes https. An Apple Podcasts link goes through the lookup API.
  - VoiceOver hears "Checking the address…" while it works.
  - A page with several feeds lists them by title as radio buttons, the first selected [3].
  - Success closes the sheet, opens the new folder, and announces "Subscribed to Planet Money: 355 episodes."
  - Failure keeps the sheet and its text, shows the reason, and announces it.
- **A feed folder's list:**
  - FeedFolderView, which LibraryView shows for a feed folder. Books that someone moved into the folder are listed after the items, as Other Books.
  - Each row is one element whose label puts first what matters most on a braille display:
    - "How the Fed sets rates, Not Downloaded, New, October 1, 2026, 28 minutes"
    - "How the Fed sets rates, Downloading, 40 percent, October 1, 2026, 28 minutes"
    - "How the Fed sets rates, Download Failed, the server says the file is gone, October 1, 2026"
    - "How the Fed sets rates, Downloaded, 42 percent, 16 minutes remaining, October 1, 2026"
    - "How the Fed sets rates, Played, Downloaded, October 1, 2026, 28 minutes"
    - "Shipping Swift 6.2, Article, New, October 2, 2026"
  - The visible note matches the spoken one, as BookCloudState's do, and one note type shared with the cloud rows words "Downloading 40%" once for both.
- **Keys and actions:**
  - Return opens a downloaded item, and downloads and then opens one that isn't downloaded. The reader's download view, with Cancel, can follow in Phase 2.
  - Command-Delete deletes, as the removal preferences say for books.
  - Every command is in the row's context menu and its VoiceOver actions (VO-Command-Space), and in the Library menu for the selection.
  - Edit Mode selects several items, and their commands count them ("Download 3 Episodes").
  - Refresh Feed takes Command-R, which no default uses. Refresh All Feeds and Mark as Played become ShortcutAction cases, and KeyboardShortcutManager gives a new default only when no action already uses that key.
- **The summary bar, the folder's row, and the Folders rotor:**
  - The summary bar is the first thing in the folder, as TimeRemainingBar is today: "355 episodes. 3 downloaded, 1 hour 10 minutes remaining in them at current speed. 1 downloading. 2 new. Checked today at 3:05 PM."
  - The check is given as a time of day, not "5 minutes ago", so nothing in the Library window redraws on a clock.
  - The folder's row, its Folders rotor entry, and the announcement on entering it all say "Planet Money, podcast, 355 episodes, 2 new", ending with "last refresh failed" when it did. The rotor would move to CountWording, which fixes its "1 books".
- **Announcements:**
  - A refresh the listener asked for says "Planet Money: 2 new episodes", "Planet Money: no new episodes", or the failure. Refresh All Feeds gives one summary, naming the feeds that failed.
  - A download announces its start and its end, or its failure with the reason.
  - A scheduled refresh says nothing. A notification banner for new episodes (UNUserNotificationCenter) is optional (question 9).
- **OPML:**
  - Import Subscriptions… reads OPML 2.0 outlines whose type is rss, each with an xmlUrl [10]. It subscribes to each address not already followed and ends with one summary.
  - Export Subscriptions… writes each feed's type, text, title, xmlUrl, and htmlUrl.
  - Categories become parent folders on import. OPML allows them, but warns that not every reader keeps them [10].

## 7. Later

- **Search:**
  - Apple's iTunes Search API takes media=podcast and a term, and returns up to 200 results, each with its feedUrl. It needs no key and allows about 20 calls a minute [27].
  - A search sheet would list each show's title, author, and episode count, with Subscribe on Return.
  - Podcast Index refused a request without an application-specific User-Agent, and then one without its Authorization header (tried twice), so it needs an API key.
- **Transcripts:**
  - A podcast:transcript file (VTT or SRT) could become a text book aligned to the episode's audio.
  - TRANSCRIPTION-RESEARCH-2026-10-03.md, a separate research task, covers making transcripts on this Mac.
- **Chapters from feeds:** Podcasting 2.0 JSON chapters [9] and Podlove Simple Chapters, laid over an episode whose file has none.
- **Whole articles:** fetching a summary-only item's web page, and keeping its main or article element.
- **Private feeds:** a user name and password kept in the Keychain.
- **More formats:** JSON Feed, video podcasts, and Ogg audio, once tried on macOS 14 and 15 (question 10).
- **A feed as one audiobook:** a LibriVox feed lists a book's chapters as its items, so Import as One Audiobook could make a single book, with a chapter for each item.

## 8. Testing

- **No test reaches the network:** a URLProtocol subclass, given to the session through URLSessionConfiguration.protocolClasses, serves fixture files, and fails any request no fixture answers.
- **Fixtures are real feeds saved as files,** trimmed to a few items, keeping every tag, attribute, and fault:
  - The LibriVox feed as it is, since LibriVox says its recordings and the summaries in its catalog are public domain [29].
  - The others with their text replaced: Anchor's "00:20:03" durations, NPR's durations in seconds and podcast namespace, WordPress's content:encoded, and swift.org's Atom.
  - Each fault the probes found, from `&nbsp;` to a truncated file.
- **Audio:** AudioTestFixtures' silent and chaptered AAC files are served as enclosures. No episode is ever played aloud.
- **Hosted tests:** row labels and actions, the summary bar, and the subscribe sheet's focus, Return, and Escape.
- **By hand:**
  - A dozen real feeds, read with VoiceOver and a braille display throughout.
  - Offline, and slow with Network Link Conditioner.
  - An http feed, NPR's large feed, and a library in iCloud Drive.

## 9. Phases

- **Phase 1, the first draft (about 2 weeks):**
  - FeedParser, FeedStore with both records, and FeedFetcher with conditional requests.
  - The download queue and publishing.
  - Subscribe, and FeedFolderView with its states and commands.
  - Refresh at launch and on demand.
  - Played at the end, Delete, and Delete Download.
  - The decision about App Transport Security.
  - Its tests:
    - Parsing: RSS and Atom, namespaces under other prefixes, each fault through the tidy fallback, the entity rule, dates, durations, and the identity fallbacks.
    - Merging: items added, kept, and dropped, deleted keys, and changed guids.
    - Fetching: 304, an unchanged body, 301 and 308, 410, the size cap, offline, and an http address.
    - Downloads and publishing: progress, Cancel, too little space, MIME types to extensions, and the book's title, author, and folder.
    - Played at the end, Delete, Delete Download, and every sentence and spoken label.
- **Phase 2 (about 1.5 weeks):**
  - Scheduled refresh, and OPML.
  - Feed settings: how many downloads to keep, whether to delete after playing, and whether to download new episodes by themselves.
  - Resumed downloads, and opening an episode that isn't downloaded in the reader.
  - Next-episode order, the summary bar's and rotor's wording, and the optional banner.
  - Its tests: the schedule with an injected clock and a feed's ttl, OPML out and back in (nested outlines, addresses already followed), the keeping and deleting rules (never a book open in a reader), resume data, and next-episode order.
- **Phase 3:** search, transcripts, chapters from feeds, whole articles, private feeds, and more formats, each tested from saved files: search results as JSON, transcripts, chapter files, and a summary-only article's page.

## 10. Risks

- **Every episode syncs in a library in the cloud:**
  - Downloads become packages in the data directory, so each one uploads and reaches every Mac. An hour at 64 kilobits a second is about 29 MB.
  - ubiquitousItemIsExcludedFromSync (macOS 11.3) [26] could keep a package off iCloud Drive. It is untested on Google Drive and Dropbox.
- **A full disk:** the space check, a limit on kept downloads, and deleting after playing bound it, and a large download's size is shown and spoken first.
- **Feeds that change or reuse guids:** the enclosure-URL match, and the keys kept for deleted items, limit doubled and returning episodes.
- **Broken or hostile feeds:** the tidy fallback, no external entities, the size and item caps, redirects only to http or https, and nothing in HTML ever runs.
- **App Transport Security:** an exception widens what the whole app may load, and without one some feeds can't be read at all.
- **The main thread:** a 2.2 MB feed parses in milliseconds, but tidying takes 100 ms and about 10 MB, so both stay off the main actor.
- **Older builds and two Macs:**
  - No new enum case reaches library.json.
  - Two Macs changing one feed's record at once can leave a conflict copy of it, which SavedFile's rules leave alone. One Mac at a time stays the policy.
- **Advertisements inserted per download:** each download can differ, which defeats resuming and duplicate checks.

## Open questions for you

1. Where should a new feed's folder go: at the top of the library, inside one Podcasts folder (and one Articles folder), or in the folder you are viewing?
2. In a library in the cloud, should downloaded episodes sync to your other Macs, or should each Mac keep its own downloads?
3. When an episode is played to the end, should its download be kept, deleted at once, or deleted after a day?
4. How many downloaded episodes should each feed keep by default: all of them, or only the latest few?
5. Should new episodes download by themselves, or only when you choose Download?
6. How often should TextMouth check your feeds while it runs: every hour, every few hours, or only at launch and when you ask?
7. Should TextMouth open feeds and episodes at plain http addresses? That means turning off the app's https-only rule (App Transport Security) for everything it loads.
8. Should finished episodes and articles count as Books Finished in Stats, count separately, or not count at all?
9. Would you like a notification banner when new episodes arrive, or only what TextMouth says when you open the folder or refresh?
10. Should video podcasts play as audio only, so you can listen to them like any other episode?

## What I could not verify

- **Older systems:** whether macOS 14 and 15 read ID3 chapters, and play Ogg Opus, Ogg Vorbis, and an MP4 video's audio, as macOS 26.3.1 does here.
- **VoiceOver and braille:** how they present the proposed rows, which exist only on paper.
- **Banners:** whether TextMouth, signed ad hoc, can post notifications.
- **Other drives:** whether ubiquitousItemIsExcludedFromSync keeps files off Google Drive and Dropbox.
- **Resuming:** resume data from hosts that insert advertisements into each download.
- **Podcast Index:** its API, which needs a key.

## Sources

1. RSS 2.0 Specification, version 2.0.11 (RSS Advisory Board, March 30, 2009): https://www.rssboard.org/rss-specification
2. RSS Best Practices Profile: https://www.rssboard.org/rss-profile
3. RSS Autodiscovery: https://www.rssboard.org/rss-autodiscovery
4. RFC 4287, The Atom Syndication Format: https://www.rfc-editor.org/rfc/rfc4287
5. Apple Podcasts for Creators, Podcast RSS feed requirements: https://podcasters.apple.com/support/823-podcast-requirements
6. Apple Podcasts for Creators, Change the RSS feed URL: https://podcasters.apple.com/support/837-change-the-rss-feed-url
7. Apple Podcasts for Creators, Set up serial and episodic shows: https://podcasters.apple.com/support/3143-how-to-set-the-order-of-podcast-episodes
8. Apple Podcasts for Creators, Chapters on Apple Podcasts: https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
9. The Podcast Namespace (Podcast Index): https://github.com/Podcastindex-org/podcast-namespace, with docs/1.0.md, docs/tags/transcript.md, docs/tags/chapters.md, docs/tags/alternate-enclosure.md, docs/tags/guid.md, and docs/examples/chapters/jsonChapters.md
10. OPML 2.0 specification: http://2005.opml.org/spec2.html
11. HTML Living Standard, link type "alternate": https://html.spec.whatwg.org/multipage/links.html#rel-alternate
12. JSON Feed version 1.1: https://www.jsonfeed.org/version/1.1/
13. RFC 9110, HTTP Semantics, sections 13.1.2, 13.1.3, 15.4.2, 15.4.5, 15.4.9, and 15.5.11: https://www.rfc-editor.org/rfc/rfc9110
14. NSAppTransportSecurity, NSAllowsArbitraryLoads, and NSAllowsArbitraryLoadsForMedia: https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity
15. Pausing and resuming downloads, and cancel(byProducingResumeData:): https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads and https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/cancel(byproducingresumedata:)
16. urlSession(_:downloadTask:didFinishDownloadingTo:), download(for:delegate:), URLSessionTask.progress, and WWDC21, Use async/await with URLSession: https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didfinishdownloadingto:) , https://developer.apple.com/documentation/foundation/urlsession/download(for:delegate:) , https://developer.apple.com/documentation/foundation/urlsessiontask/progress , and https://developer.apple.com/videos/play/wwdc2021/10095/
17. URLSessionConfiguration: waitsForConnectivity, allowsConstrainedNetworkAccess, and allowsExpensiveNetworkAccess: https://developer.apple.com/documentation/foundation/urlsessionconfiguration
18. urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:): https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)
19. NSBackgroundActivityScheduler: https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler
20. ProcessInfo.isLowPowerModeEnabled: https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled
21. XMLParser, shouldProcessNamespaces and shouldResolveExternalEntities: https://developer.apple.com/documentation/foundation/xmlparser
22. XMLDocument, init(data:options:), and XMLNode.Options documentTidyXML and nodeLoadExternalEntitiesNever: https://developer.apple.com/documentation/foundation/xmldocument , https://developer.apple.com/documentation/foundation/xmlnode/options/documenttidyxml , and https://developer.apple.com/documentation/foundation/xmlnode/options/nodeloadexternalentitiesnever
23. Technical Q&A QA1480, NSDateFormatter and Internet Dates: https://developer.apple.com/library/archive/qa/qa1480/_index.html
24. ISO8601DateFormatter and Date.HTTPFormatStyle: https://developer.apple.com/documentation/foundation/iso8601dateformatter and https://developer.apple.com/documentation/foundation/date/httpformatstyle
25. AVURLAsset.audiovisualMIMETypes(): https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualmimetypes()
26. URLResourceValues.ubiquitousItemIsExcludedFromSync: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemisexcludedfromsync
27. iTunes Search API: https://performance-partners.apple.com/search-api
28. FeedKit, its Package.swift and README on main, with lines counted from the main branch's source archive: https://github.com/nmdias/FeedKit
29. LibriVox, Public Domain: https://librivox.org/pages/public-domain/
