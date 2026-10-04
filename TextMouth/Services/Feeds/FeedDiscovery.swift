import Foundation
import SwiftSoup

// MARK: - Feeds a Web Page Names (FR03)

/// A feed a web page names, which a listener can subscribe to.
struct FeedLink: Equatable, Sendable {
    /// The feed's address.
    var url: URL
    /// The page's title for the feed, when it gives one, such as "Comments
    /// Feed".
    var title: String?
    /// The feed's MIME type, as the page gives it.
    var mimeType: String
}

/// Finds the feeds a web page names (FR03): its `link` elements whose
/// relation is "alternate" and whose type is an RSS, Atom, or JSON feed's,
/// as RSS autodiscovery, JSON Feed 1.1, and the HTML standard describe
/// them, in the page's order, the first being the site's main feed.
///
/// The page's elements are walked directly, as `HTMLToMarkdownConverter`
/// walks a document, rather than through a SwiftSoup selector, whose cached
/// results hold on to the document. Nothing the page links to is fetched.
enum FeedDiscovery {
    /// The MIME types of the feeds TextMouth reads. A JSON Feed's is
    /// application/feed+json; plain application/json is left out, since
    /// pages use it for other alternates, such as WordPress's REST API.
    static let feedTypes: Set<String> = [
        "application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/feed+json",
    ]

    /// The feeds the page `html`, fetched from `pageURL`, names, each once,
    /// with relative addresses resolved from the page's base address.
    static func feedLinks(inPage html: String, pageURL: URL) -> [FeedLink] {
        guard let document = try? SwiftSoup.parse(html, pageURL.absoluteString) else { return [] }
        var links: [FeedLink] = []
        var seen = Set<String>()
        FeedHTMLWalk.visit(document) { element in
            if element.tagName().lowercased() == "link", let link = feedLink(element, pageURL: pageURL),
               seen.insert(link.url.absoluteString).inserted {
                links.append(link)
            }
            return true
        }
        return links
    }

    /// The feed the `link` element names, or nil when it names none: its
    /// relation must include "alternate", its type must be a feed's, and its
    /// address must be http or https.
    private static func feedLink(_ element: Element, pageURL: URL) -> FeedLink? {
        let relations = ((try? element.attr("rel")) ?? "").lowercased().split(whereSeparator: \.isWhitespace)
        let type = ((try? element.attr("type")) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard relations.contains("alternate"), feedTypes.contains(type) else { return nil }
        let resolved = (try? element.absUrl("href")).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = resolved ?? URL(string: href, relativeTo: pageURL)?.absoluteURL,
              FeedTransport.isWebAddress(url) else { return nil }
        let title = ((try? element.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedLink(url: url, title: title.isEmpty ? nil : title, mimeType: type)
    }
}

// MARK: - Addresses Listeners Type

/// Reads an address a listener types or pastes for a feed (FR03).
enum FeedAddress {
    /// The http or https address `text` names, or nil when it names none.
    ///
    /// Subscribe links on some sites use the feed, pcast, or itpc schemes,
    /// which mean http; "feed:https://…" wraps a whole address. An address
    /// without a scheme ("example.com/feed") is taken as https.
    static func normalized(_ text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = address.lowercased()
        for scheme in ["feed:", "pcast:", "itpc:"] where lower.hasPrefix(scheme) {
            address.removeFirst(scheme.count)
            if address.hasPrefix("//") {
                address = "https:" + address
            }
            break
        }
        if !address.lowercased().hasPrefix("http://"), !address.lowercased().hasPrefix("https://") {
            guard !address.contains("://") else { return nil }
            address = "https://" + address
        }
        guard let url = URL(string: address), FeedTransport.isWebAddress(url) else { return nil }
        return url
    }
}

// MARK: - Walking a Page

/// Walks a page's elements directly, in document order, as
/// `HTMLToMarkdownConverter` walks a document, rather than through a
/// SwiftSoup selector, whose cached results hold on to the document.
enum FeedHTMLWalk {
    /// Visits `root` and every element inside it, depth first in document
    /// order, until `visitor` returns false.
    static func visit(_ root: Element, _ visitor: (Element) -> Bool) {
        var elements: [Element] = [root]
        while let element = elements.popLast() {
            guard visitor(element) else { return }
            // Children are visited before later siblings, first child first.
            elements.append(contentsOf: element.children().array().reversed())
        }
    }

    /// The first element inside `root`, or `root` itself, whose tag is
    /// `tag`, in document order.
    static func first(_ tag: String, in root: Element) -> Element? {
        var found: Element?
        visit(root) { element in
            if element.tagName().lowercased() == tag {
                found = element
                return false
            }
            return true
        }
        return found
    }
}
