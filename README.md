# TextMouth

TextMouth is a native macOS application that reads books aloud with the Mac's text-to-speech voices and plays audiobooks.
It is designed for people who read with VoiceOver and a braille display, and its rule is that every control has a spoken label, every value on screen has a spoken equivalent, and every action can be done from the keyboard.

This file is the index of TextMouth's documentation, whose pages are in the docs folder: a page for each part of the app, for the person using it; how to build and test TextMouth; and the notes coding agents work from.
ARCHITECTURE.md, in the same folder, is the index of the pages explaining how the code is organized and which part of the app owns each kind of data.

## For people using TextMouth

### What changed, and what TextMouth reads

- [Changelog](docs/user/changelog.md): every version, newest first, and what changed.
- [What TextMouth reads](docs/user/what-textmouth-reads.md): the formats it imports and plays.
  - [Formats list](docs/user/formats-list.md): each format, and how well it is tested.
  - [Kindle books](docs/user/reads-kindle-books.md): MOBI, KF8, KFX, PalmDOC, and Kindle Create.
  - [DAISY and braille books](docs/user/reads-daisy-and-braille.md): DAISY, XML, BRF, BRL, PEF, and BARD braille.
  - [Text, HTML, and PDF files](docs/user/reads-text-files.md): encodings, web archives, and SSML.
  - [Pages, tables, and limits](docs/user/reads-pages-and-limits.md): page numbering, and the 64 MB limit.
  - [Audiobooks](docs/user/reads-audiobooks.md): audio formats, conversion, playlists, and ZIPs of tracks.
  - [Transcripts, feeds, and packages](docs/user/reads-transcripts-and-feeds.md): transcribing, subscribing, and TextMouth packages.
- [The audiobook manifest](docs/user/audiobook-manifest.md): manifest.json, and Edit Manifest.

### Adding books and the Library window

- [Adding books](docs/user/adding-books.md): Open Book, Finder, ZIP archives, Import Folder…, New from Text.
  - [Import progress and errors](docs/user/import-progress-and-errors.md): the import overlay, and every refusal's sentence.
  - [Duplicate books and Replace Existing](docs/user/duplicate-books.md): the duplicate question, and Replace Existing.
- [The Library window](docs/user/library-window.md): views, folders, sorting, searching, and commands on books.
  - [Book Information](docs/user/book-information.md): edited details, Text Encoding, and braille pop-ups.
  - [Letter keys and Speak Info](docs/user/library-typing-and-speak-info.md): typing a title, leading articles, summaries.
- [Search Library](docs/user/search-library.md): finding text in every book at once.

### Reading, exporting, and transcribing

- [Reader windows](docs/user/reader-windows.md): playing, navigating, bookmarks, Where Am I?, and the sleep timer.
  - [Pages in a reader](docs/user/reader-pages.md): Go to Page and skipping by page.
  - [Media keys and the sleep timer](docs/user/reader-media-and-sleep-timer.md): headphones, AirPods, the timer.
  - [When a book ends, and your saved places](docs/user/reader-book-end.md): what plays next.
  - [When speech or audio goes wrong](docs/user/reader-speech-problems.md): refusals, stalls, memory limits.
  - [The reader on the iPhone](docs/user/reader-on-iphone.md): VoiceOver's order, Book content, Book Actions.
- [Exporting books](docs/user/exporting-books.md): what Export copies, and the Convert to menu.
  - [Exporting on the iPhone](docs/user/exporting-on-iphone.md): the sheet, the kept folder, braille rows.
  - [Exporting braille files](docs/user/exporting-braille.md): BRF and PEF options, layout, and emphasis.
  - [Exporting a transcript as captions](docs/user/exporting-captions.md): WebVTT and SubRip files.
  - [Exporting text as spoken audio](docs/user/exporting-spoken-audio.md): M4B, M4A, and MP3 files.
- [Editing a book's text](docs/user/editing-book-text.md): Edit Text in your own editor.
- [Transcribing an audiobook](docs/user/transcribing.md): Transcribe Audio, Retranscribe Audio, Clean Up Transcript, Attach Transcript.

### Settings, recording, and feeds

- [Settings](docs/user/settings.md): every tab of the Settings window.
  - [Settings: Shortcuts](docs/user/settings-shortcuts.md): changing, recording, and resetting keys.
  - [Settings: Braille](docs/user/settings-braille.md): the braille code, and this Mac's tables.
  - [Settings: Library](docs/user/settings-library.md): the views, titles, and the view editor.
  - [Settings: Storage](docs/user/settings-storage.md): library folder, imports, duplicates, maintenance.
- [Recording from a microphone](docs/user/recording.md): the New Recording window.
- [Editing audio](docs/user/editing-audio.md): the audio editor.
- [Podcasts and article feeds](docs/user/feeds.md): subscribing, downloading, and reading feeds.

### The library, its files, and its speed

  - [Downloading feed episodes and articles](docs/user/feed-downloads.md): listing, downloads, cancelling, quitting.
  - [Feed, episode, and article commands](docs/user/feed-commands.md): Check Feed, Feed Info, deleting episodes.
  - [Listening on, feed settings, and transcripts](docs/user/feed-listening-and-settings.md): next episode, Feeds tab, podcast transcripts.
- [Speed and memory](docs/user/speed-and-memory.md): how TextMouth stays quick with a large library.
- [Where TextMouth keeps your library](docs/user/where-your-library-lives.md): the data directory, its files, and logs.
  - [What the data directory holds](docs/user/data-directory-files.md): library.json, settings files, feeds, and sessions.
  - [A book's package](docs/user/book-packages.md): the files inside each book's folder.
  - [The diagnostic logs](docs/user/library-logs.md): the log files and where they go.
  - [Folders of this Mac's own](docs/user/this-macs-folders.md): working copies, staging, recordings, and caches.
  - [Helper programs TextMouth watches](docs/user/helper-programs.md): the converters, textutil, and the braille helper.
- [Keeping your library in the cloud](docs/user/cloud-library.md): iCloud Drive, Dropbox, Google Drive.
- [Syncing your library between your devices](docs/user/syncing-your-library.md): Set Up Sync and Sync Now.
  - [Syncing on the iPhone](docs/user/syncing-on-iphone.md): the Sync section, and Sync Now.
- [Editing settings in config.json](docs/user/config-json.md): every setting the file holds.

## For people building TextMouth

- [Building TextMouth](docs/developer/building.md): make targets, versions, and the check gate.
  - [Building the iOS app](docs/developer/building-ios.md): type-checks, the heavy-work lock, GitHub builds, the simulator.
  - [Release builds](docs/developer/building-release.md): the size settings, their profiles, and the Release golden tests.
- [Testing TextMouth](docs/developer/testing.md): the hosted suite, baselines, cloud tests.
  - [Reusable test tools](docs/developer/testing-tools.md): the `Scripts/test/` tools.
  - [Document goldens](docs/developer/testing-goldens.md): goldens, and the rich text, Word, and ODT tests.
  - [Markup guard, Kindle, and MOBI tests](docs/developer/testing-formats.md): reader tests for those formats.
  - [Tests on GitHub Actions](docs/developer/testing-github.md): the runner, and how it differs.
  - [Testing the iPhone app](docs/developer/testing-iphone.md): the phone area, the two iOS test targets.
  - [Testing library sync](docs/developer/testing-sync.md): the sync area, two devices, the log.
  - [The iPhone accessibility audit](docs/developer/testing-iphone-audit.md): the audit, its accepted findings, the UI tests.
- [Translating TextMouth](docs/developer/translation.md): the translation tools, the glossary, and the rules.
- [The interface languages](docs/developer/translation-languages.md): each language's letters, address, plurals, and doubts.
- [Localizing TextMouth's code](docs/developer/localization.md): writing a line, IDs, the engine, and the commands.
- [Architecture](ARCHITECTURE.md): state ownership, how a book is read, shared helpers.
- [Third-party code](docs/developer/third-party-code.md): the libraries TextMouth includes, and their licences.

## For coding agents

- [AGENTS.md](AGENTS.md): start here: where state lives, the standing rules, how agents work.
- [Working on TextMouth with coding agents](docs/agents/working-with-agents.md): the message board.
- [The agents' history](docs/agents/history.md): earlier campaigns' status, and the stories behind the rules.
- [Writing docs and memory files](docs/agents/writing-docs.md): the rules every page follows.
- [Orchestrating TextMouth's agents](docs/agents/orchestrator.md): launching, merging, recording, trains, teams.
