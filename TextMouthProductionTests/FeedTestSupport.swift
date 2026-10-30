import AVFoundation
import Foundation
import os
import XCTest
@testable import TextMouth

// MARK: - FR03 Feed Test Support
//
// A web server of each test's own, reached only through `FeedStubProtocol`,
// so no test reaches the network; a feed engine wired to it, a sandboxed
// preferences store, a clock and a sleep the test moves by hand, and a
// library of its own; and small feed documents written to order.

// MARK: - A Stub Web Server

/// One answer a stub server gives.
struct StubResponse: Sendable {
    /// The HTTP status.
    var status = 200
    /// The response's headers. A body's Content-Length is added unless given.
    var headers: [String: String] = [:]
    /// The body.
    var body = Data()
    /// The size of the parts the body is sent in, for a download whose
    /// progress a test follows; nil sends it whole.
    var chunkSize: Int?
    /// The pause before each part, and before the response itself.
    var pause: TimeInterval = 0
    /// A failure before any answer, such as a host not found.
    var failure: URLError.Code?
    /// Why the network refused the request, given with `failure`, as the
    /// system says when a request that may not use an expensive or
    /// constrained network meets one.
    var unavailableReason: URLError.NetworkUnavailableReason?
    /// A failure after this many bytes of the body, as a connection that
    /// drops partway.
    var failAfterBytes: Int?
    /// The gate the failure after `failAfterBytes` waits at, on a background
    /// queue, before it is told to the client: a test opens it once the app
    /// has written the bytes before the failure, so the dropped connection
    /// cannot overtake them, as a real connection's bytes arrive before it
    /// drops. Nil tells the failure at once.
    var failureGate: WorkGate?

    /// A response of `status` whose body is `body`.
    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The fixture `name` in TestData/feeds, as an RSS document.
    static func fixture(_ name: String, headers: [String: String] = ["Content-Type": "application/rss+xml"]) throws -> StubResponse {
        StubResponse(headers: headers, body: try Data(contentsOf: try requireFile("feeds/\(name)")))
    }

    /// The podcast directory's saved answer `name` in TestData/feeds, as
    /// Apple's directory serves it (text/javascript), with the feeds it
    /// names moved from feeds.example to `server`, so subscribing to a
    /// result reaches the stub server too.
    static func directoryAnswer(_ name: String, feedsOn server: FeedStubServer) throws -> StubResponse {
        let saved = try String(contentsOf: try requireFile("feeds/\(name)"), encoding: .utf8)
        let moved = saved.replacingOccurrences(of: "feeds.example", with: server.host)
        return StubResponse(headers: ["Content-Type": "text/javascript; charset=utf-8"], body: Data(moved.utf8))
    }

    /// A JSON Feed 1.1 titled `title` listing `items` in order, as a server
    /// serves one (application/feed+json): each item's guid is its id, its
    /// date its date_published, its enclosure an attachment, its
    /// description its content_html, and its link its url.
    static func jsonFeed(title: String = "The Tactile Atlas", items: [FeedXML.Item]) throws -> StubResponse {
        let dates = ISO8601DateFormatter()
        let entries: [[String: Any]] = items.map { item in
            var entry: [String: Any] = ["title": item.title]
            entry["id"] = item.guid
            entry["date_published"] = item.published.map(dates.string(from:))
            entry["content_html"] = item.description
            entry["url"] = item.link
            if let enclosure = item.enclosure {
                entry["attachments"] = [["url": enclosure, "mime_type": item.enclosureType, "size_in_bytes": item.enclosureLength]]
            }
            return entry
        }
        let document: [String: Any] = [
            "version": "https://jsonfeed.org/version/1.1",
            "title": title,
            "home_page_url": "https://show.example/",
            "items": entries,
        ]
        let body = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return StubResponse(headers: ["Content-Type": "application/feed+json"], body: body)
    }

    /// A feed document built by `FeedXML`.
    static func feed(_ markup: String, headers: [String: String] = [:]) -> StubResponse {
        var allHeaders = ["Content-Type": "application/rss+xml; charset=utf-8"]
        allHeaders.merge(headers) { _, given in given }
        return StubResponse(headers: allHeaders, body: Data(markup.utf8))
    }

    /// A failure before any answer.
    static func failing(_ code: URLError.Code) -> StubResponse {
        var response = StubResponse()
        response.failure = code
        return response
    }

    /// The refusal a request that may not use an expensive network meets on
    /// one, such as a phone's hotspot: the system fails it at once, saying
    /// why.
    static func refusedOnAMeteredNetwork() -> StubResponse {
        var response = failing(.notConnectedToInternet)
        response.unavailableReason = .expensive
        return response
    }

    /// A redirect of `status` to `location`.
    static func redirect(_ status: Int, to location: URL) -> StubResponse {
        StubResponse(status: status, headers: ["Location": location.absoluteString])
    }
}

/// A web server of one test's own, at a host no other test uses, answering
/// the requests `FeedStubProtocol` hands it with the responses the test
/// gave for each path. A path given several responses answers each request
/// with the next, repeating the last; a path given none, or a host no
/// server has, fails as a host not found. Every request is recorded.
///
/// `@unchecked Sendable`: the URL loading system reaches it from its own
/// threads, so every variable is read and changed only under `lock`.
final class FeedStubServer: @unchecked Sendable {
    /// The servers running, by host.
    private static let servers = OSAllocatedUnfairLock<[String: FeedStubServer]>(initialState: [:])

    /// The host this server answers at.
    let host: String
    /// Guards the variables below.
    private let lock = NSLock()
    /// The responses for each path still to be given, the last repeating.
    private var routes: [String: [StubResponse]] = [:]
    /// Every request received, in order.
    private var received: [URLRequest] = []

    /// A server at a host of its own, answering until `stop()`.
    init() {
        host = "\(UUID().uuidString.lowercased()).stub.test"
        Self.servers.withLock { $0[host] = self }
    }

    /// Stops answering: later requests fail as a host not found.
    func stop() {
        Self.servers.withLock { $0[host] = nil }
    }

    /// The server at `host`, if one is running.
    static func server(at host: String) -> FeedStubServer? {
        servers.withLock { $0[host] }
    }

    /// The https address of `path` on this server.
    func url(_ path: String) -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else {
            preconditionFailure("a stub path makes an address: \(path)")
        }
        return url
    }

    /// The http address of `path` on this server.
    func insecureURL(_ path: String) -> URL {
        guard let url = URL(string: "http://\(host)\(path)") else {
            preconditionFailure("a stub path makes an address: \(path)")
        }
        return url
    }

    /// Answers requests for `path` with `responses`, in turn, the last
    /// repeating, in place of any given before.
    func serve(_ path: String, _ responses: StubResponse...) {
        lock.withLock { routes[path] = responses }
    }

    /// Every request received so far.
    var requests: [URLRequest] {
        lock.withLock { received }
    }

    /// The requests received so far for `path`.
    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    /// The response to `request`, recording it; nil when nothing is served
    /// at its path.
    func respond(to request: URLRequest) -> StubResponse? {
        lock.withLock {
            received.append(request)
            guard let path = request.url?.path, var responses = routes[path], let first = responses.first else { return nil }
            if responses.count > 1 {
                responses.removeFirst()
                routes[path] = responses
            }
            return first
        }
    }
}

/// Answers every request of a session it is given to with the stub server
/// at the request's host (`FeedStubServer`), and fails any other as a host
/// not found: no request reaches the network.
///
/// A response is delivered at once, or, when it pauses, part by part from a
/// background queue onto the run loop that started the load, as the URL
/// loading system expects its client to be called; a stopped load delivers
/// nothing more.
///
/// `@unchecked Sendable`: `isStopped` is read and changed only under `lock`;
/// the client is called only on the loading thread's run loop.
final class FeedStubProtocol: URLProtocol, @unchecked Sendable {
    /// Guards `isStopped`.
    private let lock = NSLock()
    /// Whether the load was stopped, after which nothing more is delivered.
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let server = FeedStubServer.server(at: url.host ?? ""),
              let response = server.respond(to: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let answer = Self.answering(range: request.value(forHTTPHeaderField: "Range"), with: response)
        let steps = Self.steps(of: answer, for: url)
        if answer.pause <= 0 && answer.failureGate == nil {
            for step in steps {
                deliver(step)
            }
            return
        }
        // A paused response, or one whose failure waits at a gate, is
        // delivered from a background queue, each part run on this thread's
        // run loop in order, so a failure the gate holds back still comes
        // after the bytes before it.
        let runLoop = RunLoopReference(CFRunLoopGetCurrent())
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                if answer.pause > 0 {
                    Thread.sleep(forTimeInterval: answer.pause)
                }
                if step.isFailure {
                    answer.failureGate?.pass()
                }
                guard !self.lock.withLock({ self.isStopped }) else { return }
                CFRunLoopPerformBlock(runLoop.runLoop, CFRunLoopMode.defaultMode.rawValue) {
                    guard !self.lock.withLock({ self.isStopped }) else { return }
                    self.deliver(step)
                }
                CFRunLoopWakeUp(runLoop.runLoop)
            }
        }
    }

    override func stopLoading() {
        lock.withLock { isStopped = true }
    }

    /// One thing told to the client.
    private enum Step {
        case response(HTTPURLResponse)
        case redirect(URLRequest, HTTPURLResponse)
        case data(Data)
        case finish
        case fail(URLError.Code)
        /// A failure the network gave its reason for.
        case refuse(URLError)

        /// Whether this step ends the load with a failure.
        var isFailure: Bool {
            switch self {
            case .fail, .refuse:
                return true
            case .response, .redirect, .data, .finish:
                return false
            }
        }
    }

    /// `response` as it answers a request for the bytes `range` names
    /// ("bytes=N-", as a resumed download asks): the bytes from N on, as
    /// 206 Partial Content, sent whole; `response` itself for a request
    /// naming no range, or one it cannot serve.
    private static func answering(range: String?, with response: StubResponse) -> StubResponse {
        guard let range, range.hasPrefix("bytes="), response.status == 200,
              let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""),
              start < response.body.count else { return response }
        var partial = response
        partial.status = 206
        partial.body = response.body.subdata(in: start..<response.body.count)
        partial.headers["Content-Range"] = "bytes \(start)-\(response.body.count - 1)/\(response.body.count)"
        partial.headers["Content-Length"] = "\(partial.body.count)"
        partial.failAfterBytes = nil
        partial.failureGate = nil
        return partial
    }

    /// What delivering `response` to a request for `url` tells the client,
    /// in order.
    private static func steps(of response: StubResponse, for url: URL) -> [Step] {
        if let failure = response.failure {
            guard let reason = response.unavailableReason else { return [.fail(failure)] }
            // The reason a network refused the request travels in the error's
            // information, where `URLError.networkUnavailableReason` reads it.
            return [.refuse(URLError(failure, userInfo: [NSURLErrorNetworkUnavailableReasonKey: reason.rawValue]))]
        }
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = "\(response.body.count)"
        }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return [.fail(.badServerResponse)]
        }
        if let location = headers["Location"].flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }) {
            return [.redirect(URLRequest(url: location), http)]
        }
        var steps: [Step] = [.response(http)]
        let size = response.chunkSize ?? max(response.body.count, 1)
        var offset = 0
        while offset < response.body.count {
            if let failAfter = response.failAfterBytes, offset >= failAfter {
                return steps + [.fail(.networkConnectionLost)]
            }
            let end = min(offset + size, response.body.count)
            steps.append(.data(response.body.subdata(in: offset..<end)))
            offset = end
        }
        if let failAfter = response.failAfterBytes, failAfter <= response.body.count {
            return steps + [.fail(.networkConnectionLost)]
        }
        return steps + [.finish]
    }

    /// Tells the client one step.
    private func deliver(_ step: Step) {
        switch step {
        case .response(let response):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .redirect(let request, let response):
            client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
        case .data(let data):
            client?.urlProtocol(self, didLoad: data)
        case .finish:
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .refuse(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// A run loop handed to a background queue.
///
/// `@unchecked Sendable`: the run loop is only given blocks to perform and
/// woken, which Core Foundation allows from any thread.
private final class RunLoopReference: @unchecked Sendable {
    /// The run loop.
    let runLoop: CFRunLoop

    /// A reference to `runLoop`.
    init(_ runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }
}

// MARK: - Feed Documents

/// Small feed documents written to order.
enum FeedXML {
    /// One item of an RSS feed.
    struct Item {
        var guid: String?
        var title: String
        var published: Date?
        var enclosure: String?
        var enclosureType = "audio/mpeg"
        var enclosureLength = 1_000
        var description: String?
        var link: String?

        /// An item named `title`, known by `guid`, published at `published`.
        init(
            guid: String?,
            title: String,
            published: Date? = nil,
            enclosure: String? = nil,
            enclosureType: String = "audio/mpeg",
            enclosureLength: Int = 1_000,
            description: String? = nil,
            link: String? = nil
        ) {
            self.guid = guid
            self.title = title
            self.published = published
            self.enclosure = enclosure
            self.enclosureType = enclosureType
            self.enclosureLength = enclosureLength
            self.description = description
            self.link = link
        }
    }

    /// An RSS 2.0 feed titled `title` listing `items` in order; with
    /// `newFeedURL`, it says it has moved there.
    static func rss(title: String = "The Tactile Atlas", items: [Item], newFeedURL: URL? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let body = items.map { item -> String in
            var parts = ["<title>\(FeedTextConverter.escaped(item.title))</title>"]
            if let guid = item.guid { parts.append("<guid isPermaLink=\"false\">\(guid)</guid>") }
            if let published = item.published { parts.append("<pubDate>\(formatter.string(from: published))</pubDate>") }
            if let enclosure = item.enclosure {
                parts.append("<enclosure url=\"\(enclosure)\" length=\"\(item.enclosureLength)\" type=\"\(item.enclosureType)\"/>")
            }
            if let description = item.description { parts.append("<description><![CDATA[\(description)]]></description>") }
            if let link = item.link { parts.append("<link>\(link)</link>") }
            return "<item>" + parts.joined() + "</item>"
        }.joined(separator: "\n")
        let moved = newFeedURL.map { "<itunes:new-feed-url>\($0.absoluteString)</itunes:new-feed-url>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>\(FeedTextConverter.escaped(title))</title><link>https://show.example/</link>
        <description>A show for tests.</description>\(moved)
        \(body)
        </channel></rss>
        """
    }

    /// A web page naming `links` as its feeds, in order.
    static func page(naming links: [URL]) -> String {
        let heads = links.map { "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"\($0.absoluteString)\">" }
        return "<!DOCTYPE html><html><head><title>A page</title>\(heads.joined())</head><body><p>Hello</p></body></html>"
    }
}

// MARK: - A Feed Engine of the Test's Own

/// A feed engine of one test's own (FR03): its records and fetch details in
/// the test's sandbox folder, its network answered by a stub server, its
/// settings in a sandboxed preferences store, its clock and its sleep moved
/// by the test, and an inert library model with a library folder of the
/// test's own, which is where the feed's downloads go. The shared library
/// index, which the library model saves as books arrive, is put back when
/// the test ends.
@MainActor
final class FeedTestWorld {
    /// The stub server answering every request.
    let server = FeedStubServer()
    /// Whether the network is reachable.
    let online = LockedValue(true)
    /// The time now, as the engine reads it.
    let clock = LockedValue(Date(timeIntervalSince1970: 1_791_000_000))
    /// The sleep between scheduled refreshes.
    let sleep = SteppedSleep()
    /// Whether Low Power Mode is on.
    let lowPowerMode = LockedValue(false)
    /// The free bytes the library's disk reports.
    let freeSpace = LockedValue<Int64?>(100_000_000_000)
    /// The book storage, which says the library is on this Mac until a test
    /// moves it to the cloud.
    let cloud = FakeBookCloudStorage(location: .local)
    /// What the listener's own deletions removed, in order, each by its
    /// name with the names it held, as the Trash would hold them (REV11).
    let removedItems = LockedValue<[RemovedItem]>([])
    /// Whether the listener's own deletions are refused, as a Trash that
    /// cannot take an item refuses it.
    let refusesRemovals = LockedValue(false)
    /// The names of the items whose removal is refused while others go, as
    /// a Trash refuses one item it cannot take: a feed's own folder, say,
    /// once its packages went (FR14).
    let refusesRemovalsNamed = LockedValue<Set<String>>([])

    /// One item a listener's deletion removed: its name, and the names
    /// inside it, sorted, when it is a folder.
    struct RemovedItem: Equatable, Sendable {
        let name: String
        let contents: [String]
    }
    /// The statistics service whose finished books mark items played.
    let stats: ReadingStatsService
    /// The folder holding resume data.
    let resumeFolder: URL
    /// The folder holding finished downloads waiting to be imported.
    let downloadsFolder: URL
    /// The settings store.
    let preferences: UserDefaults
    /// The folder holding the records.
    let recordsFolder: URL
    /// The folder holding this Mac's fetch details.
    let fetchStateFolder: URL
    /// The library model.
    let library: LibraryViewModel
    /// The library folder the feed's downloads go to.
    let folder: IntegrationLibraryFolder
    /// That folder's row.
    let bookFolder: BookFolder
    /// Where the engine reports a record it can't save: the world's own, so
    /// the app's is never disturbed.
    let failures = PersistenceFailureCenter()
    /// What the engine works with, which an engine made for the next launch
    /// works with too (`relaunch(_:)`).
    let environment: FeedEnvironment
    /// The engine.
    let center: FeedCenter

    /// A world whose engine works on its own when `worksOnItsOwn`, made in
    /// folders `test` removes when it ends. Finished books mark items played
    /// as `statistics` counts them, or, without it, as a statistics service
    /// of the world's own does. Its records are written as storage work of
    /// `recordsBoundary`, the process's unless a test holds a boundary of
    /// its own to keep a write waiting. The engine's imports and its rules'
    /// removals of downloaded files run as storage work of `boundary`, the
    /// process's unless a test holds a boundary of its own to keep them
    /// waiting (never hold `.shared`: every later test would wait on it).
    init(
        _ test: XCTestCase,
        label: String,
        worksOnItsOwn: Bool = false,
        statistics: ReadingStatsService? = nil,
        recordsBoundary: StorageBoundary = .shared,
        boundary: StorageBoundary = .shared
    ) throws {
        // Registered first of all, so it runs last, once the library index
        // has been put back, which writes any save still waiting: a feed's
        // downloads go to a folder of the feed's own in the data directory's
        // Feeds folder (FR11), and every such folder this world made goes.
        let feedFoldersBefore = Self.feedItemsFolders()
        test.addTeardownBlock {
            for folder in Self.feedItemsFolders().subtracting(feedFoldersBefore) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // Registered next, so it runs once the engine has stopped.
        let index = try LibraryIndexSandbox.capture()
        test.addTeardownBlock { index.restore() }
        let sandbox = try test.makeSandboxDirectory(label)
        recordsFolder = sandbox.appendingPathComponent("Feeds", isDirectory: true)
        fetchStateFolder = sandbox.appendingPathComponent("Fetch State", isDirectory: true)
        preferences = test.makeSandboxedPreferences(label)
        folder = test.makeIntegrationLibraryFolder(label)
        bookFolder = BookFolder(name: folder.path)
        library = LibraryViewModel(initializeServices: false)
        library.library = Library(folders: [bookFolder])
        let online = online
        let clock = clock
        let sleep = sleep
        let lowPowerMode = lowPowerMode
        let freeSpace = freeSpace
        let cloud = cloud
        let removedItems = removedItems
        let refusesRemovals = refusesRemovals
        let refusesRemovalsNamed = refusesRemovalsNamed
        stats = statistics ?? ReadingStatsService(fileURL: sandbox.appendingPathComponent("reading_stats.json"))
        let stats = stats
        resumeFolder = sandbox.appendingPathComponent("Resume Data", isDirectory: true)
        downloadsFolder = sandbox.appendingPathComponent("Feed Downloads", isDirectory: true)
        environment = FeedEnvironment(
            records: .folder(recordsFolder, boundary: recordsBoundary),
            failureCenter: failures,
            fetchStateFolder: fetchStateFolder,
            network: .stubbed(
                protocolClasses: [FeedStubProtocol.self],
                reachability: NetworkReachability { online.value }
            ),
            // The podcast directory answers at the stub server's /search.
            directory: FeedDirectory(searchingAt: server.url("/search")),
            preferences: preferences,
            now: { clock.value },
            sleep: { try await sleep.sleep($0) },
            isLowPowerMode: { lowPowerMode.value },
            worksOnItsOwn: worksOnItsOwn,
            resumeFolder: resumeFolder,
            downloadsFolder: downloadsFolder,
            freeSpace: { _ in freeSpace.value },
            boundary: boundary,
            bookStorage: { cloud },
            finishedBooksSource: stats,
            // Never the Trash in a test: a file or package goes for good,
            // noted as the Trash would hold it, unless the test refuses it.
            removeItem: { item in
                guard !refusesRemovals.value, !refusesRemovalsNamed.value.contains(item.lastPathComponent) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let contents = ((try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? []).sorted()
                removedItems.value.append(RemovedItem(name: item.lastPathComponent, contents: contents))
                try FileManager.default.removeItem(at: item)
            }
        )
        center = FeedCenter(environment: environment)
        // The library lists this engine's feeds' items (FR11).
        library.feedEngine = center
        // Registered last, so it runs first, while every folder of the world
        // is still there.
        test.addTeardownBlock { [self] in
            await finishFeedWork()
        }
    }

    /// Ends the world's feed work, as its teardown does before any of its
    /// folders goes: the stub server stops answering, the engine stops, and
    /// every write asked for so far lands (`finish(_:)`).
    ///
    /// A write landing once the sandbox is gone would fail, and a record's
    /// failure, reported to the world's failure center, is announced to
    /// VoiceOver like any other (`PersistenceFailureCenter.publish()`): into
    /// whichever later test captures announcements, as a stray save did to
    /// `FeedUIAddFeedTests` under load.
    func finishFeedWork() async {
        server.stop()
        await Self.finish(center)
    }

    /// Stops `center` and waits for every write it asked for so far: its
    /// records, and the store's hearing of how each went
    /// (`FeedStore.flush()`); its fetch details, whose writes make their
    /// folder again when it is gone; and every statistics save, whose
    /// failure the app's failure center announces.
    ///
    /// Its download work stops first, as quitting stops it, and its own
    /// work, a sweep or a pass of the newest-N rule, is let end, so no write
    /// either asks for lands once the flush is done, as a stray save once
    /// did for a test ending with work in flight (feed review item 22). The
    /// wait gives up after 15 seconds, so a teardown never hangs.
    static func finish(_ center: FeedCenter) async {
        center.stop()
        await center.downloads.stopForQuit()
        let deadline = Date().addingTimeInterval(15)
        while center.isSweeping || center.downloads.current != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await center.store.flush()
        await center.fetchStates.flush()
        ReadingStatsService.waitForQueuedSaves()
    }

    /// The feeds' own folders in the data directory's Feeds folder now, each
    /// named by a feed's ID (FR11).
    nonisolated static func feedItemsFolders() -> Set<URL> {
        let feeds = FeedPaths.recordsFolder(in: TextMouthPaths.root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: feeds.path)) ?? []
        return Set(names.compactMap { name in
            FeedPaths.feedID(ofItemsFolderNamed: name).map { _ in feeds.appendingPathComponent(name, isDirectory: true) }
        })
    }

    /// Starts the engine in the world's library and waits for what it
    /// starts to finish.
    func start() async {
        await center.start(library: library)?.value
    }

    /// The engine the next launch makes: a new one on the world's folders,
    /// network, clock, and library, working on its own as the app's does,
    /// started, with what its start begins finished. `configure` sees it
    /// before it starts, as a test that hooks into its downloads needs.
    /// `test` stops it when it ends, and waits for its writes, before the
    /// world's folders go.
    func relaunch(_ test: XCTestCase, configuring configure: (FeedCenter) -> Void = { _ in }) async -> FeedCenter {
        var next = environment
        next.worksOnItsOwn = true
        let relaunched = FeedCenter(environment: next)
        test.addTeardownBlock {
            await Self.finish(relaunched)
        }
        configure(relaunched)
        await relaunched.start(library: library)?.value
        return relaunched
    }

    /// Subscribes to the feed served at `path`, which must succeed, starting
    /// the engine first when it has not started.
    func subscribe(_ path: String) async throws -> Feed {
        if !center.hasStarted {
            await start()
        }
        let outcome = try await center.subscribe(to: server.url(path).absoluteString, folderID: bookFolder.id)
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedTestWorld", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "subscribing to \(path) offered a choice instead: \(outcome)",
            ])
        }
        return feed
    }

    /// Moves the clock on by `interval` seconds.
    func advance(by interval: TimeInterval) {
        clock.value = clock.value.addingTimeInterval(interval)
    }

    /// Holds the engine's import queue, where its rules remove files off the
    /// main thread and downloads are imported, until the gate it returns is
    /// released, as heavy load can hold it: a removal begun meanwhile has
    /// taken its rows out of the books and written its records and indexes,
    /// but has removed no file and settled no item's state (REV11 F5, and
    /// the races of board #1821). `test`'s teardown releases it too.
    func holdImports(_ test: XCTestCase) async -> WorkGate {
        let gate = WorkGate()
        gate.arm()
        test.addTeardownBlock { gate.release() }
        let downloads = center.downloads
        Task { await downloads.runBesideImports { gate.pass() } }
        await test.waitFor("the import queue is held") { gate.wasReached }
        return gate
    }

    /// A date `days` days from the clock's start.
    func day(_ days: Double) -> Date {
        Date(timeIntervalSince1970: 1_791_000_000 + days * 86_400)
    }
}

extension XCTestCase {
    /// Waits, suspending so the main actor runs, until `condition` holds or
    /// `timeout` seconds pass, and fails the test in the latter case: for
    /// async tests, where `waitUntil(timeout:_:)`, which turns the run loop,
    /// would run main-actor work inside the waiting test's own. Nothing is
    /// fulfilled, so nothing can be fulfilled twice. The default timeout is
    /// generous, for a suite that runs under load: a wait ends as soon as
    /// its condition holds.
    @MainActor
    func waitFor(
        _ description: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Holding Work Partway

/// Holds work on a background thread at its first pass once armed, until
/// the test lets it go, so the test can see what is under way at that
/// moment: an export reading its first file, or the feed engine's import
/// queue (`FeedTestWorld.holdImports(_:)`). The wait gives up after 30
/// seconds, so no thread waits for good should a test end early, and each
/// test releases it in its teardown as well.
final class WorkGate: Sendable {
    /// Whether the gate holds the next pass, and whether one reached it.
    private let state = OSAllocatedUnfairLock(initialState: (armed: false, reached: false))
    /// Signalled to let the held pass go.
    private let released = DispatchSemaphore(value: 0)

    /// Makes the next pass wait at the gate.
    func arm() {
        state.withLock { $0.armed = true }
    }

    /// Whether a pass has reached the armed gate.
    var wasReached: Bool {
        state.withLock { $0.reached }
    }

    /// Lets the held pass go; a release with none held only lets the next
    /// one through.
    func release() {
        released.signal()
    }

    /// Called by the work at each pass: the first once the gate is armed
    /// waits until `release()`, and every other passes at once.
    func pass() {
        let holds = state.withLock { state -> Bool in
            guard state.armed, !state.reached else { return false }
            state.reached = true
            return true
        }
        if holds {
            _ = released.wait(timeout: .now() + 30)
        }
    }
}

// MARK: - Episode Files

/// The files feed downloads serve in tests.
enum FeedMediaFixtures {
    /// A response serving `data` as a file of `mimeType`, which a resumed
    /// download may ask for in part: it names an ETag and serves byte ranges.
    static func file(_ data: Data, mimeType: String) -> StubResponse {
        StubResponse(headers: ["Content-Type": mimeType, "ETag": "\"episode-1\"", "Accept-Ranges": "bytes"], body: data)
    }

    /// `duration` seconds of AAC silence in an MPEG-4 audio file, as bytes.
    static func silentAAC(duration: TimeInterval = 1) throws -> Data {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("silence.m4a")
        try AudioTestFixtures.writeAACSilence(to: file, duration: duration)
        return try Data(contentsOf: file)
    }

    /// A short MPEG-4 video, as bytes: black H.264 frames, one a second, beside
    /// `duration` seconds of AAC silence, as a video podcast's episode holds
    /// pictures beside its sound.
    static func silentVideo(duration: TimeInterval = 2) async throws -> Data {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try AudioTestFixtures.writeAACSilence(to: audio, duration: duration)
        let video = folder.appendingPathComponent("video.mp4")
        try await writeVideo(to: video, audio: audio, duration: duration)
        return try Data(contentsOf: video)
    }

    /// Writes black frames of `duration` seconds beside the audio of the file
    /// at `audio`, copied as it is, into an MPEG-4 file at `url`.
    private static func writeVideo(to url: URL, audio: URL, duration: TimeInterval) async throws {
        let asset = AVURLAsset(url: audio)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let audioFormat = try await audioTrack.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(audioOutput)

        let size = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        writer.add(videoInput)
        writer.add(audioInput)
        guard reader.startReading() else { throw try XCTUnwrap(reader.error) }
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)

        for second in 0..<max(1, Int(duration.rounded(.up))) {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let frame = try XCTUnwrap(made)
            // A black frame: every byte zero.
            CVPixelBufferLockBaseAddress(frame, [])
            if let base = CVPixelBufferGetBaseAddress(frame) {
                memset(base, 0, CVPixelBufferGetDataSize(frame))
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            guard adaptor.append(frame, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)) else {
                throw try XCTUnwrap(writer.error)
            }
        }
        videoInput.markAsFinished()
        while let sample = audioOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard audioInput.append(sample) else { throw try XCTUnwrap(writer.error) }
        }
        audioInput.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }
}

// MARK: - Downloads

extension XCTestCase {
    /// The book the item `itemID` of `feed` downloads as in `world`, through
    /// `center` (the world's own engine unless a relaunched one is given),
    /// once its download has ended, announcing its end, and its book is in
    /// the library; fails the test when the download fails or takes longer
    /// than 20 seconds.
    @MainActor
    func downloadedBook(
        _ world: FeedTestWorld,
        center: FeedCenter? = nil,
        feed: Feed,
        item itemID: FeedItem.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Book {
        let center = center ?? world.center
        // The item is marked downloaded as its book is listed, a moment
        // before the download ends and announces it.
        await waitFor("\(itemID) downloads", timeout: 20, file: file, line: line) {
            let state = center.store.record(of: feed.id)?.item(itemID)?.state
            let settled = state?.bookID != nil || state?.failureReason != nil
            return settled && !center.downloads.isDownloading(itemID, of: feed.id)
        }
        let state = center.store.record(of: feed.id)?.item(itemID)?.state
        if let reason = state?.failureReason {
            XCTFail("the download of \(itemID) failed: \(reason)", file: file, line: line)
        }
        let bookID = try XCTUnwrap(state?.bookID, file: file, line: line)
        return try XCTUnwrap(world.library.bookByID(bookID), file: file, line: line)
    }

    /// Starts `world`'s engine, subscribes it to a feed of `episodes`
    /// episodes, "Episode 1" ("guid:ep-1") the newest, each a second of
    /// silence served at /audio/<number>.m4a, whose folder goes where
    /// `choice` says (the world's own folder unless given), and downloads
    /// the first `downloading` of them, each as the listener asks; returns
    /// the feed and the books, episode 1 first (FR14).
    @MainActor
    func feedWithDownloads(
        episodes: Int,
        downloading: Int,
        in world: FeedTestWorld,
        into choice: FeedFolderChoice? = nil
    ) async throws -> (feed: Feed, books: [Book]) {
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        let items = (1...episodes).map { number in
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
            return FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(Double(-number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4",
                enclosureLength: audio.count
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let outcome = try await world.center.subscribe(
            to: world.server.url("/feed.xml").absoluteString,
            into: choice ?? .folder(world.bookFolder.id)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedTestWorld", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        var books: [Book] = []
        for number in stride(from: 1, through: downloading, by: 1) {
            world.center.download("guid:ep-\(number)", of: feed.id)
            books.append(try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)"))
        }
        return (feed, books)
    }
}
