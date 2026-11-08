# Task `fetch`: a podcast episode's own transcript and chapters, fetched with its download (FMT25, step 5b)

Slug `podcastext-fetch`, branch `podcastext/fetch` (from `team/podcastext`, which by now holds the readers, `TimedTextReader`, the store's builder and `keepingExisting`, `PodcastChapters`, and the chapters file read as headings). Read `common.md` beside this brief first.

## Goal
When an episode's audio has downloaded, fetch the transcript and the chapters file its feed links (Podcasting 2.0 `podcast:transcript` and `podcast:chapters`, stored on the item as `FeedItem.transcripts` and `.chapters`, `TextMouth/Models/FeedItem.swift:47-50, 420-425`), under the download's network rules, for every feed (the user's answer: on by default; no per-feed switch tonight). The chapters go into the episode's package before it is read, so the book is published with them as its headings when its audio has none of its own. The transcript becomes the episode's transcript once the book is in the library, unless the episode already has one. Nothing fetched can stop or fail the episode's own download: a failed or refused file leaves the episode exactly as it is today, with a line in the debug log.

Read first (by line): `TextMouth/Services/Feeds/FeedDownloadManager.swift:597-700` (running a download), `:698-770` (`downloadEpisode`), `:800-870` (`runBesideImports`, `importAndCommit`); `TextMouth/Services/Feeds/FeedNetwork.swift:85-100` (`request(for:discretionary:)`), `:236-330` (`fetch(_:etag:lastModified:discretionary:limit:)`, which already caps the body, follows only http and https redirects, sends no cookies, and refuses every request in a test host unless a stub answers); `TextMouth/Services/Feeds/FeedEpisodeImporter.swift:85-110, 160-330`; `TextMouth/Services/Feeds/FeedCenter.swift:83-160` (`FeedLibraryHost`); `TextMouth/ViewModels/LibraryViewModel+Feeds.swift` (its conformance: find `addFeedBook`); `TextMouth/ViewModels/TranscriptionJobCenter.swift:278-286` (what a finished transcription tells the library); `TextMouth/Services/OutsideTranscript.swift`; `TextMouth/Parsers/TimedTextReader.swift`; `TextMouth/Parsers/PodcastChapters.swift`.

## Files
- New `TextMouth/Services/Feeds/FeedEpisodeExtras.swift`: choosing, fetching, and reading the two files.
- `TextMouth/Services/Feeds/FeedDownloadManager.swift`: `downloadEpisode` fetches them and attaches the transcript (items 6 and 7).
- `TextMouth/Services/Feeds/FeedEpisodeImporter.swift`: `importEpisode` writes the chapters into the staged package (item 5).
- `TextMouth/Services/Feeds/FeedCenter.swift` (the protocol) and `TextMouth/ViewModels/LibraryViewModel+Feeds.swift` (its conformance): one requirement, item 8.
- New `TextMouthProductionTests/FeedEpisodeExtrasTests.swift`.
The `bughunt` team reviews feeds tonight and may fix bugs in these files: claim each before you edit it (`bbs claim`), read `bbs claims`, and post on `team:podcastext` which functions you touch; if another team holds a claim on one, ask its holder on the board before editing and tell the lead.

## Behavior
1. ```swift
   /// A podcast episode's own transcript and chapters (FMT25) ...
   enum FeedEpisodeExtras {
       /// What a download fetched beside the episode's audio.
       struct Fetched: Sendable, Equatable { var chapters: PodcastChapters?; var transcript: TimedTextDocument? }
       /// The most transcript links tried for one episode.
       static let maximumTranscriptTries = 3
       static func transcriptFormat(of resource: FeedResource) -> TimedTextFormat?
       static func transcriptCandidates(of item: FeedItem) -> [(url: URL, format: TimedTextFormat)]
       static func fetch(for item: FeedItem, of feed: Feed, network: FeedNetwork, discretionary: Bool,
                         transcriptLimit: Int = TimedTextLimits.podcastTranscriptBytes,
                         chaptersLimit: Int = TimedTextLimits.podcastChaptersBytes) async -> Fetched
   }
   ```
2. `transcriptFormat(of:)`: the resource's `mimeType`, lowercased, its parameters (after ";") and spaces dropped: "text/vtt" is WebVTT; "application/json" is Podcasting 2.0 JSON; "application/x-subrip", "application/srt", "application/x-srt", "text/srt", and "text/x-srt" are SubRip; "text/html" and "text/plain", which carry no times, are nil, never fetched (the charter's decision 3; a follow-up). A missing or other type falls back to the address's extension: "vtt", "json", "srt" (any case); nil otherwise.
3. `transcriptCandidates(of:)`: every link of the item with a format, ordered WebVTT first, then JSON, then SubRip (decision 3), in the feed's order within each, each address once, and at most `maximumTranscriptTries` of them.
4. `fetch`: never throws; returns what it could use.
   - **Chapters first,** when `item.chapters` is there: `network.fetch(url, discretionary: discretionary, limit: chaptersLimit)`, then `PodcastChapters.read` of the body. A failure leaves `chapters` nil with one log line (item 9).
   - **Then the transcript:** each candidate in order, fetched with `limit: transcriptLimit` and read with `TimedTextReader.read(_:as:)` in its format, until one reads; each failure logs a line and goes to the next candidate.
   - `discretionary` is the download's own (`request.origin == .window`, the newest-N rule's downloads): `FeedNetwork.request(for:discretionary:)` then keeps the same rules for expensive and constrained networks as the episode's audio had.
   - A cancellation (the task cancelled, or `FeedFetchError.cancelled`) stops at once and returns what it has; the caller's own `Task.checkCancellation()` then stops the download as it does today.
   - Nothing fetched is ever followed: no address inside a transcript or a chapters file (`img`, `url`) is opened.
5. **The chapters into the package.** `FeedEpisodeImporter.importEpisode` gains `chapters: PodcastChapters? = nil`, passed down to both the new book's import (`importBook`) and the restore of a kept package (`restoreBook`). In each, right after `stageFile` places the audio in the staged package and before `publishReadableBook` reads it, write `chapters.normalizedJSON()` to `TextMouthPaths.podcastChaptersPath(in: staging.directory)`, atomically. A failure to write logs one line, `FEED_CHAPTERS_NOT_KEPT: \(item.title): error \(code) in \(domain)`, and the import goes on without them. Reading the package then gives the episode the chapters as its headings when its audio has none of its own (the `chapters` task's `analyzeAudio`). An article (`importArticle`) gets none.
6. **In `downloadEpisode`** (`FeedDownloadManager.swift:698-770`): after the audio's transfer has ended and `try Task.checkCancellation()` has passed (`:754-758`), and after the file's name is known (`:762`), call `FeedEpisodeExtras.fetch(for:of:network: environment.network, discretionary: request.origin == .window)`, then `try Task.checkCancellation()` again; pass `fetched.chapters` to `importEpisode`. Both fetches happen while the download is still the download under way, so its progress still shows it, and a Cancel or a quit then stops it as one stops a download today.
7. **The transcript, once the book is listed.** After `importAndCommit` returns the book, when `fetched.transcript` is there, attach it before returning the book (so a reader that the download opens shows it at once):
   - run the work on the import queue with `runBesideImports` (so it never interleaves with a rule's removal of the episode's files), off the main thread: `TranscriptionPlan.make(for: book)`, `OutsideTranscript.transcript(bookTimeline: document.sentences, plan:, source: TranscriptSource(origin: .podcast, format: document.format))`, and `TranscriptStore.install(_:for: book, keepingExisting: true)`, returning a `Result`;
   - success: `library()?.feedTranscriptAttached(bookID: book.id, text: installation.text)` (item 8) and the line `FEED_TRANSCRIPT_ATTACHED: \(item.title) (\(feed.title)): \(format.name), \(wordCount) words`;
   - failure: the line `FEED_TRANSCRIPT_NOT_ATTACHED: \(item.title) (\(feed.title)): \(reason)` (`OutsideTranscriptError.alreadyTranscribed` included: an episode downloaded again keeps the transcript kept with it, which may be the listener's own or edited), and the book is returned as it is;
   - nothing in this step throws out of `downloadEpisode`.
8. `FeedLibraryHost` gains `func feedTranscriptAttached(bookID: UUID, text: TranscriptText)`, documented: the transcript fetched with an episode was saved into its package; the library row says "Transcribed" and an open reader shows the text. `LibraryViewModel`'s conformance: `TranscribedBooks.shared.record(bookID, isTranscribed: true)` and `bookUpdates.transcriptReplaced(bookID: bookID, with: text)`, as `TranscriptionJobCenter.saved` does. If a test stub conforms to `FeedLibraryHost` (grep `TextMouthProductionTests` for `FeedLibraryHost`), give it the requirement too.
9. **The log** (`DiagnosticLog.event(.feeds, ...)`), one line each, naming the episode and its feed as `FEED_DOWNLOAD_STARTED` does, and a server by its host alone (`FeedHost.of`), never an address, never a word of the transcript or a chapter's title:
   - `FEED_CHAPTERS_FETCHED: \(item.title) (\(feed.title)): \(n) chapters`
   - `FEED_CHAPTERS_REFUSED: \(item.title) (\(feed.title)): from \(host): \(reason)`
   - `FEED_TRANSCRIPT_FETCHED: \(item.title) (\(feed.title)): \(format.name), \(n) passages`
   - `FEED_TRANSCRIPT_REFUSED: \(item.title) (\(feed.title)): \(format.name) from \(host): \(reason)`
   - and item 7's two lines.
   A reason is short and plain: for a `FeedFetchError`, write a small `logReason(_:)` mapping each case ("not found (404)", "the server answered with error \(status)", "larger than the \(limit / 1024) KB TextMouth fetches", "timed out", "offline", "it needs a password", "gone (410)", "refused on a network with data limits", "not a web address", "the connection failed", "stopped"); for a `TimedTextError`, its `errorDescription`; for a `PodcastChaptersError`, its `description`.
10. No new setting, no new words a listener hears (the row's "Transcribed" note and the headings are the existing ones).

## Tests (FeedEpisodeExtrasTests)
- `transcriptFormat(of:)`: a table of every type of item 2, with parameters ("text/vtt; charset=utf-8"), letter case, and the extension fallback;
- `transcriptCandidates`: the order, duplicates, the cap of three, HTML and text left out;
- the end-to-end download, with a `FeedTestWorld` (`TextMouthProductionTests/FeedTestSupport.swift:439-700`; follow `FeedDownloadTests.testAnEpisodeBecomesAnAudiobookInTheFeedsFolder`, `:21-66`, and its `subscribe` at `:979-985`), an RSS feed you write by hand with `xmlns:podcast="https://podcastindex.org/namespace/1.0"`, one item whose enclosure is `FeedMediaFixtures.silentAAC(duration: 4)` served as audio/mp4, a `<podcast:transcript url="…/t.vtt" type="text/vtt"/>` serving the WebVTT sample's bytes (`copyOfFormatSample("vtt/tone4.vtt")`, served with `StubResponse(headers: ["Content-Type": "text/vtt"], body:)`), and a `<podcast:chapters url="…/c.json" type="application/json+chapters"/>` serving the chapters sample: the downloaded book's package holds `podcastChapters.json`; its index has the four chapters of the sample as its chapters; `TranscriptStore.read` finds a transcript whose source is podcast/webvtt with no file name; `TranscribedBooks.shared.contains(book.id)`; the FEED_CHAPTERS_FETCHED, FEED_TRANSCRIPT_FETCHED, and FEED_TRANSCRIPT_ATTACHED lines are written once each (count them before and after, as that test does);
- the transcript and the chapters both answering 404: the episode downloads as today (one chapter, no transcript.json), with the two REFUSED lines;
- a WebVTT link answering 404 and a JSON link after it serving the JSON sample: the transcript comes from JSON (source podcast/podcast-json);
- a transcript running past the end (a WebVTT whose last cue ends at 30 s, for the 4-second episode): no transcript.json, the NOT_ATTACHED line with the `runsPastTheEnd` sentence;
- only an HTML and a text transcript linked: neither is requested (`world.server.requests(to:)` is empty for both);
- `fetch` with a `transcriptLimit` of 100 bytes and a larger body: no transcript, a REFUSED line;
- a chapters file the reader refuses (not JSON): the episode keeps one chapter, a REFUSED line, and no `podcastChapters.json`;
- an episode downloaded again into its kept package that holds a transcript (find how `LibraryFeedDownloadReturnTests` or `FeedDownloadTests` makes a kept package; if no test helper does it in a few lines, call `TranscriptStore.install(_:for:keepingExisting: true)` on a package that has one, the unit this step relies on, and say so in your report): the kept transcript stays.

Run: `FeedEpisodeExtrasTests FeedDownloadTests FeedEndToEndTests LibraryFeedDownloadReturnTests FeedDownloadProgressEngineTests PodcastChaptersHeadingsTests OutsideTranscriptTests` (check each exists; `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped` is load-sensitive: a failure of it alone is rerun in its class alone, and both results reported).

## Not yours
A per-feed setting, Book Information, the reader. Do not change `TimedText.swift`, `OutsideTranscript.swift`, `TimedTextReader.swift`, or `PodcastChapters.swift` (ask the lead).
