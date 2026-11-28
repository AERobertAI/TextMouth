# TextMouth architecture

This document explains how TextMouth is put together and, above all, which part of the app owns each kind of state: who keeps it, who may change it, and how everything else finds out about a change.
When a change moves the ownership of some state, update its page in the same branch.

README.md indexes the pages on building, testing, the files in the data directory, and keeping the library in the cloud.
In these pages, paths are relative to the TextMouth source folder unless they start with the name of another top-level folder, and names in the text are the names of Swift types, functions, and properties.

Each part below is a page of its own under docs/architecture, so an agent can read only the parts its task touches.

- [The parts of the app](docs/architecture/parts-of-the-app.md)
- [The two apps and the platform folders](docs/architecture/platforms.md)
  - [The iPhone interface: announcements, text, sheets, and search](docs/architecture/platforms-phone-interface.md)
  - [The iPhone reader's controls: Book Actions, the timer, and the skips](docs/architecture/platforms-phone-reader.md)
  - [Feeds on the iPhone: rows, the hub, and focus](docs/architecture/platforms-phone-feeds.md)
- [Launch](docs/architecture/launch.md)

## Who owns each kind of state

Each entry names a kind of state, then its owner, who may write it, how others observe it, and the files involved.

### The library, its files, and its caches

- [The library index](docs/architecture/state/library-index.md)
  - [The reading list and feed items](docs/architecture/state/library-index-reading-feeds.md)
- [Package records](docs/architecture/state/package-records.md)
  - [Package records: places, transcripts, origin, manifests](docs/architecture/state/package-records-places-and-files.md)
- [Audio edits](docs/architecture/state/audio-edits.md)
- [Text caches and content indexes](docs/architecture/state/text-caches.md)
  - [Kept texts, re-reads, and edited text](docs/architecture/state/text-caches-rereads-edits.md)
- [The data directory](docs/architecture/state/data-directory.md)
- [Cloud state](docs/architecture/state/cloud-state.md)
- [Library sync](docs/architecture/state/library-sync.md): the folder, outbox, and merge.
  - [Library sync: books and rules](docs/architecture/state/library-sync-store.md): blobs, folder access, R1 to R9.
- [Preferences](docs/architecture/state/preferences.md)
  - [Preferences: keyboard shortcuts](docs/architecture/state/preferences-shortcuts.md)

### Reading, playback, and windows

- [The reader](docs/architecture/state/reader.md)
  - [The reader's playback and speech](docs/architecture/state/reader-playback.md)
  - [The reader's moves between books, and search](docs/architecture/state/reader-navigation.md)
- [Media playback](docs/architecture/state/media-playback.md)
- [Timers and statistics](docs/architecture/state/timers-and-statistics.md)
- [Windows](docs/architecture/state/windows.md)
  - [Windows: sheets, search, Speak Info](docs/architecture/state/windows-sheets.md)
- [Interface text and language](docs/architecture/state/interface-text.md): the engine, the pack, and the switch.
- [Saving failures](docs/architecture/state/saving-failures.md)

### Imports

- [Imports](docs/architecture/state/imports.md): the import itself, its progress, questions, and folders.
  - [Duplicates](docs/architecture/state/imports-duplicates.md): unanswered duplicates, and Replace Existing.
  - [DAISY 3 books](docs/architecture/state/imports-daisy.md): several DTBook files, and SMIL clocks.
  - [Audio](docs/architecture/state/imports-audio.md): manifests, conversion, playlists, Ogg, and chapters.
  - [Audio only FFmpeg reads](docs/architecture/state/imports-audio-ffmpeg.md): the helper, its sandbox, and its limits.
  - [Documents textutil reads](docs/architecture/state/imports-textutil.md): web archives, SSML, and DTBooks.
  - [Rich text and Word](docs/architecture/state/imports-rtf-and-word.md): the RTF, Word 97-2003, and Word 6 readers.
  - [DOCX, OpenDocument, and Word 2003 XML](docs/architecture/state/imports-office-xml.md): the readers' policies.
  - [Password-protected books](docs/architecture/state/protected-books.md): detecting, unlocking, and never writing their text.
  - [Kindle books](docs/architecture/state/imports-kindle.md): KFX, MOBI 6, and KF8.
  - [Braille files](docs/architecture/state/imports-braille.md): BRF, BRL, PEF, and BARD braille books, and their records.
  - [Braille tables](docs/architecture/state/imports-braille-tables.md): the translator helper, the table check, and the guess.
  - [Braille table pack](docs/architecture/state/braille-table-pack.md): the catalog, the pack, the unpacker, and the lists.
  - [Text in other encodings](docs/architecture/state/imports-text-encodings.md): finding and guessing the encoding.
  - [Choosing the encoding](docs/architecture/state/imports-text-encoding-choice.md): the listener's way to mend a guess.

### Feeds, recordings, exports, logs, and the test sandbox

- [Feeds](docs/architecture/state/feeds.md)
  - [Feed options, interface, and arrivals](docs/architecture/state/feeds-interface.md)
- [Recordings](docs/architecture/state/recordings.md)
- [Transcription](docs/architecture/state/transcription.md)
- [Exports](docs/architecture/state/exports.md)
  - [A chapter nested too deeply](docs/architecture/state/exports-deep-chapter.md): the question, and the lines as written.
  - [Exports on the iPhone](docs/architecture/state/exports-iphone.md): the delivery seam, kept folder, memory check.
- [Logs](docs/architecture/state/logs.md)
- [The hosted-test sandbox](docs/architecture/state/hosted-test-sandbox.md)

## The rest

- [Reading a book: the path from library row to spoken audio](docs/architecture/reading-a-book.md)
- [Shared helpers](docs/architecture/shared-helpers.md)
  - [Shared helpers: values, ordering, and wording](docs/architecture/shared-helpers-values.md)
  - [Shared helpers: readers and markup guards](docs/architecture/shared-helpers-parsers.md)
- [Known duplication](docs/architecture/known-duplication.md)
