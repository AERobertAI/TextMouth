# TextMouth

TextMouth is a native macOS application that reads books aloud with the Mac's text-to-speech voices and plays audiobooks. It is designed for people who read with VoiceOver and a braille display, and its rule is that every control has a spoken label, every value on screen has a spoken equivalent, and every action can be done from the keyboard.

This file is the index of TextMouth's documentation, whose pages are in the docs folder: a page for each part of the app, for the person using it; how to build and test TextMouth; and the notes coding agents work from. ARCHITECTURE.md, in the same folder, is the index of the pages explaining how the code is organized and which part of the app owns each kind of data.

## A note on Ogg audio

TextMouth no longer plays Ogg audio (.ogg, .oga, or .opus) itself. On October 14, 2026 macOS's own Vorbis decoder locked up while TextMouth played an Ogg audiobook; TextMouth's memory then grew until the Mac ran out, and the Mac had to be restarted. So every Ogg file is now converted to an .m4a file as it is imported, in AAC at about its own bit rate, which can lose a little, or in Apple Lossless for Ogg FLAC, which loses nothing, and the Ogg books already in the library are converted once, a book at a time, at the first launch of this version; the Library window shows the progress, and a book can't be played while it converts. TextMouth also now stops any playback whose audio stops responding, and saves your place and quits before a fault in macOS's audio can exhaust the Mac's memory. See [What TextMouth reads](docs/user/what-textmouth-reads.md) and [Reader windows](docs/user/reader-windows.md).

## For people using TextMouth

- [Changelog](docs/user/changelog.md): every version of TextMouth, newest first, and what changed for you in each.
- [What TextMouth reads](docs/user/what-textmouth-reads.md): the formats it imports and plays, among them Kindle books in MOBI, KF8 (.azw3), and KFX.
- [The audiobook manifest](docs/user/audiobook-manifest.md): manifest.json, which orders, titles, groups, and paces a ZIP or folder of audio tracks, and Edit Manifest, which changes it after import.
- [Adding books](docs/user/adding-books.md): Open Book, Finder, ZIP archives, Import Folder… for DAISY books and folders of tracks, New from Text.
- [The Library window](docs/user/library-window.md): the View pop-up and the views you arrange and make, folders, sorting, searching, and the commands on books.
- [Search Library](docs/user/search-library.md): Edit > Find > Search Library… (Option-Command-F), which finds a word, phrase, or regular expression in the text of every book at once, with Match Case, and opens a match in its reader.
- [Reader windows](docs/user/reader-windows.md): playing, navigating, bookmarks, Where Am I?, and the sleep timer.
- [Exporting books](docs/user/exporting-books.md): what Export copies out of the library, and the Convert to menu that makes a text book's text HTML, RTF, a Word 97-2003 document, a braille file (BRF or PEF), or spoken audio (M4B, M4A, or MP3); and a transcript as WebVTT or SubRip captions.
- [Editing a book's text](docs/user/editing-book-text.md): Edit Text in your own editor.
- [Transcribing an audiobook](docs/user/transcribing.md): Transcribe Audio, Retranscribe Audio, and Clean Up Transcript, on macOS 26 and later; and Attach Transcript, on any macOS.
- [Settings](docs/user/settings.md): every tab of the Settings window.
- [Recording from a microphone](docs/user/recording.md): the New Recording window.
- [Editing audio](docs/user/editing-audio.md): the audio editor.
- [Podcasts and article feeds](docs/user/feeds.md): subscribing, downloading, and reading feeds.
- [Speed and memory](docs/user/speed-and-memory.md): how TextMouth stays quick with a large library.
- [Where TextMouth keeps your library](docs/user/where-your-library-lives.md): the data directory, its files, and the logs.
- [Keeping your library in the cloud](docs/user/cloud-library.md): a data directory in iCloud Drive, Dropbox, or Google Drive.
- [Editing settings in config.json](docs/user/config-json.md): every setting the file holds.

## For people building TextMouth

- [Building TextMouth](docs/developer/building.md): what you need, the make targets (`make build`, then `make install` to put the app in Applications), the version policy and how the version number is raised (`make bump-patch`, `make bump-minor`) or set (`make set-version`), the make check gate, and the iOS app (`TextMouthiOS`), which `make typecheck-ios` compiles and links without Xcode's iOS platform, with `make typecheck-mac` and `make mac-projection`.
- [Testing TextMouth](docs/developer/testing.md): the hosted test suite, the performance baselines, and the tests on real cloud drives. It also covers the reusable test tools in `Scripts/test/`: run only some tests (`make test-area AREAS="feeds bookmarks"`), check the lines a branch adds (`make lint-tests`, `make lint-a11y`, `make lint-ogg`), record and compare document goldens (`Scripts/test/update-goldens.sh`), report on a folder of documents (`Scripts/test/corpus-report.sh`), and the opt-in sweeps for voices, damaged imports, and storage failures.
- [Architecture](ARCHITECTURE.md): who owns each kind of state, how a book is read, the shared helpers, and the duplication left in place. [The two apps and the platform folders](docs/architecture/platforms.md) says how one source folder builds the Mac app and the iOS app: `TextMouth/Platform/macOS`, `TextMouth/Platform/iOS`, and the files they share.
- [Third-party code](docs/developer/third-party-code.md): the libraries TextMouth includes, and their licences.

## For coding agents

- [AGENTS.md](AGENTS.md): start here. Where the project's state lives, the user's standing rules, how a task agent works, and how the orchestrator merges and records.
- [Working on TextMouth with coding agents](docs/agents/working-with-agents.md): the message board the agents coordinate through.
- [Where things stood, earlier campaigns](docs/agents/history.md): the status of each earlier campaign.
