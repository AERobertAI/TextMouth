import Foundation

// MARK: - A Podcast a Search Found (FR03)

/// One podcast a directory search found (FR03): what Add Feed's list of
/// results says of it, and the feed its Subscribe button subscribes to.
struct FeedDirectoryResult: Equatable, Identifiable, Sendable {
    /// The podcast's title.
    var title: String
    /// Who publishes it, when the directory says.
    var author: String?
    /// How many episodes the directory counts, when it gives a number above 0.
    var episodeCount: Int?
    /// The podcast's feed, which Subscribe subscribes to.
    var feedURL: URL

    /// A result is known by its feed, which a search lists once.
    var id: String {
        feedURL.absoluteString
    }
}

// MARK: - Why a Search Failed

/// Why a directory search failed (FR03), in sentences a listener reads,
/// naming the directory by its host alone.
enum FeedSearchError: Error, Equatable, Sendable {
    /// The search could not be sent, or its answer did not come.
    case fetch(FeedFetchError)
    /// The directory answered with something other than a list of results.
    case unreadableAnswer

    /// The sentence the Add Feed sheet shows and VoiceOver speaks.
    var message: String {
        switch self {
        case .fetch(let error):
            return error.searchMessage
        case .unreadableAnswer:
            return "The podcast directory sent an answer TextMouth can't read. Try again later."
        }
    }
}

extension FeedFetchError {
    /// The sentence about a directory search that failed this way. Apple's
    /// directory refuses searches past about 20 a minute, with 403 (which
    /// reads as a password asked for) or 429.
    var searchMessage: String {
        switch self {
        case .offline:
            return "This Mac is offline, so the podcast directory can't be searched. Connect to the internet and try again."
        case .hostNotFound(let host):
            return "The podcast directory at \(host) couldn't be found."
        case .timedOut(let host):
            return "The podcast directory at \(host) didn't answer for \(Int(FeedNetwork.requestTimeout)) seconds."
        case .needsPassword, .serverError(status: 429, host: _):
            return "The podcast directory refused the search. It allows about 20 searches a minute, so wait a minute and try again."
        case .serverError(let status, let host):
            return "The podcast directory at \(host) couldn't answer the search (error \(status)). Try again later."
        case .notFound, .gone:
            return "The podcast directory couldn't answer the search. Try again later."
        case .tooLarge:
            return "The podcast directory's answer is larger than TextMouth reads."
        case .connectionFailed(let host, let reason):
            return "The podcast directory at \(host) couldn't be reached: \(reason)"
        case .notAWebAddress:
            return "The search couldn't be sent, because the directory's address isn't a web address."
        case .constrainedNetwork:
            return "The podcast directory can't be searched on this network, which limits data."
        case .cancelled:
            return "The search was stopped."
        }
    }
}

// MARK: - Searching

/// Where Add Feed searches for podcasts (FR03): Apple's iTunes Search API,
/// which takes a term and the podcast media type, needs no key, and allows
/// about 20 searches a minute.
///
/// A search asks for podcasts alone, at most `resultLimit` of them, and
/// keeps a result only when it names a feed TextMouth can fetch, since
/// Subscribe needs one; each feed is listed once. It goes through the feed
/// engine's own connections (`FeedNetwork`) as the listener's request, on
/// any network, so in a process hosting tests only a test's stub server
/// answers it.
struct FeedDirectory: Equatable, Sendable {
    /// The search address's scheme.
    let scheme: String
    /// The search address's host.
    let host: String
    /// The search address's path; each search adds its own query.
    let path: String

    /// Apple's directory, at https://itunes.apple.com/search.
    static let apple = FeedDirectory(scheme: "https", host: "itunes.apple.com", path: "/search")

    /// The most results one search asks for: as many as a listener reads
    /// through, under the 200 Apple allows.
    static let resultLimit = 50
    /// The largest answer read: fifty results take about 100 KB.
    static let maximumBytes = 4 * 1_024 * 1_024

    /// A directory searched at `scheme`://`host``path`.
    init(scheme: String, host: String, path: String) {
        self.scheme = scheme
        self.host = host
        self.path = path
    }

    /// A directory searched at `url`, as a test's stub server answers.
    init(searchingAt url: URL) {
        self.init(scheme: url.scheme ?? "https", host: url.host ?? "", path: url.path)
    }

    /// The address a search for `term` asks: podcasts alone, at most
    /// `resultLimit`, with every character of the term but letters, digits,
    /// and "-._~" percent-encoded, so an "&" or a "+" in it is searched for
    /// rather than read as part of the address.
    func searchURL(for term: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        let parameters = [
            ("media", "podcast"),
            ("entity", "podcast"),
            ("limit", String(Self.resultLimit)),
            ("term", term),
        ]
        components.percentEncodedQuery = parameters
            .map { name, value in "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "")" }
            .joined(separator: "&")
        return components.url
    }

    /// The characters a query value keeps as they are: RFC 3986's
    /// unreserved characters, ASCII alone.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Searches the directory for podcasts matching `term` through
    /// `network`, and returns those it found that name a feed, in its order.
    /// - Throws: `FeedSearchError`.
    func search(_ term: String, through network: FeedNetwork) async throws -> [FeedDirectoryResult] {
        guard let url = searchURL(for: term) else { throw FeedSearchError.fetch(.notAWebAddress) }
        let fetched: FeedFetchResult
        do {
            fetched = try await network.fetch(url, discretionary: false, limit: Self.maximumBytes)
        } catch {
            throw FeedSearchError.fetch(FeedFetchError.from(error, host: FeedHost.of(url)))
        }
        // Nothing was sent that a server could answer "not modified" to.
        guard case .body(let body) = fetched else { throw FeedSearchError.unreadableAnswer }
        let found = await OffMainWork.run { Self.results(in: body.data) }
        guard let found else { throw FeedSearchError.unreadableAnswer }
        DiagnosticLog.trace(.feeds, "a podcast directory search at \(FeedHost.of(url)) found \(found.count) result(s)")
        return found
    }

    /// The podcasts the directory's answer `data` lists that name a feed
    /// TextMouth can fetch, each feed once, in the answer's order; nil when
    /// `data` is no answer of a directory's.
    ///
    /// A result's title is its collection's name (or its track's), its
    /// author the artist's name, and its episode count the track count.
    static func results(in data: Data) -> [FeedDirectoryResult]? {
        guard let answer = FeedJSON.object(in: data), answer["results"] is [Any] else { return nil }
        var results: [FeedDirectoryResult] = []
        var seen = Set<String>()
        for entry in FeedJSON.objects(answer["results"]) {
            guard let address = FeedJSON.string(entry["feedUrl"]),
                  let feedURL = URL(string: address),
                  FeedTransport.isWebAddress(feedURL),
                  seen.insert(FeedAddress.comparisonKey(feedURL)).inserted else { continue }
            let title = FeedJSON.string(entry["collectionName"]) ?? FeedJSON.string(entry["trackName"])
            results.append(FeedDirectoryResult(
                title: title ?? feedURL.host ?? address,
                author: FeedJSON.string(entry["artistName"]),
                episodeCount: FeedJSON.integer(entry["trackCount"]).flatMap { $0 > 0 ? $0 : nil },
                feedURL: feedURL
            ))
        }
        return results
    }
}
