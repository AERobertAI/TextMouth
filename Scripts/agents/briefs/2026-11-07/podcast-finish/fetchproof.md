# Worker `pf-fetchproof`: an episode's own files, reviewed and proven

Slug `pf-fetchproof`, branch `podcast/fetch-proof`. Read `common.md` beside this brief first.

## What this is

The lead has just written FMT25's fetch, and nobody else has read it. Read it as a skeptic: your job is to find what's wrong with it, and to prove its tests by breaking the code in a throwaway copy.

The code: `TextMouth/Services/Feeds/FeedEpisodeExtras.swift`, `downloadEpisode` and `attachTranscript` in `TextMouth/Services/Feeds/FeedDownloadManager.swift`, `stageFile` and `keep` in `TextMouth/Services/Feeds/FeedEpisodeImporter.swift`, `holdsListenersFiles` in `TextMouth/Services/Feeds/FeedItemPackage.swift`, `holdsUntouchedPodcastTranscript` in `TextMouth/Services/TranscriptInstallation.swift`, and `feedTranscriptAttached` in `TextMouth/ViewModels/LibraryViewModel+Feeds.swift`. See them with `git diff main...podcast/finish -- <file>`. The tests: `TextMouthProductionTests/FeedEpisodeExtrasTests.swift`. Its brief, slightly older than the code: `Scripts/agents/briefs/2026-10-30/podcastext/fetch.md`. Decisions 3 to 8 of `Scripts/agents/briefs/2026-10-30/team-podcastext.md` are what it must do.

Other workers are reviewing the readers, the attach path, the chapters' path, and export, so leave those to them. Post a `finding` for what you see there.

## Check, at least

1. **Nothing can stop the episode's download.** Walk every path from the transfer's end to `FEED_DOWNLOAD_FINISHED`: a throw, a hang, a trap, a wait with no limit. The task group in `fetch`: can it wait for good? What does a stalled server do, one that sends a byte every 25 seconds forever (the feed session's own timeouts), and what does `timeLimit` then do? Does a fetch's cancellation reach the `URLSession` task at every point, including before its delegate is set (board #4438, `resumeUnlessCancelled`)?
2. **Cancel, quit, and being asked again.** Cancel Download, the downloads section's Cancel (`cancelEveryDownload`, which also clears the holding folder), Delete Episode, Delete Feed…, a quit, and the same item asked for again, each during the fetch and during `attachTranscript`. What does the listener hear, what state is the item left in, is the file left in the holding folder, and is the next download right? Does `Cancel Download` during `attachTranscript` say the true thing (`cancelTargets`)?
3. **The queue.** The manager runs one download at a time, on the main actor with awaits. Does anything here block the main thread? `TranscriptStore.holdsUntouchedPodcastTranscript` is asked on the main thread: how long does it take on a realistic 20 MB transcript.json, a 3-hour episode of one-word segments, in a harness? `FeedEpisodeExtras.attach` runs on the import queue: is anything else held up behind it, and can a rule's removal, a data-directory move, or a reader opening the book race with it? `attachTranscript` runs `TranscriptionPlan.make` before `install`'s storage boundary: is a move between them safe?
4. **What a listener gets, in the app's other paths.** A kept package restored; a video episode (`AVAudioFile` cannot read one: what happens?); an Ogg episode (converted at import? `TranscriptionPlan.duration` refuses to decode one in-process, as it must); a cloud library; an item with no enclosure; an article. A transcript with chapters: does the reader show the text under the chapters' headings?
5. **The rule that a podcast's untouched transcript holds nothing of the listener's.** Every caller of `holdsListenerState` and `holdsListenersFiles`. Is the `Provenance` decoder really cheaper than a full decode (measure it), and can it say "untouched" of a transcript the listener did touch, for instance one whose cleanup left a `transcript.json.before-cleanup`, or one in which `editedAt` is present and null? Does the listener's Clean Up, or Edit Text, change anything else that should count?
6. **The third-party rules.** Which requests does an episode cause, in every case? Is any address in a file ever opened? Can a feed make TextMouth fetch a `file:` address, or one on this Mac (`http://localhost`, a link-local address)? The audio's enclosure could already be such an address, so compare. Do a redirect loop, a 5 GB `Content-Length`, a body with no length that never ends, and a gzip bomb stay bounded (does `URLSession`'s automatic decompression run before the limit counts the bytes)? No log line holds an address or a word of a file.
7. **The tests.** Read them as a skeptic, and prove them.

## Proving them

The whole app is too large for a scratch copy within the size limit. So build a small SwiftPM package or `swiftc` harness holding verbatim copies of `FeedEpisodeExtras.swift`, the readers (`TextMouth/Parsers/TimedText*.swift`, `WebVTTReader.swift`, `SubRipReader.swift`, `PodcastTranscriptReader.swift`, `PodcastChapters.swift`), `TextMouth/Models/TimedText.swift`, and the network part of `FeedNetwork.swift`, with small stubs for what they reach (`DiagnosticLog`, `FeedItem`, `Feed`, `TranscriptStore`, and so on), a `URLProtocol` stub as `TextMouthProductionTests/FeedTestSupport.swift`'s `FeedStubProtocol` is, and the pure tests cut in verbatim. Mutate: the order of formats, the cap of tries, each address once, the type table, the time limit, `Task.isCancelled` in `body`, the group's `cancelAll`, the limits passed to each fetch, `holdsUntouchedPodcastTranscript`'s three conditions. For the hosted end-to-end tests, which need the app, read each against the code and say in your report why it would fail if the code were wrong, or say you could not tell.

## Fix what you find

A commit for each fix, with a test that fails without it. Keep the log lines' tags, since the tests and the report name them. Claim the files you edit. The lead is on `podcast/finish` and may change these files too: post on the board before you edit `FeedDownloadManager.swift`, and keep your edits to the lines of this feature.

Run `FeedEpisodeExtrasTests FeedDownloadTests FeedItemRecordTests FeedLifecycleTests LogContentPolicyTests UncheckedConcurrencyPolicyTests` on the train.
