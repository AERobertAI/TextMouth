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
    /// A failure after this many bytes of the body, as a connection that
    /// drops partway.
    var failAfterBytes: Int?

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
        let steps = Self.steps(of: Self.answering(range: request.value(forHTTPHeaderField: "Range"), with: response), for: url)
        if response.pause <= 0 {
            for step in steps {
                deliver(step)
            }
            return
        }
        // A paused response is delivered from a background queue, each part
        // run on this thread's run loop.
        let runLoop = RunLoopReference(CFRunLoopGetCurrent())
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                Thread.sleep(forTimeInterval: response.pause)
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
        return partial
    }

    /// What delivering `response` to a request for `url` tells the client,
    /// in order.
    private static func steps(of response: StubResponse, for url: URL) -> [Step] {
        if let failure = response.failure {
            return [.fail(failure)]
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
    /// The engine.
    let center: FeedCenter

    /// A world whose engine works on its own when `worksOnItsOwn`, made in
    /// folders `test` removes when it ends.
    init(_ test: XCTestCase, label: String, worksOnItsOwn: Bool = false) throws {
        // Registered first, so it runs last, once the engine has stopped.
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
        resumeFolder = sandbox.appendingPathComponent("Resume Data", isDirectory: true)
        downloadsFolder = sandbox.appendingPathComponent("Feed Downloads", isDirectory: true)
        center = FeedCenter(environment: FeedEnvironment(
            records: .folder(recordsFolder),
            fetchStateFolder: fetchStateFolder,
            network: .stubbed(
                protocolClasses: [FeedStubProtocol.self],
                reachability: NetworkReachability { online.value }
            ),
            preferences: preferences,
            now: { clock.value },
            sleep: { try await sleep.sleep($0) },
            isLowPowerMode: { lowPowerMode.value },
            worksOnItsOwn: worksOnItsOwn,
            resumeFolder: resumeFolder,
            downloadsFolder: downloadsFolder,
            freeSpace: { _ in freeSpace.value },
            boundary: .shared
        ))
        let server = server
        let center = center
        test.addTeardownBlock {
            server.stop()
            await MainActor.run { center.stop() }
        }
    }

    /// Starts the engine in the world's library and waits for what it
    /// starts to finish.
    func start() async {
        await center.start(library: library)?.value
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
    /// The book the item `itemID` of `feed` downloads as in `world`, once
    /// its download has ended, announcing its end, and its book is in the
    /// library; fails the test when the download fails or takes longer than
    /// 20 seconds.
    @MainActor
    func downloadedBook(
        _ world: FeedTestWorld,
        feed: Feed,
        item itemID: FeedItem.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Book {
        // The item is marked downloaded as its book is listed, a moment
        // before the download ends and announces it.
        await waitFor("\(itemID) downloads", timeout: 20, file: file, line: line) {
            let state = world.center.store.record(of: feed.id)?.item(itemID)?.state
            let settled = state?.bookID != nil || state?.failureReason != nil
            return settled && !world.center.downloads.isDownloading(itemID, of: feed.id)
        }
        let state = world.center.store.record(of: feed.id)?.item(itemID)?.state
        if let reason = state?.failureReason {
            XCTFail("the download of \(itemID) failed: \(reason)", file: file, line: line)
        }
        let bookID = try XCTUnwrap(state?.bookID, file: file, line: line)
        return try XCTUnwrap(world.library.bookByID(bookID), file: file, line: line)
    }
}
