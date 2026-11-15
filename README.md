# TextMouth

TextMouth is a native macOS application that reads books aloud with the Mac's text-to-speech voices and plays audiobooks.
It is designed for people who read with VoiceOver and a braille display, and its rule is that every control has a spoken label, every value on screen has a spoken equivalent, and every action can be done from the keyboard.

This file is the index of TextMouth's documentation, whose pages are in the docs folder: a page for each part of the app, for the person using it; how to build and test TextMouth; and the notes coding agents work from.
ARCHITECTURE.md, in the same folder, is the index of the pages explaining how the code is organized and which part of the app owns each kind of data.

## For people using TextMouth

- [Changelog](docs/user/changelog.md): every version, newest first, and what changed.
- [What TextMouth reads](docs/user/what-textmouth-reads.md): the formats it imports and plays.
- [The audiobook manifest](docs/user/audiobook-manifest.md): manifest.json, and Edit Manifest.
- [Adding books](docs/user/adding-books.md): Open Book, Finder, ZIP archives, Import Folder…, New from Text.
- [The Library window](docs/user/library-window.md): views, folders, sorting, searching, and commands on books.
- [Search Library](docs/user/search-library.md): finding text in every book at once.
- [Reader windows](docs/user/reader-windows.md): playing, navigating, bookmarks, Where Am I?, and the sleep timer.
  - [Pages in a reader](docs/user/reader-pages.md): Go to Page and skipping by page.
  - [Media keys and the sleep timer](docs/user/reader-media-and-sleep-timer.md): headphones, AirPods, the timer.
  - [When a book ends, and your saved places](docs/user/reader-book-end.md): what plays next.
  - [When speech or audio goes wrong](docs/user/reader-speech-problems.md): refusals, stalls, memory limits.
- [Exporting books](docs/user/exporting-books.md): what Export copies, and the Convert to menu.
- [Editing a book's text](docs/user/editing-book-text.md): Edit Text in your own editor.
- [Transcribing an audiobook](docs/user/transcribing.md): Transcribe Audio, Retranscribe Audio, Clean Up Transcript, Attach Transcript.
- [Settings](docs/user/settings.md): every tab of the Settings window.
- [Recording from a microphone](docs/user/recording.md): the New Recording window.
- [Editing audio](docs/user/editing-audio.md): the audio editor.
- [Podcasts and article feeds](docs/user/feeds.md): subscribing, downloading, and reading feeds.
- [Speed and memory](docs/user/speed-and-memory.md): how TextMouth stays quick with a large library.
- [Where TextMouth keeps your library](docs/user/where-your-library-lives.md): the data directory, its files, and logs.
- [Keeping your library in the cloud](docs/user/cloud-library.md): iCloud Drive, Dropbox, Google Drive.
- [Editing settings in config.json](docs/user/config-json.md): every setting the file holds.

## For people building TextMouth

- [Building TextMouth](docs/developer/building.md): make targets, versions, the check gate, the iOS app.
  - [Building the iOS app](docs/developer/building-ios.md): type-checks, the heavy-work lock, GitHub builds, the simulator.
- [Testing TextMouth](docs/developer/testing.md): the hosted suite, baselines, cloud tests.
  - [Reusable test tools](docs/developer/testing-tools.md): the `Scripts/test/` tools.
  - [Document goldens](docs/developer/testing-goldens.md): goldens, and the rich text, Word, and ODT tests.
  - [Markup guard, Kindle, and MOBI tests](docs/developer/testing-formats.md): reader tests for those formats.
  - [Tests on GitHub Actions](docs/developer/testing-github.md): the runner, and how it differs.
  - [Testing the iPhone app](docs/developer/testing-iphone.md): the phone area, the two iOS test targets.
  - [The iPhone accessibility audit](docs/developer/testing-iphone-audit.md): the audit, its accepted findings, the UI tests.
- [Architecture](ARCHITECTURE.md): state ownership, how a book is read, shared helpers.
- [Third-party code](docs/developer/third-party-code.md): the libraries TextMouth includes, and their licences.

## For coding agents

- [AGENTS.md](AGENTS.md): start here: where state lives, the standing rules, how agents work.
- [Working on TextMouth with coding agents](docs/agents/working-with-agents.md): the message board.
- [The agents' history](docs/agents/history.md): earlier campaigns' status, and the stories behind the rules.
- [Writing docs and memory files](docs/agents/writing-docs.md): the rules every page follows.
- [Orchestrating TextMouth's agents](docs/agents/orchestrator.md): launching, merging, recording, trains, teams.
