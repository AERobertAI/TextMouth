# TextMouth

TextMouth is a native macOS application that reads books aloud with the Mac's text-to-speech voices and plays audiobooks. It is designed for people who read with VoiceOver and a braille display, and its rule is that every control has a spoken label, every value on screen has a spoken equivalent, and every action can be done from the keyboard.

This file is the index of TextMouth's documentation, whose pages are in the docs folder: a page for each part of the app, for the person using it; how to build and test TextMouth; and the notes coding agents work from. ARCHITECTURE.md, in the same folder, is the index of the pages explaining how the code is organized and which part of the app owns each kind of data.

## For people using TextMouth

- [What TextMouth reads](docs/user/what-textmouth-reads.md): the formats it imports and plays.
- [The audiobook manifest](docs/user/audiobook-manifest.md): manifest.json, which orders, titles, groups, and paces a ZIP of audio tracks.
- [Adding books](docs/user/adding-books.md): Open Book, Finder, ZIP archives, DAISY folders, New from Text.
- [The Library window](docs/user/library-window.md): categories, folders, sorting, searching, and the commands on books.
- [Reader windows](docs/user/reader-windows.md): playing, navigating, bookmarks, Where Am I?, and the sleep timer.
- [Exporting books](docs/user/exporting-books.md): what Export copies out of the library.
- [Editing a book's text](docs/user/editing-book-text.md): Edit Text in your own editor.
- [Transcribing an audiobook](docs/user/transcribing.md): Transcribe Audio and Clean Up Transcript, on macOS 26 and later.
- [Settings](docs/user/settings.md): every tab of the Settings window.
- [Recording from a microphone](docs/user/recording.md): the New Recording window.
- [Editing audio](docs/user/editing-audio.md): the audio editor.
- [Podcasts and article feeds](docs/user/feeds.md): subscribing, downloading, and reading feeds.
- [Speed and memory](docs/user/speed-and-memory.md): how TextMouth stays quick with a large library.
- [Where TextMouth keeps your library](docs/user/where-your-library-lives.md): the data directory, its files, and the logs.
- [Keeping your library in the cloud](docs/user/cloud-library.md): a data directory in iCloud Drive, Dropbox, or Google Drive.
- [Editing settings in config.json](docs/user/config-json.md): every setting the file holds.

## For people building TextMouth

- [Building TextMouth](docs/developer/building.md): what you need, the make targets (`make build`, then `make install` to put the app in Applications), and the make check gate.
- [Testing TextMouth](docs/developer/testing.md): the hosted test suite, the performance baselines, and the tests on real cloud drives.
- [Architecture](ARCHITECTURE.md): who owns each kind of state, how a book is read, the shared helpers, and the duplication left in place.
- [Third-party code](docs/developer/third-party-code.md): the libraries TextMouth includes, and their licences.

## For coding agents

- [AGENTS.md](AGENTS.md): start here. Where the project's state lives, the user's standing rules, how a task agent works, and how the orchestrator merges and records.
- [Working on TextMouth with coding agents](docs/agents/working-with-agents.md): the message board the agents coordinate through.
- [Where things stood, earlier campaigns](docs/agents/history.md): the status of each earlier campaign.
