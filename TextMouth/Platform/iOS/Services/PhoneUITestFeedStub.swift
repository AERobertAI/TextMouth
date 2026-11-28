import Foundation

// The whole of this file is compiled into debug builds only, as `PhoneLaunchRequest` is: a release build holds
// neither the type nor the host it answers.
#if DEBUG

/// The one feed, and its one episode file, that an interface test of the iPhone app can subscribe to without the
/// network (FR53): a stand-in server, in the app's own process, that answers two addresses and nothing else.
///
/// The Mac's tests reach their feeds through a stub protocol of their own (`FeedStubProtocol`), which lives in the test
/// target. A UI test drives the app from another process, so the app itself carries the stand-in, only in a debug
/// build, and only in a launch that asked for a sandbox (`PhoneLaunchRequest.sandboxVariable`), where the app's feed
/// sessions otherwise refuse every request (`FeedNetworkRefusal`). It answers `feeds.textmouth.test`, a name no
/// network resolves, and never any other host.
///
/// - `https://feeds.textmouth.test/atlas.xml` is a small RSS feed titled "The Tactile Atlas" with two episodes, each
///   naming an audio file of the same host.
/// - `https://feeds.textmouth.test/audio/<name>.wav` serves the file the launch named
///   (`PhoneLaunchRequest.feedEpisodeVariable`), a few kilobytes of tone from the test bundle, whichever name is asked.
final class PhoneUITestFeedStub: URLProtocol {
    /// The host the stand-in answers.
    static let host = "feeds.textmouth.test"

    /// The feed's address, which a UI test types into Add Feed.
    static let feedAddress = "https://\(host)/atlas.xml" // l10n: no (a web address a test types)

    /// The feed's title.
    static let feedTitle = "The Tactile Atlas" // l10n: no (a feed's own title, in a test's data)

    /// The titles of the feed's two episodes, newest first.
    static let episodeTitles = ["A map you can touch", "Ridges and valleys"] // l10n: no (a feed's own titles, in a test's data)

    /// The feed itself, as a feed's own server would send it. The dates are fixed, so a launch always lists the same.
    private static var feedDocument: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
        <title>\(feedTitle)</title>
        <link>https://\(host)/</link>
        <description>A show for interface tests.</description>
        <item>
        <title>\(episodeTitles[0])</title>
        <guid isPermaLink="false">atlas-2</guid>
        <pubDate>Wed, 25 Nov 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://\(host)/audio/atlas-2.wav" length="16044" type="audio/x-wav"/>
        <itunes:duration>1</itunes:duration>
        </item>
        <item>
        <title>\(episodeTitles[1])</title>
        <guid isPermaLink="false">atlas-1</guid>
        <pubDate>Tue, 24 Nov 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://\(host)/audio/atlas-1.wav" length="16044" type="audio/x-wav"/>
        <itunes:duration>1</itunes:duration>
        </item>
        </channel>
        </rss>
        """
    }

    /// Whether the app's feed sessions should try this stand-in before refusing a request: a launch that asked for a
    /// sandbox and named an episode file.
    static func isOn(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        PhoneLaunchRequest.runsInSandbox(environment) && PhoneLaunchRequest.feedEpisodeFile(environment) != nil
    }

    /// Answers only the stand-in's own host.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    /// The request as it is.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Answers the feed, or the episode file, whole and at once; a failure for anything else.
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/atlas.xml" {
            deliver(Data(Self.feedDocument.utf8), type: "application/rss+xml", for: url)
        } else if url.path.hasPrefix("/audio/"), let file = PhoneLaunchRequest.feedEpisodeFile(ProcessInfo.processInfo.environment),
                  let bytes = try? Data(contentsOf: file) {
            deliver(bytes, type: "audio/x-wav", for: url)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }
    }

    /// Nothing is in flight to stop: every answer is delivered at once.
    override func stopLoading() {}

    /// Tells the client the answer, `bytes` of `type`, then that it is done.
    private func deliver(_ bytes: Data, type: String, for url: URL) {
        let headers = ["Content-Type": type, "Content-Length": "\(bytes.count)"] // l10n: no (HTTP header names)
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}

#endif
