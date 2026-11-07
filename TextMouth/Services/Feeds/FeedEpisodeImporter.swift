import Foundation
import SwiftSoup

// MARK: - A Download Becomes a Book (FR03)

/// How a feed item's download becomes a book of its feed (FR03), through the
/// import pipeline every book takes: a package staged where
/// `ImportScratchSpace` stages it, the file moved in, the book read as the
/// reader will read it, its record written and read back, and the package
/// published with one rename (`FileImportService.publishReadableBook`).
///
/// The package is published in the feed's own folder, `Feeds/<feed ID>/`,
/// outside the Library folder (FR11, `destinationPackageURL`), and the book
/// is a feed item's: its row names its feed and item and no library folder,
/// and its feed's index keeps it rather than library.json.
///
/// - An episode, audio or video, becomes an audiobook. Video plays as sound
///   alone (the listener's decision of October 4), and is among the formats
///   Open Book imports as audiobooks too, so a video episode's package
///   imports again; the format is given here all the same, since a
///   download's extension comes from its type or its address.
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
        // Ogg audio, which AVFoundation plays from macOS 15.4 on
        // (`BookFormat.fileExtensions`). "application/ogg" is left out: it
        // may hold video, which AVFoundation does not play.
        "audio/ogg": "ogg", "audio/vorbis": "ogg", "audio/opus": "opus",
        "video/mp4": "mp4", "video/x-m4v": "m4v", "video/quicktime": "mov",
    ]

    /// The extension a downloaded episode is kept under, which tells
    /// AVFoundation what the file holds: the type the server gave it when
    /// that names one TextMouth plays, else the extension of its address,
    /// else the type the feed gave. Nil when none names a file TextMouth
    /// plays, such as Windows Media Audio.
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
    /// package as `fileName`, as an audiobook of `feed` in the feed's own
    /// folder (FR11), added at `dateAdded`; or, with `kept`, the item's row
    /// kept after an earlier download's file went, as that same book in its
    /// kept package (`restoreBook`, FR11 branch A2). `chapters`, a podcast's
    /// own chapters fetched with the episode (FMT25), are kept in its package
    /// before it is read, so the book takes them as its headings when its
    /// audio has none of its own (`BookContentAnalysisService.analyzeAudio`).
    /// - Throws: an `ImportFailure` naming the file and the step that
    ///   failed; whatever was staged is removed, and `file` is left where it
    ///   was when the move had not happened.
    static func importEpisode(
        _ file: URL,
        named fileName: String,
        item: FeedItem,
        of feed: Feed,
        dateAdded: Date,
        restoring kept: Book? = nil,
        chapters: PodcastChapters? = nil
    ) throws -> ImportedBook {
        try importBook(
            named: fileName,
            format: .audio,
            item: item,
            of: feed,
            dateAdded: dateAdded,
            restoring: kept,
            chapters: chapters
        ) { staged in
            try FileManager.default.moveItem(at: file, to: staged)
        }
    }

    /// Imports an article whose book is the HTML `html` as an HTML book of
    /// `feed` in the feed's own folder (FR11), added at `dateAdded`; or,
    /// with `kept`, as that same book in its kept package, as
    /// `importEpisode` does.
    /// - Throws: an `ImportFailure`, as `importEpisode` does.
    static func importArticle(
        html: String,
        item: FeedItem,
        of feed: Feed,
        dateAdded: Date,
        restoring kept: Book? = nil
    ) throws -> ImportedBook {
        let fileName = Self.fileName(title: item.title, fileExtension: "html")
        return try importBook(named: fileName, format: .html, item: item, of: feed, dateAdded: dateAdded, restoring: kept) { staged in
            try Data(html.utf8).write(to: staged, options: .atomic)
        }
    }

    /// Where a download of the feed `feedID` publishes its package (FR11):
    /// in the feed's own folder, `Feeds/<feed ID>/`, made first when it is
    /// missing, inside a data directory that must be there, under the name
    /// the book's title, author, date added, and ID give it, as
    /// `FileImportService.destinationPackageURL` names a book's package in a
    /// library folder.
    static func destinationPackageURL(
        title: String,
        author: String,
        dateAdded: Date,
        bookID: UUID,
        feedID: UUID
    ) throws -> URL {
        try packageURL(
            named: TextMouthPaths.tmbName(title: title, author: author, dateAdded: dateAdded, bookID: bookID),
            ofFeed: feedID
        )
    }

    /// The package named `name` in the feed `feedID`'s own folder,
    /// `Feeds/<feed ID>/`, which is made first when it is missing, inside a
    /// data directory that must be there: where a download publishes a new
    /// package (`destinationPackageURL`), or finds the package kept for its
    /// item (`restoreBook`).
    private static func packageURL(named name: String, ofFeed feedID: UUID) throws -> URL {
        try TextMouthPaths.ensureDirectoryStructure()
        let root = TextMouthPaths.root
        try FileManager.default.createDirectory(at: FeedPaths.itemsFolder(of: feedID, in: root), withIntermediateDirectories: true)
        return FeedPaths.packageDirectory(named: name, of: feedID, in: root)
    }

    /// Puts a download's file into `staging` as `fileName` with
    /// `placeFile`, then reads its checksum, and keeps beside it `chapters`,
    /// the podcast's own chapters of `item`, when it has any: the copying and
    /// reading steps of every download's import, new or restoring a kept
    /// item.
    /// - Returns: The staged file and its MD5 checksum.
    private static func stageFile(
        named fileName: String,
        in staging: ImportStaging,
        run: inout ImportRun,
        chapters: PodcastChapters?,
        of item: FeedItem,
        placeFile: (URL) throws -> Void
    ) throws -> (url: URL, md5Hash: String) {
        try run.begin(.copying, in: staging.directory)
        let stagedFile = staging.directory.appendingPathComponent(fileName)
        try placeFile(stagedFile)
        keep(chapters, of: item, in: staging)
        try run.begin(.readingSource, in: staging.directory)
        return (stagedFile, try FileImportService.md5Hash(of: stagedFile))
    }

    /// Writes `chapters`, the podcast's own chapters of `item`, into the
    /// package `staging` holds (`TextMouthPaths.podcastChaptersPath(in:)`).
    /// They never stop the episode's own import: one that cannot be written
    /// is left out, with one FEED_CHAPTERS_NOT_KEPT line in the debug log,
    /// naming the error by its code and domain, since its own words can name
    /// the package by its absolute path.
    private static func keep(_ chapters: PodcastChapters?, of item: FeedItem, in staging: ImportStaging) {
        guard let chapters else { return }
        do {
            try chapters.normalizedJSON().write(to: TextMouthPaths.podcastChaptersPath(in: staging.directory), options: .atomic)
        } catch {
            let failure = error as NSError
            DiagnosticLog.event(.feeds, "FEED_CHAPTERS_NOT_KEPT: \(item.title): error \(failure.code) in \(failure.domain)")
        }
    }

    /// Whether a download of an item whose row `kept` was kept after an
    /// earlier download's file went restores that same book into its kept
    /// package (`restoreBook`), which then holds the place, bookmarks, and
    /// transcript kept for it, rather than publishing a new one: when the
    /// row names a package of its feed's folder (FR11, branch A2).
    static func restoresKeptPackage(_ kept: Book?) -> Bool {
        kept.map { FeedItemPackage.isPackageName($0.tmbDirectoryName) } ?? false
    }

    /// The import both kinds share: a package staged for the book, its file
    /// put in by `placeFile`, then read, recorded with its feed item, and
    /// published in the feed's own folder. With `kept`, a row whose package
    /// was kept after an earlier download's file went, the same book is
    /// restored there instead (`restoreBook`). `chapters` are a podcast's own
    /// chapters of `item`, kept in the package beside its file (`stageFile`).
    private static func importBook(
        named fileName: String,
        format: BookFormat,
        item: FeedItem,
        of feed: Feed,
        dateAdded: Date,
        restoring kept: Book?,
        chapters: PodcastChapters? = nil,
        placeFile: (URL) throws -> Void
    ) throws -> ImportedBook {
        if let kept, restoresKeptPackage(kept) {
            return try restoreBook(kept, named: fileName, format: format, item: item, of: feed, chapters: chapters, placeFile: placeFile)
        }
        return try ImportRun.perform(importing: fileName) { run in
            let bookID = UUID()
            let author = bookAuthor(for: item, of: feed)
            let link = FeedBookLink(feedID: feed.id, itemID: item.id)

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: item.title,
                author: author,
                dateAdded: dateAdded,
                bookID: bookID,
                feedID: feed.id
            ))
            defer { staging.discard() }

            let file = try stageFile(named: fileName, in: staging, run: &run, chapters: chapters, of: item, placeFile: placeFile)
            // A feed item's row names its feed and item and no library folder
            // (FR11); while staged, its package is the staged one.
            let staged = Book(
                id: bookID,
                title: item.title,
                author: author,
                format: format,
                filePath: file.url.path,
                md5Hash: file.md5Hash,
                folderPath: "",
                dateAdded: dateAdded,
                tmbDirectoryName: staging.name,
                audioAlbum: format.isAudio ? feed.title : nil,
                audioGenre: format.isAudio ? "Podcast" : nil,
                audioYear: format.isAudio ? item.published.map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) } : nil,
                feedLink: link
            )
            return try FileImportService.publishReadableBook(
                staged,
                from: staging,
                run: &run,
                feedLink: link
            )
        }
    }

    /// Imports a new download of `item` into the package kept for it after
    /// an earlier download's file went (FR11, branch A2), restoring the same
    /// book. `kept`, the item's row as its feed's index keeps it, gives the
    /// book its ID, package, date added, place, playback times, bookmarks,
    /// and settings; the new file, put in by `placeFile` as `fileName`,
    /// gives its file, its checksum, and what reading it measures.
    ///
    /// The package is staged as every import's is, with the transcript the
    /// kept package holds copied in (a kept package that cannot be listed
    /// fails the download, and stays as it is), then read as the reader
    /// will read it and recorded as every import's is
    /// (`FileImportService.publishReadableBook`), the kept record's revision
    /// passed and the note of a transcript following the new index, which
    /// has none until the episode opens; only then does it take the kept
    /// package's place, in one step where the volume allows
    /// (`FeedItemPackage.putInPlace`), so the kept package stays whole until
    /// the new one is. A transcript whose audio differs from the new file's,
    /// as when a host inserts other advertisements into each download, is
    /// kept: the episode finds it stale (TRANSCRIPT_STALE) and shows no text
    /// until it is transcribed again (`TranscriptTextLoader`). An
    /// audiobook's content.md, which the new package does not carry, is kept
    /// as an `.edited-` copy when it holds a save its record's transcript
    /// layer does not account for (`FeedItemPackage.unrecordedTranscriptText(of:)`).
    /// Chapters kept with the earlier file went with it; `chapters` are those
    /// fetched with the new one (`stageFile`).
    private static func restoreBook(
        _ kept: Book,
        named fileName: String,
        format: BookFormat,
        item: FeedItem,
        of feed: Feed,
        chapters: PodcastChapters?,
        placeFile: (URL) throws -> Void
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: fileName) { run in
            let link = FeedBookLink(feedID: feed.id, itemID: item.id)

            try run.begin(.preparingPackage)
            let keptPackage = try packageURL(named: kept.tmbDirectoryName, ofFeed: feed.id)
            // What a crash during an earlier restore left set aside is put
            // right before anything reads the kept package.
            try FeedItemPackage.recoverSetAside(of: keptPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: keptPackage)
            defer { staging.discard() }
            try FeedItemPackage.copyWhatANewDownloadKeeps(from: keptPackage, to: staging.directory)
            // An article's text, which the rules keep and may hold an edit,
            // is written anew from the new file: the earlier one is read
            // now, to stay beside the new one should they differ (REV11).
            // An audiobook's is written from its transcript when it opens,
            // and is kept only when it holds a save no session took, which
            // its record's transcript layer does not account for.
            let earlierText = format.isAudio
                ? try FeedItemPackage.unrecordedTranscriptText(of: keptPackage)
                : try FeedItemPackage.keptText(of: keptPackage)
            let keptState = (try? StoredBookRecord.read(from: keptPackage))?.info.state

            let file = try stageFile(named: fileName, in: staging, run: &run, chapters: chapters, of: item, placeFile: placeFile)
            var staged = kept
            staged.format = format
            staged.filePath = file.url.path
            staged.md5Hash = file.md5Hash
            staged.folderPath = ""
            staged.tmbDirectoryName = staging.name
            staged.feedLink = link
            // What reading the new file measures replaces what the old one's did.
            staged.contentAnalysisFields = Book.ContentAnalysisFields()
            var keptCopy: URL?
            let restored = try FileImportService.publishReadableBook(
                staged,
                from: staging,
                run: &run,
                feedLink: link,
                replacing: keptState,
                publish: { built in
                    keptCopy = try FeedItemPackage.keepEarlierText(earlierText, in: built.directory)
                    try FeedItemPackage.putInPlace(built, of: keptPackage)
                }
            )
            DiagnosticLog.event(
                .feeds,
                "FEED_DOWNLOAD_RESTORED: \(restored.book.title): downloaded again into its kept package, with its place and bookmarks"
            )
            if let keptCopy {
                // An audiobook's copy is a save no session took; an article's is
                // an earlier text unlike the one the new file gives.
                let what = format.isAudio
                    ? "its text, which holds a save its transcript's record does not account for,"
                    : "its earlier text, unlike the new download's,"
                DiagnosticLog.event(
                    .feeds,
                    "FEED_ARTICLE_TEXT_KEPT: \(restored.book.title): \(what) kept as \(keptCopy.lastPathComponent)"
                )
            }
            return restored
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
    /// - Throws: what `fetchPage` throws, as a download that must wait for
    ///   its page rather than be written from its summary does.
    static func articleBody(for item: FeedItem, fetchPage: @Sendable (URL) async throws -> String?) async rethrows -> String {
        let own = item.content ?? item.summary
        let ownWords = own.map { wordCount($0.plainText) } ?? 0
        guard ownWords < shortArticleWords, let link = item.link,
              let page = try await fetchPage(link),
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
