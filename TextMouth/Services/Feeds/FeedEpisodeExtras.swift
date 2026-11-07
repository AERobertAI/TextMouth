import Foundation

// MARK: - A Podcast Episode's Own Transcript and Chapters (FMT25)

/// A podcast episode's own transcript and chapters (FMT25): the files its
/// feed links beside the episode's audio, Podcasting 2.0's
/// `podcast:transcript` and `podcast:chapters` (kept on the item as
/// `FeedItem.transcripts` and `FeedItem.chapters`), fetched once the audio
/// has downloaded, for every feed, so a downloaded episode has text and
/// headings at once.
///
/// Each file is fetched as the episode's audio was, under the download's
/// own network rules (`FeedNetwork.fetch`): no cookie is sent, redirects are
/// followed to http and https addresses only, and the body is read up to a
/// limit, 1 MB for chapters and 5 MB for a transcript (`TimedTextLimits`).
/// What comes back is third-party data: it is read by the readers that bound
/// every size and count it holds, nothing that does not read is used, and no
/// address inside it, such as a chapter's picture or link, is ever opened.
///
/// Nothing here can stop or fail the episode's own download: a file that
/// cannot be fetched or read is left out, with one line in the debug log
/// naming the episode, its feed, the server by its host alone, and why,
/// never a word of the file. The download puts the chapters into the
/// episode's package before it is read (`FeedEpisodeImporter`), and makes
/// the transcript the episode's once its book is listed (`attach(_:to:)`).
enum FeedEpisodeExtras {
    /// What a download fetched beside the episode's audio.
    struct Fetched: Sendable, Equatable {
        /// The episode's chapters, when its feed links a chapters file that
        /// could be fetched and read.
        var chapters: PodcastChapters?
        /// The episode's transcript, from the first of its transcript links
        /// that could be fetched and read (`transcriptCandidates(of:)`).
        var transcript: TimedTextDocument?
    }

    /// The most transcript links tried for one episode, so a feed listing
    /// many cannot keep a download fetching.
    static let maximumTranscriptTries = 3

    /// The longest an episode's files may hold up its download: the two
    /// minutes one feed's whole fetch may take (`FeedNetwork`). The episode's
    /// audio is here already, waiting to be added to the library, and each
    /// file's own time limit would let a slow server hold it for eight
    /// minutes. A file not fetched by then is left out, as one that fails is.
    static let timeLimit: Duration = .seconds(FeedNetwork.feedResourceTimeout)

    // MARK: Choosing the Transcript

    /// The transcript formats in the order an episode's links are tried
    /// (the charter's decision 3): WebVTT, the format Podcasting 2.0
    /// recommends first, then Podcasting 2.0's own JSON, then SubRip.
    private static let preferredFormats: [TimedTextFormat] = [.webVTT, .podcastJSON, .subRip]

    /// The transcript formats by the MIME types that name them, lowercased
    /// and without parameters.
    private static let formatsByMediaType: [String: TimedTextFormat] = [
        "text/vtt": .webVTT,
        "application/json": .podcastJSON,
        "application/x-subrip": .subRip,
        "application/srt": .subRip,
        "application/x-srt": .subRip,
        "text/srt": .subRip,
        "text/x-srt": .subRip,
    ]

    /// The MIME types of transcripts that time nothing, an HTML page and
    /// plain text, which are never fetched (the charter's decision 3).
    private static let untimedMediaTypes: Set<String> = ["text/html", "text/plain"]

    /// The format of the transcript `resource` links, or nil when it is not
    /// one TextMouth reads.
    ///
    /// Its MIME type decides first, in any letter case and with any
    /// parameters ("text/vtt; charset=utf-8" is WebVTT): "text/vtt" is
    /// WebVTT, "application/json" Podcasting 2.0 JSON, and SubRip's several
    /// types SubRip; "text/html" and "text/plain", which carry no times, are
    /// nil, so they are never fetched. A link without a type, or with any
    /// other, is known by its address's extension: "vtt", "json", or "srt",
    /// in any letter case; nil for any other.
    static func transcriptFormat(of resource: FeedResource) -> TimedTextFormat? {
        let mediaType = mediaType(of: resource.mimeType)
        if let format = formatsByMediaType[mediaType] {
            return format
        }
        guard !untimedMediaTypes.contains(mediaType) else { return nil }
        let fileExtension = resource.url.pathExtension.lowercased()
        return preferredFormats.first { $0.fileExtension == fileExtension }
    }

    /// `mimeType` as a media type alone: lowercased, without its parameters
    /// (whatever follows its first ";") and without white space, so
    /// " Text/VTT ; charset=utf-8" is "text/vtt"; "" for none.
    private static func mediaType(of mimeType: String?) -> String {
        let essence = mimeType?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(essence.lowercased().filter { !$0.isWhitespace })
    }

    /// The transcript links of `item` worth fetching, in the order they are
    /// tried: every link whose format TextMouth reads
    /// (`transcriptFormat(of:)`), WebVTT first, then Podcasting 2.0 JSON,
    /// then SubRip (the charter's decision 3), each format's links in the
    /// feed's order; each address once, in the place its first link in that
    /// order gives it; and at most `maximumTranscriptTries` of them.
    static func transcriptCandidates(of item: FeedItem) -> [(url: URL, format: TimedTextFormat)] {
        let readable = (item.transcripts ?? []).compactMap { resource in
            transcriptFormat(of: resource).map { (url: resource.url, format: $0) }
        }
        var seen = Set<URL>()
        var candidates: [(url: URL, format: TimedTextFormat)] = []
        for format in preferredFormats {
            for link in readable where link.format == format {
                // An address listed again, under this format or another,
                // is tried once, as its first listing in this order says.
                guard seen.insert(link.url).inserted else { continue }
                candidates.append(link)
                guard candidates.count < maximumTranscriptTries else { return candidates }
            }
        }
        return candidates
    }

    // MARK: Fetching

    /// Fetches and reads the chapters file and the transcript that `item`,
    /// an episode of `feed`, links, with `network`, as its download fetches:
    /// `discretionary` is the download's own, so the episode's audio and its
    /// files keep the same rules for networks with data limits
    /// (`FeedNetwork.request(for:discretionary:)`). Each body is read up to
    /// its limit: `chaptersLimit` bytes for the chapters, `transcriptLimit`
    /// for a transcript.
    ///
    /// The chapters come first, when the item links a chapters file, read
    /// with `PodcastChapters.read`. Then each of the item's transcript links
    /// (`transcriptCandidates(of:)`) is fetched in turn and read in its
    /// format (`TimedTextReader.read(_:as:)`), until one reads. A file that
    /// cannot be fetched or read is left out, with one line in the debug
    /// log, and the next transcript link is tried.
    ///
    /// Never throws: returns what it could use. A cancellation, of the task
    /// or of a fetch, stops at once and returns what it has; the download's
    /// own check of its task then stops the download. So does `timeLimit`
    /// running out, with one line in the debug log, but the download goes on:
    /// a file that keeps its server's connection open by sending a byte now
    /// and then, which no fetch's own limit stops soon, never holds an
    /// episode up for long.
    static func fetch(
        for item: FeedItem,
        of feed: Feed,
        network: FeedNetwork,
        discretionary: Bool,
        transcriptLimit: Int = TimedTextLimits.podcastTranscriptBytes,
        chaptersLimit: Int = TimedTextLimits.podcastChaptersBytes,
        timeLimit: Duration = FeedEpisodeExtras.timeLimit
    ) async -> Fetched {
        // Most episodes link nothing, and have nothing to wait for.
        guard item.chapters != nil || !transcriptCandidates(of: item).isEmpty else { return Fetched() }
        return await withTaskGroup(of: Fetched?.self) { group in
            group.addTask {
                await fetchFiles(
                    for: item, of: feed, network: network, discretionary: discretionary,
                    transcriptLimit: transcriptLimit, chaptersLimit: chaptersLimit
                )
            }
            group.addTask {
                // Cancelled, as it is once the files have come, it says nothing.
                guard (try? await Task.sleep(for: timeLimit)) != nil else { return nil }
                DiagnosticLog.event(
                    .feeds,
                    "FEED_EPISODE_FILES_TIMED_OUT: \(item.title) (\(feed.title)): "
                        + "still fetching after \(timeLimit.components.seconds) seconds, so the rest are left out"
                )
                return nil
            }
            // Whichever ends first stops the other. Stopped, the fetching
            // returns what it has, and only the fetching returns anything.
            var fetched = Fetched()
            for await result in group {
                if let result {
                    fetched = result
                }
                group.cancelAll()
            }
            return fetched
        }
    }

    /// The fetching of `fetch(for:of:network:discretionary:transcriptLimit:chaptersLimit:timeLimit:)`,
    /// which says what it does, without its limit on the whole.
    private static func fetchFiles(
        for item: FeedItem,
        of feed: Feed,
        network: FeedNetwork,
        discretionary: Bool,
        transcriptLimit: Int,
        chaptersLimit: Int
    ) async -> Fetched {
        // The episode as every line about its download names it, by its
        // title and its feed's (FEED_DOWNLOAD_STARTED).
        let episode = "\(item.title) (\(feed.title))"
        var fetched = Fetched()

        if let link = item.chapters {
            let host = FeedHost.of(link.url)
            switch await body(at: link.url, network: network, discretionary: discretionary, limit: chaptersLimit) {
            case .stopped:
                return fetched
            case .refused(let reason):
                DiagnosticLog.event(.feeds, "FEED_CHAPTERS_REFUSED: \(episode): from \(host): \(reason)")
            case .fetched(let data):
                do {
                    let chapters = try PodcastChapters.read(data)
                    fetched.chapters = chapters
                    let count = CountWording.phrase(chapters.chapters.count, singular: "chapter", plural: "chapters")
                    DiagnosticLog.event(.feeds, "FEED_CHAPTERS_FETCHED: \(episode): \(count)")
                } catch {
                    DiagnosticLog.event(.feeds, "FEED_CHAPTERS_REFUSED: \(episode): from \(host): \(logReason(of: error))")
                }
            }
        }

        for link in transcriptCandidates(of: item) {
            let host = FeedHost.of(link.url)
            let format = link.format.name
            switch await body(at: link.url, network: network, discretionary: discretionary, limit: transcriptLimit) {
            case .stopped:
                return fetched
            case .refused(let reason):
                DiagnosticLog.event(.feeds, "FEED_TRANSCRIPT_REFUSED: \(episode): \(format) from \(host): \(reason)")
            case .fetched(let data):
                do {
                    let document = try TimedTextReader.read(data, as: link.format)
                    fetched.transcript = document
                    let count = CountWording.phrase(document.cues.count, singular: "passage", plural: "passages")
                    DiagnosticLog.event(.feeds, "FEED_TRANSCRIPT_FETCHED: \(episode): \(format), \(count)")
                    return fetched
                } catch {
                    DiagnosticLog.event(.feeds, "FEED_TRANSCRIPT_REFUSED: \(episode): \(format) from \(host): \(logReason(of: error))")
                }
            }
        }
        return fetched
    }

    /// How one fetch of a file beside an episode ended.
    private enum Outcome {
        /// The file's bytes, all of them, within the fetch's limit.
        case fetched(Data)
        /// The network or the server refused the file, for the reason given
        /// (`logReason(_:limit:)`).
        case refused(String)
        /// The download was stopped: nothing more is fetched.
        case stopped
    }

    /// The bytes at `url`, fetched with `network` under the download's own
    /// `discretionary` rules and read up to `limit` bytes; nothing at all
    /// once the download was stopped, before or during the fetch.
    private static func body(at url: URL, network: FeedNetwork, discretionary: Bool, limit: Int) async -> Outcome {
        // A download stopped already asks for nothing more.
        guard !Task.isCancelled else { return .stopped }
        let failure: FeedFetchError
        do {
            switch try await network.fetch(url, discretionary: discretionary, limit: limit) {
            case .body(let body):
                return .fetched(body.data)
            case .notModified:
                // An answer only to validators, which are never sent here.
                failure = .serverError(status: 304, host: FeedHost.of(url))
            }
        } catch {
            failure = FeedFetchError.from(error, host: FeedHost.of(url))
        }
        // A fetch the download's stop interrupted may fail some other way
        // than as cancelled: it stops all the same.
        return failure == .cancelled || Task.isCancelled ? .stopped : .refused(logReason(failure, limit: limit))
    }

    // MARK: Attaching the Transcript

    /// What attaching a fetched transcript to its episode saved.
    struct Attached: Sendable {
        /// What the install saved, the text an open reader shows among it.
        let installation: TranscriptInstallation
        /// How many words the transcript holds (`Transcript.wordCount`).
        let wordCount: Int
    }

    /// Makes `document`, the transcript fetched with the episode `book`, the
    /// book's transcript, as Attach Transcript… makes a file's: timed on the
    /// book's timeline, which is the episode's audio
    /// (`OutsideTranscript.transcript(bookTimeline:plan:source:now:hasher:)`),
    /// recording that it is the podcast's own, in its format, with no file
    /// name (`TranscriptSource`), and saved in the book's package with its
    /// text (`TranscriptStore.install`).
    ///
    /// A transcript the book has already is kept: an episode downloaded again
    /// into the package kept for it keeps the transcript kept with it, which
    /// may be the listener's own or an edited one. Only the podcast's own,
    /// as an earlier download brought it, gives way, the listener having
    /// made and changed nothing in it
    /// (`TranscriptStore.holdsUntouchedPodcastTranscript(in:)`): a host that
    /// inserts other advertisements into each download makes a new file of
    /// each, for which the earlier transcript is stale, and shows no text,
    /// while the one just fetched was made for it.
    ///
    /// Measures, fingerprints, and writes the book's files, so it blocks:
    /// the download runs it on the import queue
    /// (`FeedDownloadManager.runBesideImports`), off the main thread.
    /// - Throws: `OutsideTranscriptError.alreadyTranscribed` for a book with
    ///   a transcript to keep, `.runsPastTheEnd` for a transcript made for
    ///   longer audio, and whatever else `TranscriptionPlan.make(for:)`,
    ///   `OutsideTranscript`, and `TranscriptStore.install` throw.
    static func attach(_ document: TimedTextDocument, to book: Book) throws -> Attached {
        let replacesItsOwn = TranscriptStore.holdsUntouchedPodcastTranscript(in: book.tmbDirectory)
        // Before the audio is measured and fingerprinted, which reads the
        // whole of it, for a transcript that would only be turned away.
        guard replacesItsOwn || !TranscriptStore.hasTranscript(of: book) else {
            throw OutsideTranscriptError.alreadyTranscribed
        }
        let plan = try TranscriptionPlan.make(for: book)
        let transcript = try OutsideTranscript.transcript(
            bookTimeline: document.sentences,
            plan: plan,
            source: TranscriptSource(origin: .podcast, format: document.format)
        )
        let installation = try TranscriptStore.install(transcript, for: book, keepingExisting: !replacesItsOwn)
        return Attached(installation: installation, wordCount: transcript.wordCount)
    }

    // MARK: Reasons, for the Log

    /// Why a fetch that failed with `error` was refused, short and plain,
    /// for the debug log; `limit` is the fetch's limit in bytes, which a file
    /// too large passed. It names no address: the line names the server by
    /// its host.
    static func logReason(_ error: FeedFetchError, limit: Int) -> String {
        switch error {
        case .notFound:
            return "not found (404)"
        case .serverError(let status, _):
            return "the server answered with error \(status)"
        case .tooLarge:
            return "larger than the \(limit / 1024) KB TextMouth fetches"
        case .timedOut:
            return "timed out"
        case .offline:
            return "offline"
        case .needsPassword:
            return "it needs a password"
        case .gone:
            return "gone (410)"
        case .constrainedNetwork:
            return "refused on a network with data limits"
        case .notAWebAddress:
            return "not a web address"
        case .hostNotFound, .connectionFailed:
            return "the connection failed"
        case .cancelled:
            return "stopped"
        }
    }

    /// Why reading a fetched file, or attaching the transcript read from
    /// one, failed with `error`, for the debug log: TextMouth's own words
    /// for its own errors, which never quote the file or name a path (a
    /// chapters file's reason, a timed-text file's, a transcript's that
    /// does not fit, a transcription's, or a transcript text's), and any
    /// other error by its code and domain, since its own words can name a
    /// package's folder by its absolute path.
    static func logReason(of error: any Error) -> String {
        switch error {
        case let error as PodcastChaptersError:
            return error.description
        case let error as TranscriptTextError:
            return error.logDescription
        case let error as TimedTextError:
            return error.localizedDescription
        case let error as OutsideTranscriptError:
            return error.localizedDescription
        case let error as TranscriptionError:
            return error.localizedDescription
        default:
            let failure = error as NSError
            return "error \(failure.code) in \(failure.domain)"
        }
    }
}
