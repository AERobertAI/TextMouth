# TextMouth architecture

This document explains how TextMouth is put together and, above all, which part of the app owns each kind of state: who keeps it, who may change it, and how everything else finds out about a change. It describes main as of October 10, 2026. When a change moves the ownership of some state, update its page in the same branch.

README.md indexes the pages on building, testing, the files in the data directory, and keeping the library in the cloud. In these pages, paths are relative to the TextMouth source folder unless they start with the name of another top-level folder, and names in the text are the names of Swift types, functions, and properties.

Each part below is a page of its own under docs/architecture, so an agent can read only the parts its task touches.

- [The parts of the app](docs/architecture/parts-of-the-app.md)
- [Launch](docs/architecture/launch.md)

## Who owns each kind of state

Each entry names a kind of state, then its owner, who may write it, how others observe it, and the files involved.

- [The library index](docs/architecture/state/library-index.md)
- [Package records](docs/architecture/state/package-records.md)
- [Audio edits](docs/architecture/state/audio-edits.md)
- [Text caches and content indexes](docs/architecture/state/text-caches.md)
- [The data directory](docs/architecture/state/data-directory.md)
- [Cloud state](docs/architecture/state/cloud-state.md)
- [Preferences](docs/architecture/state/preferences.md)
- [The reader](docs/architecture/state/reader.md)
- [Media playback](docs/architecture/state/media-playback.md)
- [Timers and statistics](docs/architecture/state/timers-and-statistics.md)
- [Windows](docs/architecture/state/windows.md)
- [Saving failures](docs/architecture/state/saving-failures.md)
- [Imports](docs/architecture/state/imports.md)
- [Feeds](docs/architecture/state/feeds.md)
- [Recordings](docs/architecture/state/recordings.md)
- [Transcription](docs/architecture/state/transcription.md)
- [Exports](docs/architecture/state/exports.md)
- [Logs](docs/architecture/state/logs.md)
- [The hosted-test sandbox](docs/architecture/state/hosted-test-sandbox.md)

## The rest

- [Reading a book: the path from library row to spoken audio](docs/architecture/reading-a-book.md)
- [Shared helpers](docs/architecture/shared-helpers.md)
- [Known duplication](docs/architecture/known-duplication.md)
