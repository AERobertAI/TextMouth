import CryptoKit
import Foundation

// MARK: - One Episode or Article (FR03)

/// One episode or article of a feed, as the feed's record keeps it (FR03):
/// what the feed says about it, and what the listener has done with it.
///
/// The feed's fields (title, texts, dates, enclosure, and the rest) follow
/// the feed at each refresh. The listener's fields (`state`, `playedDate`,
/// `downloadDeletedDate`, and `deletedDate`) change only through what the
/// listener and TextMouth do with the item, never through a refresh.
struct FeedItem: Codable, Equatable, Identifiable, Sendable {
    /// The item's identity (`FeedItemIdentity`): its guid, else its
    /// enclosure's address, else its link and title. Fixed when the item is
    /// first seen, so a book downloaded from it stays linked to it
    /// (`FeedBookLink`) even after the feed renumbers its guids.
    let id: String
    /// The item's guid (an Atom entry's id) as the feed gives it now.
    var guid: String?
    /// The item's title, as plain text.
    var title: String
    /// The item's summary: its description, `itunes:summary`, or Atom
    /// summary.
    var summary: FeedText?
    /// The item's full content (`content:encoded`, or Atom content), when the
    /// feed gives more than the summary.
    var content: FeedText?
    /// When the feed says the item was published, when it says in a form
    /// TextMouth reads.
    var published: Date?
    /// When TextMouth first listed the item: the date it sorts by when the
    /// feed gives none.
    var firstSeen: Date
    /// The file the item offers: an episode's audio or video.
    var enclosure: FeedEnclosure?
    /// How long the episode plays, in seconds, when the feed says.
    var duration: TimeInterval?
    /// The item's web page.
    var link: URL?
    /// Who wrote or presents the item, when the feed says.
    var author: String?
    /// The episode's number (`itunes:episode`), which orders a serial show's
    /// episodes when the feed dates none of them.
    var episodeNumber: Int?
    /// The item's transcripts (Podcasting 2.0 `podcast:transcript`).
    var transcripts: [FeedResource]?
    /// The item's chapters file (Podcasting 2.0 `podcast:chapters`).
    var chapters: FeedResource?
    /// Where the item's download stands.
    var state: FeedItemState
    /// When the item played to the end (an article: was read to the end), or
    /// was marked played; nil while unplayed.
    var playedDate: Date?
    /// When the item's download was deleted, by the delete-after-played rule
    /// or by the listener, keeping the item itself; nil while it is
    /// downloaded or was never deleted.
    var downloadDeletedDate: Date?
    /// When the listener deleted the item itself. The record keeps it, out of
    /// every list, so the next refresh never brings it back.
    var deletedDate: Date?

    /// An item seen for the first time at `firstSeen`, not downloaded and
    /// unplayed.
    init(
        id: String,
        guid: String? = nil,
        title: String,
        summary: FeedText? = nil,
        content: FeedText? = nil,
        published: Date? = nil,
        firstSeen: Date,
        enclosure: FeedEnclosure? = nil,
        duration: TimeInterval? = nil,
        link: URL? = nil,
        author: String? = nil,
        episodeNumber: Int? = nil,
        transcripts: [FeedResource]? = nil,
        chapters: FeedResource? = nil,
        state: FeedItemState = .notDownloaded,
        playedDate: Date? = nil,
        downloadDeletedDate: Date? = nil,
        deletedDate: Date? = nil
    ) {
        self.id = id
        self.guid = guid
        self.title = title
        self.summary = summary
        self.content = content
        self.published = published
        self.firstSeen = firstSeen
        self.enclosure = enclosure
        self.duration = duration
        self.link = link
        self.author = author
        self.episodeNumber = episodeNumber
        self.transcripts = transcripts
        self.chapters = chapters
        self.state = state
        self.playedDate = playedDate
        self.downloadDeletedDate = downloadDeletedDate
        self.deletedDate = deletedDate
    }

    /// The date the item sorts by: its publication date, or the date it was
    /// first seen when the feed gives none.
    var sortDate: Date {
        published ?? firstSeen
    }

    /// Whether the item is an article rather than an episode: it offers no
    /// audio or video to download, so its download is its text, read as an
    /// HTML book.
    var isArticle: Bool {
        !(enclosure?.isPlayable ?? false)
    }
}

// MARK: - Where a Download Stands

/// Where an item's download stands (FR03).
///
/// A download in progress is published while it runs, with its progress, so
/// the library can show "Downloading 40%" (`visibleNote`); the item's record
/// file never holds it (`FeedRecord.durable`), since the download ends with
/// the app.
enum FeedItemState: Equatable, Sendable {
    /// The item has no book.
    case notDownloaded
    /// The item is waiting to download, or downloading, with how far it has got.
    case downloading(BookDownloadProgress)
    /// The item's last download failed, for the reason given, which a
    /// listener reads; Download tries it again.
    case failed(String)
    /// The item's download is the book `bookID`, in the feed's folder.
    case downloaded(bookID: UUID)

    /// The book the item downloaded as, if it is downloaded.
    var bookID: UUID? {
        if case .downloaded(let bookID) = self { return bookID }
        return nil
    }

    /// Whether the item is waiting to download or downloading.
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// Why the item's last download failed, if it did.
    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    /// The note a list shows for the state, which a braille display shows
    /// too: "Downloading 40%" is worded once, for books in the cloud and
    /// feed items alike (`BookCloudState`).
    var visibleNote: String {
        switch self {
        case .notDownloaded: return "Not Downloaded"
        case .downloading(let progress): return BookCloudState.downloading(progress).visibleNote ?? "Downloading"
        case .failed: return "Download Failed"
        case .downloaded: return "Downloaded"
        }
    }

    /// The same note as VoiceOver speaks it: "Downloading, 40 percent".
    var spokenNote: String {
        switch self {
        case .downloading(let progress): return BookCloudState.downloading(progress).spokenNote ?? visibleNote
        default: return visibleNote
        }
    }
}

extension FeedItemState: Codable {
    /// The keys of a state in a record file.
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case bookID
    }

    /// The kinds a record file names.
    private enum Kind: String, Codable {
        case notDownloaded
        case failed
        case downloaded
    }

    /// Reads a state. A kind this version does not know, or a failure or
    /// download missing its details, reads as not downloaded, so one odd
    /// item never makes its whole record unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try? container.decode(Kind.self, forKey: .kind) {
        case .failed:
            let reason = (try? container.decode(String.self, forKey: .reason)) ?? ""
            self = .failed(reason)
        case .downloaded:
            if let bookID = try? container.decode(UUID.self, forKey: .bookID) {
                self = .downloaded(bookID: bookID)
            } else {
                self = .notDownloaded
            }
        case .notDownloaded, nil:
            self = .notDownloaded
        }
    }

    /// Writes a state. A download in progress is written as not downloaded:
    /// it does not outlive the app that runs it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notDownloaded, .downloading:
            try container.encode(Kind.notDownloaded, forKey: .kind)
        case .failed(let reason):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .downloaded(let bookID):
            try container.encode(Kind.downloaded, forKey: .kind)
            try container.encode(bookID, forKey: .bookID)
        }
    }
}

// MARK: - The File an Item Offers

/// The file an item offers to download (an RSS enclosure, or an Atom link
/// whose relation is enclosure): its address, its MIME type, and its length.
struct FeedEnclosure: Codable, Equatable, Sendable {
    /// Where the file is.
    var url: URL
    /// The file's MIME type as the feed gives it, such as "audio/mpeg"; an
    /// advisory, which the address's extension backs up.
    var mimeType: String?
    /// The file's length in bytes as the feed gives it, or nil when the feed
    /// gives none or gives 0, as LibriVox does. Often wrong, so it serves
    /// only as an estimate before a download starts.
    var length: Int64?

    /// What kind of file the enclosure is, from its MIME type, or from its
    /// address's extension when the type says nothing useful.
    var kind: FeedMediaKind {
        FeedMediaKind.of(mimeType: mimeType, url: url)
    }

    /// Whether the enclosure is audio or video, which TextMouth plays as an
    /// audiobook.
    var isPlayable: Bool {
        kind != .other
    }
}

/// What kind of file an enclosure is.
enum FeedMediaKind: String, Equatable, Sendable {
    /// Audio, imported as an audiobook.
    case audio
    /// Video, imported as an audiobook whose sound alone plays (the
    /// listener's decision of October 4).
    case video
    /// Anything else, such as a PDF or an image, which TextMouth does not
    /// download.
    case other

    /// The extensions TextMouth imports as audio, the import pipeline's own.
    static let audioExtensions = Set(BookFormat.audio.fileExtensions)

    /// The extensions TextMouth imports from feeds as video played as audio.
    /// Only feed downloads accept them (`FeedEpisodeImporter`): a video file
    /// chosen in Open Book is still refused.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// The kind of a file whose MIME type is `mimeType` and whose address is
    /// `url`: by the type's top-level part when it is audio or video, and
    /// otherwise by the address's extension, since feeds often give a
    /// generic type ("application/octet-stream") or none.
    static func of(mimeType: String?, url: URL) -> FeedMediaKind {
        let type = mimeType?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        let fileExtension = url.pathExtension.lowercased()
        if audioExtensions.contains(fileExtension) { return .audio }
        if videoExtensions.contains(fileExtension) { return .video }
        return .other
    }
}

/// A file an item links to besides its enclosure: a transcript or a
/// chapters file (Podcasting 2.0).
struct FeedResource: Codable, Equatable, Sendable {
    /// Where the file is.
    var url: URL
    /// Its MIME type, such as "text/vtt" or "application/json+chapters".
    var mimeType: String?
}

// MARK: - Text Read From a Feed

/// A summary or content as an item gives it: the HTML (or the plain text,
/// made HTML) the feed holds, read once through the app's HTML readers as
/// plain text, which VoiceOver and a braille display read, and as Markdown,
/// which keeps headings, emphasis, lists, and links.
struct FeedText: Codable, Equatable, Sendable {
    /// The text as HTML: the feed's own markup, or its plain text with each
    /// line break made a break, so an article's book reads it as written.
    var html: String
    /// The text as the HTML reader reads it, without markup.
    var plainText: String
    /// The text as Markdown, as the HTML converter writes it.
    var markdown: String
}

// MARK: - Identity

/// How an item is told from the feed's other items, and found again at the
/// next refresh (FR03): by its guid (an Atom entry's id), else by its
/// enclosure's address, as for LibriVox's feeds, which give no guid, else by
/// its link and title together, else by a digest of its summary.
enum FeedItemIdentity {
    /// The identity of an item with these fields. Each kind of key has a
    /// prefix of its own, so a guid that happens to look like an address
    /// never matches an enclosure.
    static func key(guid: String?, enclosureURL: URL?, link: URL?, title: String, summaryHTML: String?) -> String {
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            return "guid:" + guid
        }
        if let enclosureURL {
            return "enclosure:" + enclosureURL.absoluteString
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if link != nil || !trimmedTitle.isEmpty {
            // U+001F, the unit separator, which neither an address nor a
            // title holds, keeps "a" + "bc" apart from "ab" + "c".
            return "link:" + (link?.absoluteString ?? "") + "\u{1F}" + trimmedTitle
        }
        let digest = SHA256.hash(data: Data((summaryHTML ?? "").utf8))
        return "summary:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
