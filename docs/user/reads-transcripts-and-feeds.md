# What TextMouth reads: transcripts, feeds, and packages
<!-- id: reads-transcripts-feeds; keys: transcription, feeds, RSS, packages, .tmb; src: TextMouth/Services/TranscriptionService.swift, TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/FileImportService+Packages.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

## Transcripts of audiobooks, on macOS 26 and later
<!-- id: transcripts-audiobooks-macos-26-later; keys: SpeechAnalyzer, speech recognizer, macOS 26, transcript, Where Am I; src: TextMouth/Services/TranscriptionService.swift, TextMouth/Services/TranscriptionEngine.swift, TextMouth/Services/TranscriptionAvailability.swift -->

### Transcribing an audiobook
<!-- id: reads-transcribing-audiobook; keys: Transcribe Audio, SpeechAnalyzer, sentence, Edit Text, Where Am I?; src: TextMouth/Services/TranscriptionService.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/ReaderViewModel+Transcript.swift -->

- Transcribe Audio… transcribes an audiobook with the Mac's own speech recognizer (SpeechAnalyzer), which asks no permission and sends nothing anywhere: the book's audio never leaves this Mac (see [Transcribing an audiobook](transcribing.md)).
- The transcript becomes the book's text: the reader shows it around the sentence being narrated, following the narration as the book plays, while positions and bookmarks go on counting time.
- Where Am I? ends with the sentence being heard, the one the text is shown around, quoting up to 40 words of it.
- Edit Text opens that text in your own editor (see [Editing a book's text](editing-book-text.md)).

### The language of a transcript
<!-- id: language-transcript; keys: transcriptionLocale, locale, speech model, download, en-GB; src: TextMouth/Models/TranscriptionLanguage.swift, TextMouth/Services/TranscriptionModelInstaller.swift -->

- Transcripts are in English unless you choose another language in Settings, under Playback, Transcription, or with transcriptionLocale in config.json (see [Editing settings in config.json](config-json.md)).
- The English is as this Mac's region writes it when the Mac is set to English, such as en-GB in the United Kingdom, and otherwise US English.
- Each language needs its speech model, which macOS downloads from Apple only when you ask for it in the Transcribe Audio sheet, and keeps for other apps too.

### Cleaning up a transcript
<!-- id: cleaning-up-transcript; keys: TranscriptCleanup, rules file, replacement rules, experimental, undo cleanup; src: TextMouth/Services/TranscriptCleanup.swift, TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/Models/TranscriptCleanupWording.swift -->

- Clean Up Transcript (Experimental)… corrects, by rules you write, words the recognizer always writes another way, such as a name in a series of books.
- The last cleanup can be undone (see [Transcribing an audiobook](transcribing.md)).
- TextMouth comes with no rules of its own: measured on 38,834 words read aloud, no correction was right in every book.
- research/TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md says which words the recognizer gets wrong, and what a cleanup can fix.

### macOS 14 and 15
<!-- id: transcription-macos-14-15; keys: TranscriptionAvailability, unavailable, macOS 26 required; src: TextMouth/Services/TranscriptionAvailability.swift -->

- TextMouth itself still runs on macOS 14 and 15, which can't transcribe: there Transcribe Audio… only says that transcription needs macOS 26 or later.

## Podcasts and article feeds
<!-- id: podcasts-article-feeds; keys: RSS, Atom, JSON Feed, iTunes namespace, podcast namespace, OPML; src: TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/Feeds/JSONFeedParser.swift -->

- TextMouth reads podcasts and article feeds in RSS 2.0, RSS 1.0, Atom, or JSON Feed (1.0 and 1.1), with Apple's podcast elements and Podcasting 2.0's.

### Subscribing to a feed
<!-- id: subscribing-feed; keys: feed:, pcast:, itpc:, discovery, podcast directory, search; src: TextMouth/Services/Feeds/FeedDiscovery.swift, TextMouth/Services/Feeds/FeedDirectory.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Views/Feeds/AddFeedSheet.swift -->

- TextMouth can subscribe to a feed by its address, by a feed:, pcast:, or itpc: link, by a web page that names its feed, or by searching Apple's podcast directory, and lists the feed's episodes and articles in a library folder of its own, named after it (see [Podcasts and article feeds](feeds.md)).
- An episode downloads as an audiobook, a video episode as an audiobook that plays its sound, and an article as an HTML book.
- An article is read from its web page when the feed gives only a short summary that links one, though an article TextMouth downloads by itself reads its page only on a network without data limits, and otherwise holds the feed's own text.
- Each download is kept in the feed's own folder in the data directory, apart from the library's books (see Feeds, under [Where TextMouth keeps your library](data-directory-files.md)).

### Refreshing feeds
<!-- id: refreshing-feeds; keys: Low Power Mode, Low Data Mode, newest 5, Waiting to Download, Resubscribe, Books Finished; src: TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedNetwork.swift, TextMouth/Models/FeedItemPolicy.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Views/Feeds/FeedLibraryWording.swift -->

- Feeds refresh when TextMouth opens and every hour while it runs, unless the Feeds tab of Settings says otherwise, skipping an hour in Low Power Mode.
- A feed you unsubscribed from is never refreshed, at launch, every hour, or by Refresh All Feeds, until you choose Resubscribe (see Commands, under [Podcasts and article feeds](feed-commands.md)).
- Each feed's List and download choice decides which of its episodes and articles are listed and which download by themselves.
  Unless you choose otherwise, every one the feed lists is listed, and those of the newest 5 not yet played are kept downloaded (see Listing and downloading, under [Podcasts and article feeds](feed-downloads.md)).
- Those refreshes, and the episodes TextMouth downloads by itself, never use a network with data limits, such as Low Data Mode or a phone's hotspot.
  Such an episode waits, its row saying "Waiting to Download, it downloads once this Mac is on a network without data limits", and is asked for again after the next refresh TextMouth makes by itself on a network without them.
- A finished episode or article counts among Books Finished.
- Its download's file is deleted for good a day after it finished, or as the Feeds tab of Settings says, unless it is open in a reader, being transcribed, or being exported, when it goes at a later pass.
- Its place and bookmarks are kept should you download it again (see Commands, under [Podcasts and article feeds](feed-commands.md)).

### What reaches the network
<!-- id: what-reaches-network; keys: ephemeral session, cookies, cache, http, speech model download; src: TextMouth/Services/Feeds/FeedNetwork.swift -->

- The feeds, and a search of Apple's podcast directory, are the only things TextMouth itself reaches the network for, and its connections keep no cookies and cache nothing on disk.
- A feed or episode at a plain http address loads too, since many still use one.
- A transcription language's speech model is downloaded by macOS, and only when you ask for it (see [Transcribing an audiobook](transcribing.md)).

## TextMouth packages
<!-- id: textmouth-packages; keys: .tmb, package, another library, TextMouth package; src: TextMouth/Services/FileImportService+Packages.swift -->

- TextMouth reads TextMouth packages (.tmb folders) from another TextMouth library.
- A package keeps its reading position, bookmarks, and per-book settings.
