# Worker `pf-chapters`: a podcast's chapters as an episode's headings, reviewed

Slug `pf-chapters`, branch `podcast/chapters-proof`. Read `common.md` beside this brief first.

## Your files

`PodcastChapters.bookChapters(fileDuration:)` in `TextMouth/Parsers/PodcastChapters.swift` (worker `pf-readers` owns the rest of that file, so keep to that function), the branch's changes to `TextMouth/Parsers/AudioBookParser.swift`, `TextMouth/Services/BookContentAnalysisService.swift`, `TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift`, `TextMouth/Services/FileImportService+Packages.swift`, and `TextMouth/Services/TextMouthPaths.swift` (see them with `git diff main...podcast/finish -- <file>`), and `TextMouthProductionTests/PodcastChaptersHeadingsTests.swift`. Read `NeroChapterReader.bookChapters(from:fileDuration:)` too, which `bookChapters` hands its chapters to.

The lead is writing, on `podcast/finish`, the part that fetches the chapters and writes them as `podcastChapters.json` in the staged package before it is read (`FeedEpisodeImporter`, `FeedEpisodeExtras`). You don't touch `TextMouth/Services/Feeds/`.

## What this is

Decision 4: a podcast's chapters become the episode's headings only when the episode's audio has none of its own, `toc: false` chapters are left out, and they never replace headings the listener edited. Decision 6: a chapters file whose last start lies more than 5 seconds past the audio's end is refused.

## Check, at least

1. **When the file is read.** Every path that analyzes an episode's audio: the first import, opening the book, a stale or damaged index, the launch's re-read, an audio edit (`dropPodcastChapters`), a kept package restored by a new download, Move to Library…. Does each find the chapters, or rightly not? What happens to a package whose name the book's `tmbDirectoryName` gives while it is staged? Is a chapters file read for a book that isn't a podcast's, and could an import copy one in from a folder the listener chose (`isPackageContentName`, a `.tmb` package imported from elsewhere, or a folder of tracks holding a file with that name)?
2. **What a listener edited.** Which edits of an audiobook's headings exist (Edit Manifest for tracks, a transcript's Edit Text, Book Information's chapter titles if any)? For each, could a re-analysis with the chapters file bring a podcast's chapters back over it? Find out and prove it, or show the path is closed.
3. **The audio changes.** An audio edit drops the file. A failed drop, and a re-download with other advertisements: the old chapters must not be laid over the new audio. `FeedItemPackage.staysWithoutTheFile` does not keep it: follow what `removeWhatTheFileMade` and `copyWhatANewDownloadKeeps` do with it.
4. **The chapters.** Nero's rules on what comes: a first chapter starting after 0, duplicate starts, starts past the end within the margin, a single chapter, 5,000 chapters (does `BookContentIndex.build`, or the heading list, cope? what does it cost?), untitled ones ("Chapter N"), very long titles (5 MB of JSON holding one title of a megabyte: is it bounded before it reaches a heading a listener hears?), titles of white space, a title holding a line feed or Markdown. A file-reported duration of 0 or NaN.
5. **A transcript with chapters.** `TranscriptTextBuilder` and the reader: when the episode has both, do the text's headings follow the chapters, and does following along work across them? Follow it by reading, and with a hosted test if none exists.
6. **The unused-file log lines:** `PODCAST_CHAPTERS_UNUSED`, `PODCAST_CHAPTERS_DROPPED`, `PODCAST_CHAPTERS_LEFT`. Do they repeat on every open (is one line per read too chatty, for a book opened daily)? They quote no title and no path.
7. **The tests.** Read them as a skeptic. Prove `bookChapters` by mutation in a harness (see `common.md`), with `NeroChapterReader`'s file.

## Fix what you find

A commit for each fix, with a test that fails without it. Don't change a decision of the team's brief: if one looks wrong, tell the lead.

Run `PodcastChaptersHeadingsTests PodcastChaptersTests` and the `analysis` area on the train.
