import CryptoKit
import Foundation
import os

// MARK: - The Feed Engine's Connections (FR03)

/// The only network connections TextMouth makes (FR03): one session for
/// feeds and the web pages that name them, and one for the episodes and
/// articles they list.
///
/// Both are ephemeral: nothing they load is cached on disk, no cookie is
/// kept or sent, and each request carries TextMouth's own User-Agent. A
/// feed request gives up after 30 seconds without an answer, or two minutes
/// in all; a download, after 30 seconds without data, or a day in all.
/// Whether this Mac is online is asked of `NetworkReachability` before
/// anything is fetched, so a refresh asked for offline fails at once.
///
/// In a process hosting tests, the app's own sessions refuse every request
/// (`FeedNetworkRefusal`): only a test's stubbed network
/// (`stubbed(protocolClasses:reachability:)`) answers, so no test reaches
/// the network.
struct FeedNetwork: Sendable {
    /// Fetches feeds and web pages.
    let feedSession: URLSession
    /// Downloads episodes and articles' pages.
    let downloadSession: URLSession
    /// Whether this Mac can reach the network now.
    let reachability: NetworkReachability
    /// The User-Agent every request names.
    let userAgent: String

    /// How long a request may go without an answer.
    static let requestTimeout: TimeInterval = 30
    /// How long a feed's whole fetch may take.
    static let feedResourceTimeout: TimeInterval = 120
    /// How long a download's whole transfer may take.
    static let downloadResourceTimeout: TimeInterval = 24 * 3_600

    /// The app's network: the system's reachability, and, in a process
    /// hosting tests, sessions that refuse every request.
    static let app: FeedNetwork = {
        let refusing: [AnyClass] = TextMouthRuntime.current.isHostedTest ? [FeedNetworkRefusal.self] : []
        return FeedNetwork(protocolClasses: refusing, reachability: .system)
    }()

    /// A network whose requests `protocolClasses` answer, as a test's stub
    /// server does.
    static func stubbed(protocolClasses: [AnyClass], reachability: NetworkReachability = .online) -> FeedNetwork {
        FeedNetwork(protocolClasses: protocolClasses, reachability: reachability)
    }

    /// Sessions configured as the type describes, with `protocolClasses`
    /// tried before the system's own.
    private init(protocolClasses: [AnyClass], reachability: NetworkReachability) {
        feedSession = URLSession(configuration: Self.configuration(
            resourceTimeout: Self.feedResourceTimeout,
            protocolClasses: protocolClasses
        ))
        downloadSession = URLSession(configuration: Self.configuration(
            resourceTimeout: Self.downloadResourceTimeout,
            protocolClasses: protocolClasses
        ))
        self.reachability = reachability
        userAgent = Self.makeUserAgent()
    }

    /// An ephemeral configuration that caches nothing, keeps no cookies,
    /// fails at once without a connection, and gives up after
    /// `resourceTimeout` seconds in all.
    private static func configuration(resourceTimeout: TimeInterval, protocolClasses: [AnyClass]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return configuration
    }

    /// "TextMouth/<version>", naming the app to the servers it asks.
    private static func makeUserAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "TextMouth/\(version) (Macintosh; podcast and article reader)"
    }

    /// A GET request for `url` as this network sends it: TextMouth's
    /// User-Agent, and, for work the listener did not ask for, no expensive
    /// or constrained network (Low Data Mode, a phone's hotspot), as Apple
    /// advises for discretionary work.
    func request(for url: URL, discretionary: Bool) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.allowsExpensiveNetworkAccess = !discretionary
        request.allowsConstrainedNetworkAccess = !discretionary
        return request
    }
}

// MARK: - Refusing Requests in Tests

/// Refuses every request the app's own sessions make in a process hosting
/// tests, as if this Mac were offline, so a test that reaches the app's
/// network by mistake fails rather than reaching the network.
final class FeedNetworkRefusal: URLProtocol {
    /// Answers every request.
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    /// The request as it is.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Fails at once.
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    /// Nothing to stop.
    override func stopLoading() {}
}

// MARK: - Why a Fetch Failed

/// Why a feed or page could not be fetched (FR03), in sentences a listener
/// reads, naming the server by its host and never by the whole address,
/// which can carry a private feed's token.
enum FeedFetchError: Error, Equatable, Sendable {
    /// This Mac is offline.
    case offline
    /// No server answers at the host.
    case hostNotFound(host: String)
    /// The server did not answer in time.
    case timedOut(host: String)
    /// Nothing is at the address (404).
    case notFound
    /// The server asks for a password (401 or 403).
    case needsPassword
    /// The publisher removed the feed for good (410).
    case gone
    /// The server answered with another error status.
    case serverError(status: Int, host: String)
    /// The document is larger than TextMouth reads.
    case tooLarge(host: String)
    /// The connection failed for another reason, in the system's words.
    case connectionFailed(host: String, reason: String)
    /// The address or a redirect led somewhere other than an http or https
    /// address.
    case notAWebAddress
    /// A refresh the listener did not ask for was refused on an expensive or
    /// constrained network, and waits for its next turn.
    case constrainedNetwork
    /// The fetch was cancelled.
    case cancelled

    /// The sentence the library shows and VoiceOver speaks about a feed
    /// named `name` (its title, or its host).
    func message(about name: String) -> String {
        switch self {
        case .offline:
            return "This Mac is offline, so \(name) can't be refreshed. Connect to the internet and try again."
        case .hostNotFound(let host):
            return "The server \(host) couldn't be found. Check the address."
        case .timedOut(let host):
            return "\(host) didn't answer for \(Int(FeedNetwork.requestTimeout)) seconds."
        case .notFound:
            return "There's no feed at that address any more."
        case .needsPassword:
            return "This feed needs a password, which TextMouth can't send yet."
        case .gone:
            return "The publisher has removed this feed."
        case .serverError(let status, let host):
            return "\(host) couldn't send the feed (error \(status)). Try again later."
        case .tooLarge(let host):
            let megabytes = FeedParser.maximumBytes / 1_048_576
            return "The feed at \(host) is larger than the \(megabytes) MB TextMouth reads."
        case .connectionFailed(let host, let reason):
            return "\(host) couldn't be reached: \(reason)"
        case .notAWebAddress:
            return "That address isn't a web address TextMouth can open."
        case .constrainedNetwork:
            return "\(name) waits for a network without data limits to refresh by itself."
        case .cancelled:
            return "The refresh of \(name) was stopped."
        }
    }

    /// The error for a failure `URLSession` reported while reaching `host`.
    static func from(_ error: Error, host: String) -> FeedFetchError {
        if let fetchError = error as? FeedFetchError {
            return fetchError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let urlError = error as? URLError else {
            return .connectionFailed(host: host, reason: error.localizedDescription)
        }
        if urlError.networkUnavailableReason != nil {
            return .constrainedNetwork
        }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound(host: host)
        case .timedOut:
            return .timedOut(host: host)
        case .cancelled:
            return .cancelled
        case .unsupportedURL, .badURL:
            return .notAWebAddress
        default:
            return .connectionFailed(host: host, reason: urlError.localizedDescription)
        }
    }

    /// The error a final HTTP status means, or nil for a success.
    static func from(status: Int, host: String) -> FeedFetchError? {
        switch status {
        case 200...299: return nil
        case 401, 403: return .needsPassword
        case 404: return .notFound
        case 410: return .gone
        default: return .serverError(status: status, host: host)
        }
    }
}

/// The host a sentence or log line names for `url`: its host alone, never
/// its path or query, which can carry a private feed's token.
enum FeedHost {
    /// `url`'s host, or "the server" when it has none.
    static func of(_ url: URL) -> String {
        url.host ?? "the server"
    }
}

// MARK: - Fetching

/// What fetching an address found.
enum FeedFetchResult: Sendable {
    /// The server says the document has not changed since the validators
    /// sent (304 Not Modified), at the address every redirect led to when
    /// all were permanent.
    case notModified(permanentURL: URL?)
    /// The document, with what the server said about it.
    case body(FeedFetchedBody)
}

/// A document fetched, with what the server said about it.
struct FeedFetchedBody: Sendable {
    /// The document's bytes.
    var data: Data
    /// The address it came from, after any redirects.
    var finalURL: URL
    /// The address to keep from now on, when every redirect on the way was
    /// permanent (301 or 308), which lets a client replace the address it
    /// had; nil when there was none, or any was temporary.
    var permanentURL: URL?
    /// The ETag the server sent.
    var etag: String?
    /// The Last-Modified date the server sent, as it wrote it.
    var lastModified: String?
    /// The MIME type the server gave the document.
    var mimeType: String?
    /// The text encoding the server named for it.
    var textEncodingName: String?

    /// The SHA-256 digest of the document, in hexadecimal.
    var digest: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The document as text, in the encoding the server named, or UTF-8,
    /// with any byte that is not text replaced: for reading a web page.
    var text: String {
        if let name = textEncodingName {
            let named = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if named != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(named))) {
                return decoded
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension FeedNetwork {
    /// Fetches the document at `url` with `feedSession`, sending the
    /// validators given, so an unchanged document comes back as
    /// `.notModified`. The body is read up to `limit` bytes; redirects are
    /// followed to http and https addresses only.
    /// - Throws: `FeedFetchError`.
    func fetch(
        _ url: URL,
        etag: String? = nil,
        lastModified: String? = nil,
        discretionary: Bool,
        limit: Int = FeedParser.maximumBytes
    ) async throws -> FeedFetchResult {
        let host = FeedHost.of(url)
        guard FeedTransport.isWebAddress(url) else { throw FeedFetchError.notAWebAddress }
        guard reachability.isOnline() else { throw FeedFetchError.offline }
        var request = request(for: url, discretionary: discretionary)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let task = feedSession.dataTask(with: request)
        let outcome: FeedDataTaskOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FeedDataTaskOutcome, Error>) in
                    task.delegate = FeedDataTaskDelegate(limit: limit, continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw FeedFetchError.from(error, host: host)
        }

        guard let response = outcome.response else {
            throw FeedFetchError.connectionFailed(host: host, reason: "the server sent no answer")
        }
        let finalHost = response.url.map(FeedHost.of) ?? host
        let finalURL = response.url ?? url
        let allPermanent = !outcome.redirects.isEmpty && outcome.redirects.allSatisfy { [301, 308].contains($0) }
        if response.statusCode == 304, etag != nil || lastModified != nil {
            return .notModified(permanentURL: allPermanent ? finalURL : nil)
        }
        if let failure = FeedFetchError.from(status: response.statusCode, host: finalHost) {
            throw failure
        }
        return .body(FeedFetchedBody(
            data: outcome.data,
            finalURL: finalURL,
            permanentURL: allPermanent ? finalURL : nil,
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            mimeType: response.mimeType,
            textEncodingName: response.textEncodingName
        ))
    }
}

/// What one data task produced.
struct FeedDataTaskOutcome: Sendable {
    /// The final response.
    var response: HTTPURLResponse?
    /// The body, up to the limit.
    var data: Data
    /// The status of each redirect followed, in order.
    var redirects: [Int]
}

/// One data task's delegate: it collects the body up to a limit, follows
/// redirects only to http and https addresses, notes each redirect's
/// status, and resumes the fetch that waits for it once, when the task
/// completes.
///
/// Every stored property is a constant: what the task reports is kept in
/// `state`, behind an unfair lock, since URLSession calls the delegate on a
/// queue of its own.
private final class FeedDataTaskDelegate: NSObject, URLSessionDataDelegate {
    /// What the task has reported so far.
    private struct State {
        var data = Data()
        var redirects: [Int] = []
        var exceededLimit = false
    }

    /// The most bytes of body read.
    private let limit: Int
    /// The fetch waiting for the task.
    private let continuation: CheckedContinuation<FeedDataTaskOutcome, Error>
    /// What the task has reported, guarded by its lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A delegate reading at most `limit` bytes, resuming `continuation`.
    init(limit: Int, continuation: CheckedContinuation<FeedDataTaskOutcome, Error>) {
        self.limit = limit
        self.continuation = continuation
    }

    /// Refuses a body declared larger than the limit before any of it comes.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(limit) {
            state.withLock { $0.exceededLimit = true }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    /// Keeps each part of the body, stopping the task once it passes the limit.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = state.withLock { state -> Bool in
            state.data.append(data)
            if state.data.count > limit {
                state.exceededLimit = true
                state.data = Data()
            }
            return state.exceededLimit
        }
        if exceeded {
            dataTask.cancel()
        }
    }

    /// Follows a redirect only to an http or https address, noting its status.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, FeedTransport.isWebAddress(url) else {
            completionHandler(nil)
            return
        }
        state.withLock { $0.redirects.append(response.statusCode) }
        completionHandler(request)
    }

    /// Resumes the fetch with what the task produced, or why it failed.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = state.withLock { $0 }
        let host = task.originalRequest?.url.map(FeedHost.of) ?? "the server"
        if finished.exceededLimit {
            continuation.resume(throwing: FeedFetchError.tooLarge(host: host))
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: FeedDataTaskOutcome(
                response: task.response as? HTTPURLResponse,
                data: finished.data,
                redirects: finished.redirects
            ))
        }
    }
}
