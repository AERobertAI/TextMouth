# Team `podcastext`: transcripts and chapters from outside (FMT23, FMT25), October 30, 2026

Read `teams-common.md` beside this file first: it is the pattern, the rules, and the report format, and it stands in for AGENTS.md. You are the lead, `podcastext-lead`, on branch `team/podcastext`, made from local `main` by name (`git checkout -b team/podcastext main`; your worktree may start on an older commit).

## What and why
Two items of the TODO's formats section, which the user approved on October 18 (questions 12 and 13 of `FORMATS-RESEARCH-2026-10-17.md`, section 12, both answered "yes"; recorded in the TODO: "Everything else as recommended (… FMT23 and FMT25 …)"):
- **FMT23, SRT and WebVTT transcripts:** `grep -n "FMT23 —" TODO-2026-09-04.md` in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`, gitignored, so read it there, by line). Attach an existing transcript to an audiobook instead of transcribing it, on any macOS: a .srt or .vtt beside a track with the same name, at import (a single file, a folder, or a ZIP), or chosen by a Book menu command for a book already in the library. Export a transcript as either format.
- **FMT25, a podcast episode's own transcript and chapters:** `grep -n "FMT25 —" TODO-2026-09-04.md`. Feeds that follow Podcasting 2.0 link both, and TextMouth already stores the links (`FeedItem.transcripts`, `FeedItem.chapters`, `TextMouth/Models/FeedItem.swift:47-50`) and never fetches them. Fetch them beside the episode's download, under the download's network rules, on by default (the user's answer), so a downloaded episode has text and headings at once.

The research is `FORMATS-RESEARCH-2026-10-17.md` sections 5.4 and 5.5 (in your worktree once you branch from main). The samples are in `TestData/format-samples/` (`srt/`, `vtt/`, `podcast-transcript-json/`, `podcast-chapters-json/`; `samples.tsv` gives each one's source): untrusted input that the readers must survive, copied into a test's own folder before use.

## Read first
- How a transcript is stored and installed today: `TextMouth/Services/TranscriptStore.swift`, `TranscriptInstallation.swift`, `TranscriptSentenceBuilder.swift`, `TranscriptTextBuilder.swift`, `TranscriptTextLoader.swift`, `TranscriptionService.swift` (what it records: the audio's fingerprint and length, per track), `TranscribedBooks.swift`, and `docs/architecture/state/transcription.md` and `docs/user/transcribing.md`.
- How a feed episode is downloaded and becomes a book: `TextMouth/Services/Feeds/FeedEpisodeImporter.swift`, `FeedDownloadManager.swift`, `FeedNetwork.swift`, `FeedTransfer.swift`, `FeedItemPackage.swift`, and `docs/user/feeds.md` and `docs/architecture/state/feeds.md`.
- How a book's headings are kept for an audiobook (chapters from the file, the manifest's headings), and how Retranscribe Audio… and Delete Transcript… treat a transcript (`ReaderBookCommands.swift`, `TranscriptDeletion.swift`).
- How export writes a transcript today (`TextMouth/Services/BookExportService.swift`, `TextMouth/Services/Export/`).

## Decisions settled for you (the user's answers and the research's recommendations)
1. A transcript from outside replaces nothing silently: an audiobook that already has a transcript keeps it unless the listener chooses to replace it (an alert, as Retranscribe Audio… asks).
2. A transcript from a file or a feed is marked as such in the book's record (where it came from), so Retranscribe Audio… and Book Information can say so; recognition and outside transcripts share the one transcript store and the reader's whole transcript path (search, follow along, Edit Text, export).
3. WebVTT first, then JSON (Podcasting 2.0 1.0.0 segments), then SRT; text and HTML transcripts carry no times and are not fetched in this build (a follow-up).
4. A podcast's chapters become the episode's headings only when the episode's audio has none of its own (`toc: false` chapters are left out), and never replace headings the listener edited.
5. Third-party text is data: cap each fetched file's size (say 5 MB for a transcript and 1 MB for chapters, with the reason in a comment), follow none of its links, refuse what does not parse, and never let it stop the episode's own download: a failed or refused transcript or chapters file leaves the episode as it is today, with a line in the log.
6. Dynamic ads shift times: compare the transcript's last cue end, and the chapters' last start, with the episode's duration, and refuse one that runs past the audio's end by more than a few seconds (choose and justify the margin).
7. Fetching follows the download's network rules (the same rules for cellular-like or constrained networks, the same retries) and happens after the audio is safely in place.
8. Per-feed setting? Only if it falls out cheaply from the existing feed settings; otherwise on for every feed, and a per-feed switch is a follow-up.
9. The Book menu command's name: "Attach Transcript…", offered for an audiobook (not a text book), dimmed while one is being attached; its open panel takes .srt and .vtt.

## Order of work (each one or two commits, with tests)
1. The cue model, and the SRT and WebVTT readers (bounded, tolerant of BOMs, CRLF, both time forms, NOTE and STYLE blocks, voice tags turned into "Name: " text, cue settings ignored), with the samples.
2. Cues into the transcript store as `TranscriptSentence`s, per track, with the record's fingerprint and length as recognition records them; the import pairing by name; "Attach Transcript…".
3. The SRT and WebVTT writers, and Export of a transcript in either format (a file per track or one for the book, as the dialog's existing choices allow).
4. The Podcasting 2.0 JSON transcript reader and the chapters reader (version 1.2.0), bounded.
5. The fetch beside an episode's download, its limits, and the episode's transcript and headings from them.
Run each worker's touched classes plus the transcription, feed, and export areas in `Scripts/test/areas.conf`.

## Files
You own the new cue, reader, writer, and fetch files, and their tests. Shared files where you add only your own lines: `FeedEpisodeImporter.swift`, `FeedDownloadManager.swift`, `TranscriptStore.swift`, `TranscriptInstallation.swift`, `BookExportService.swift`, `ReaderBookCommands.swift` (the command), `MenuCommands.swift`, `FileImportService.swift` (the pairing at import), `Scripts/test/areas.conf`, `project.pbxproj` (by `xcodegen generate` only). The `bughunt` team reviews feeds and imports tonight and may fix bugs in the same files: claim each file before a worker edits it, read the claims, and agree on the board before editing a region another team claims.

## When you are done
Follow "Finish" in `teams-common.md`: rebase on main, one full suite, report, with every sentence a listener hears.
