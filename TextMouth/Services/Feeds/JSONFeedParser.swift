import Foundation

// MARK: - Reading JSON Feed (FR03)

/// Reads JSON Feed 1.1 and 1.0 (https://www.jsonfeed.org/version/1.1/) into
/// the feed the XML readers make (`ParsedFeed`), so a JSON feed is merged,
/// listed, downloaded, and announced exactly as an RSS or Atom feed is
/// (FR03).
///
/// - The feed's title, home page (its site), description, and authors
///   (`authors`, or 1.0's single `author`) are its own fields.
/// - An item's id is its guid, its `url` (else its `external_url`) its
///   page, its `date_published` (else its `date_modified`) its date, and
///   its authors its author.
/// - `content_html`, else `content_text`, is its content, and `summary` its
///   summary; content that only repeats the summary is dropped, as for RSS.
/// - Its attachments are its enclosures, chosen as RSS enclosures are
///   (`FeedEnclosure.preferred(among:otherwise:)`), each with its size and
///   its duration.
/// - An item without a title is listed by the start of its text, as an
///   RSS item is.
///
/// Each field is read on its own (`FeedJSON`), so one of an unexpected type
/// reads as absent. A document that is no JSON object, or names no JSON
/// Feed version, is no feed. Only http and https addresses are kept, and
/// relative ones are resolved from the feed's own address.
enum JSONFeedParser {
    /// How every version's address begins: "https://jsonfeed.org/version/1.1".
    static let versionPrefixes = ["https://jsonfeed.org/version/", "http://jsonfeed.org/version/"]

    /// The UTF-8 byte order mark, which a document may begin with.
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Whether `data` is JSON rather than XML: its first byte past a byte
    /// order mark and white space opens an object.
    static func looksLikeJSON(_ data: Data) -> Bool {
        let bytes = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data[...]
        let first = bytes.first { !(($0 == 0x20) || ($0 == 0x09) || ($0 == 0x0A) || ($0 == 0x0D)) }
        return first == UInt8(ascii: "{")
    }

    /// Reads `data` as a JSON Feed whose relative addresses are relative to
    /// `baseURL`, the address it was fetched from, keeping at most
    /// `maximumItems` items.
    /// - Throws: `FeedParseError.notAFeed` for JSON that is no JSON Feed.
    static func parse(_ data: Data, baseURL: URL?, maximumItems: Int) throws -> ParsedFeed {
        let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data
        guard let document = FeedJSON.object(in: Data(body)),
              let version = FeedJSON.string(document["version"])?.lowercased(),
              versionPrefixes.contains(where: { version.hasPrefix($0) }) else {
            throw FeedParseError.notAFeed
        }
        let listed = FeedJSON.objects(document["items"])
        var items: [ParsedItem] = []
        for entry in listed.prefix(maximumItems) {
            if let item = item(entry, position: items.count, baseURL: baseURL) {
                items.append(item)
            }
        }
        return ParsedFeed(
            format: .json,
            title: FeedJSON.string(document["title"]).map { FeedTextConverter.plainLine($0) } ?? "",
            siteLink: webAddress(document["home_page_url"], baseURL: baseURL),
            summary: FeedJSON.string(document["description"]).map { FeedTextSource(text: $0, kind: .plain) },
            author: authorNames(in: document),
            isSerial: false,
            newFeedURL: nil,
            items: items,
            repair: nil,
            reachedItemLimit: listed.count > maximumItems
        )
    }

    // MARK: Items

    /// The item `entry` describes, the `position`th listed, or nil when it
    /// gives nothing to list: no title, text, id, page, or attachment.
    private static func item(_ entry: [String: Any], position: Int, baseURL: URL?) -> ParsedItem? {
        let guid = identifier(entry["id"])
        let summary = FeedJSON.string(entry["summary"]).map { FeedTextSource(text: $0, kind: .plain) }
        let content = FeedJSON.string(entry["content_html"]).map { FeedTextSource(text: $0, kind: .html) }
            ?? FeedJSON.string(entry["content_text"]).map { FeedTextSource(text: $0, kind: .plain) }
        let attachments = FeedJSON.objects(entry["attachments"]).compactMap { attachment($0, baseURL: baseURL) }
        let chosen = FeedEnclosure.preferred(among: attachments.map(\.enclosure), otherwise: attachments.first?.enclosure)
        let link = webAddress(entry["url"], baseURL: baseURL) ?? webAddress(entry["external_url"], baseURL: baseURL)

        var title = FeedJSON.string(entry["title"]).map { FeedTextConverter.plainLine($0) } ?? ""
        if title.isEmpty, let text = summary ?? content {
            title = ParsedItem.standInTitle(from: text.text, isHTML: text.kind == .html)
        }
        guard !title.isEmpty || guid != nil || chosen != nil || link != nil else { return nil }
        return ParsedItem(
            guid: guid,
            title: title,
            link: link,
            summary: summary,
            content: content.flatMap { ParsedItem.isRepeating($0, summary) ? nil : $0 },
            published: date(entry["date_published"]) ?? date(entry["date_modified"]),
            enclosure: chosen,
            duration: attachments.first { $0.enclosure == chosen }?.duration,
            author: authorNames(in: entry),
            episodeNumber: nil,
            transcripts: [],
            chapters: nil,
            position: position
        )
    }

    /// An attachment as an enclosure, with how long it plays: its address,
    /// which must be http or https, its MIME type, and its size when that
    /// is a positive number of bytes.
    private static func attachment(_ entry: [String: Any], baseURL: URL?) -> (enclosure: FeedEnclosure, duration: TimeInterval?)? {
        guard let url = webAddress(entry["url"], baseURL: baseURL) else { return nil }
        let size = FeedJSON.integer(entry["size_in_bytes"]).flatMap { $0 > 0 ? Int64($0) : nil }
        let duration = FeedJSON.number(entry["duration_in_seconds"]).flatMap { $0 > 0 ? $0 : nil }
        return (FeedEnclosure(url: url, mimeType: FeedJSON.string(entry["mime_type"]), length: size), duration)
    }

    // MARK: Fields

    /// An item's id: a string, or, as JSON Feed 1.0 allowed, a number,
    /// written as its digits.
    private static func identifier(_ value: Any?) -> String? {
        if let text = FeedJSON.string(value) {
            return text
        }
        guard let number = value as? NSNumber, FeedJSON.number(number) != nil else { return nil }
        return number.stringValue
    }

    /// The names of the authors `object` lists (`authors`, or JSON Feed
    /// 1.0's single `author`), joined by commas, or nil when it names none.
    private static func authorNames(in object: [String: Any]) -> String? {
        var authors = FeedJSON.objects(object["authors"])
        if authors.isEmpty, let single = object["author"] as? [String: Any] {
            authors = [single]
        }
        return authors.compactMap { FeedJSON.string($0["name"]) }.joinedNames
    }

    /// The date an RFC 3339 field names, read as Atom's dates are.
    private static func date(_ value: Any?) -> Date? {
        FeedJSON.string(value).flatMap(FeedDates.date(from:))
    }

    /// The http or https address `value` gives, resolved from `baseURL`
    /// when relative; nil for any other: a file a feed names is never
    /// loaded.
    private static func webAddress(_ value: Any?, baseURL: URL?) -> URL? {
        guard let text = FeedJSON.string(value),
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              FeedTransport.isWebAddress(url) else { return nil }
        return url
    }
}
