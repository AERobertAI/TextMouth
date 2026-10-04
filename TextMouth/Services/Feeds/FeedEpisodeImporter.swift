import Foundation
import SwiftSoup

// MARK: - A Download Becomes a Book (FR03)

/// How a feed item's download becomes a book in its feed's folder (FR03),
/// through the import pipeline every book takes: a package staged where
/// `ImportScratchSpace` stages it, the file moved in, the book read as the
/// reader will read it, its record written and read back, and the package
/// published with one rename (`FileImportService.publishReadableBook`).
///
/// - An episode, audio or video, becomes an audiobook. Video plays as sound
///   alone (the listener's decision of October 4). Only these downloads
///   accept video files: the extensions they keep (`FeedMediaKind
///   .videoExtensions`) are not among the formats Open Book imports, so the
///   format is given here rather than read from the extension.
/// - An article becomes an HTML book, from an HTML file written here: its
///   title as a heading, the author, the date, the text, and the link.
///
/// The book takes the item's title, its author (`bookAuthor(for:of:)`),
/// the show as an episode's album, and the date of the download as its date
/// added; its record names the feed and the item (`FeedBookLink`). Every
/// function runs off the main thread.
enum FeedEpisodeImporter {
    /// The extension of each MIME type an episode may come as.
    static let extensionsByMIMEType: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mpeg3": "mp3", "audio/x-mpeg": "mp3",
        "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a",
        "audio/x-m4b": "m4b", "audio/m4b": "m4b",
        "audio/aac": "aac", "audio/x-aac": "aac", "audio/aacp": "aac",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff",
        "audio/flac": "flac", "audio/x-flac": "flac",
        "video/mp4": "mp4", "video/x-m4v": "m4v", "video/quicktime": "mov",
    ]

    /// The extension a downloaded episode is kept under, which tells
    /// AVFoundation what the file holds: the type the server gave it when
    /// that names one TextMouth plays, else the extension of its address,
    /// else the type the feed gave. Nil when none names a file TextMouth
    /// plays, such as Ogg audio.
    static func fileExtension(responseMIMEType: String?, enclosure: FeedEnclosure) -> String? {
        if let fromResponse = responseMIMEType.flatMap(extensionForMIMEType) {
            return fromResponse
        }
        let fromAddress = enclosure.url.pathExtension.lowercased()
        if FeedMediaKind.audioExtensions.contains(fromAddress) || FeedMediaKind.videoExtensions.contains(fromAddress) {
            return fromAddress
        }
        return enclosure.mimeType.flatMap(extensionForMIMEType)
    }

    /// The extension of `mimeType`, ignoring its parameters and letter case.
    private static func extensionForMIMEType(_ mimeType: String) -> String? {
        let bare = mimeType.split(separator: ";").first.map(String.init) ?? mimeType
        return extensionsByMIMEType[bare.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The author of the book `item` of `feed` becomes: the item's own
    /// author, else the show's, else the show's title.
    static func bookAuthor(for item: FeedItem, of feed: Feed) -> String {
        item.author ?? feed.author ?? feed.title
    }

    /// The name a file of the item titled `title` gets in its package: the
    /// title's letters, digits, spaces, hyphens, and underscores, at most 80
    /// characters, then `fileExtension`.
    static func fileName(title: String, fileExtension: String) -> String {
        let kept = title.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }
        let stem = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(80)
        return (stem.isEmpty ? "Episode" : String(stem)) + "." + fileExtension
    }

    // MARK: Importing

    /// Imports the episode file at `file`, which is moved into the book's
    /// package as `fileName`, as an audiobook in the library folder
    /// `folderPath`, added at `dateAdded`.
    /// - Throws: an `ImportFailure` naming the file and the step that
    ///   failed; whatever was staged is removed, and `file` is left where it
    ///   was when the move had not happened.
    static func importEpisode(
        _ file: URL,
        named fileName: String,
        item: FeedItem,
        of feed: Feed,
        toFolder folderPath: String,
        dateAdded: Date
    ) throws -> ImportedBook {
        try importBook(named: fileName, format: .audio, item: item, of: feed, toFolder: folderPath, dateAdded: dateAdded) { staged in
            try FileManager.default.moveItem(at: file, to: staged)
        }
    }

    /// Imports an article whose book is the HTML `html` as an HTML book in
    /// the library folder `folderPath`, added at `dateAdded`.
    /// - Throws: an `ImportFailure`, as `importEpisode` does.
    static func importArticle(
        html: String,
        item: FeedItem,
        of feed: Feed,
        toFolder folderPath: String,
        dateAdded: Date
    ) throws -> ImportedBook {
        let fileName = Self.fileName(title: item.title, fileExtension: "html")
        return try importBook(named: fileName, format: .html, item: item, of: feed, toFolder: folderPath, dateAdded: dateAdded) { staged in
            try Data(html.utf8).write(to: staged, options: .atomic)
        }
    }

    /// The import both kinds share: a package staged for the book, its file
    /// put in by `placeFile`, then read, recorded with its feed item, and
    /// published.
    private static func importBook(
        named fileName: String,
        format: BookFormat,
        item: FeedItem,
        of feed: Feed,
        toFolder folderPath: String,
        dateAdded: Date,
        placeFile: (URL) throws -> Void
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: fileName) { run in
            let bookID = UUID()
            let author = bookAuthor(for: item, of: feed)

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try FileImportService.destinationPackageURL(
                title: item.title,
                author: author,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let stagedFile = staging.directory.appendingPathComponent(fileName)
            try placeFile(stagedFile)

            try run.begin(.readingSource, in: staging.directory)
            let hash = try FileImportService.md5Hash(of: stagedFile)
            let staged = Book(
                id: bookID,
                title: item.title,
                author: author,
                format: format,
                filePath: stagedFile.path,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                tmbDirectoryName: staging.name,
                audioAlbum: format.isAudio ? feed.title : nil,
                audioGenre: format.isAudio ? "Podcast" : nil,
                audioYear: format.isAudio ? item.published.map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) } : nil
            )
            return try FileImportService.publishReadableBook(
                staged,
                from: staging,
                run: &run,
                feedLink: FeedBookLink(feedID: feed.id, itemID: item.id)
            )
        }
    }

    // MARK: Articles

    /// The HTML of an article's book: its title as a heading, a line with
    /// its author or show and its date, `body`, and a link to its page.
    static func articleHTML(for item: FeedItem, of feed: Feed, body: String) -> String {
        let escaped = FeedTextConverter.escaped
        var byline: [String] = []
        if let author = item.author, author != feed.title {
            byline.append(author)
        }
        byline.append(feed.title)
        if let published = item.published {
            byline.append(published.formatted(date: .long, time: .omitted))
        }
        var parts = [
            "<!DOCTYPE html>",
            "<html>",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<title>\(escaped(item.title))</title>",
            "<meta name=\"author\" content=\"\(escaped(bookAuthor(for: item, of: feed)))\">",
            "</head>",
            "<body>",
            "<h1>\(escaped(item.title))</h1>",
            "<p>\(escaped(byline.joined(separator: ", ")))</p>",
            body,
        ]
        if let link = item.link {
            parts.append("<p>Read on the web: <a href=\"\(escaped(link.absoluteString))\">\(escaped(FeedHost.of(link)))</a></p>")
        }
        parts += ["</body>", "</html>", ""]
        return parts.joined(separator: "\n")
    }

    /// How many words of an article's own text make it whole enough that
    /// its web page is not fetched: fewer means the feed gave a summary.
    static let shortArticleWords = 200

    /// The text an article's book holds by the rule chosen for articles: the
    /// item's own content, or its summary, unless that runs to fewer than
    /// `shortArticleWords` words and the item links a page, whose article
    /// (`readablePart(ofPage:)`) is used when it reads as more words.
    /// `fetchPage` fetches the page's HTML, or returns nil when it can't.
    static func articleBody(for item: FeedItem, fetchPage: @Sendable (URL) async -> String?) async -> String {
        let own = item.content ?? item.summary
        let ownWords = own.map { wordCount($0.plainText) } ?? 0
        guard ownWords < shortArticleWords, let link = item.link,
              let page = await fetchPage(link),
              let readable = readablePart(ofPage: page),
              let pageText = FeedTextConverter.read(html: readable),
              wordCount(pageText.plainText) > ownWords else {
            return own?.html ?? ""
        }
        return readable
    }

    /// The part of a web page an article's book reads: its first `article`
    /// element, else its `main` element, else its body, as HTML; nil when
    /// the page can't be read.
    static func readablePart(ofPage html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html) else { return nil }
        for tag in ["article", "main"] {
            if let element = FeedHTMLWalk.first(tag, in: document), let inner = try? element.html() {
                return inner
            }
        }
        return try? document.body()?.html()
    }

    /// The words in `text`: its runs of characters that are not whitespace.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
