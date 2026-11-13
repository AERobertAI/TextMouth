import Foundation

// MARK: - Book Info Without Waiting (FR02)

/// What the library's Book Info sheet shows for a book.
enum LibraryBookInfo {
    /// The EPUB editor with `metadata`. When `isCloudOnly`, the EPUB was
    /// only in the cloud: the metadata is the library's own, and the sheet
    /// says some details appear once the book is downloaded.
    case epub(EPUBMetadata, isCloudOnly: Bool)
    /// The audio editor with `metadata`; `isCloudOnly` as for an EPUB.
    case audio(AudioMetadata, isCloudOnly: Bool)
    /// The simple title and author sheet: a format without the rich editor,
    /// or an EPUB whose metadata could not be read.
    case simple

    /// What the sheet says while some details wait for a download.
    static let cloudOnlyNote = "Some details appear once the book is downloaded."

    /// Whether the book's file was only in the cloud, so the sheet shows the
    /// details the library keeps and says `cloudOnlyNote`.
    var isCloudOnly: Bool {
        switch self {
        case .epub(_, let isCloudOnly), .audio(_, let isCloudOnly): return isCloudOnly
        case .simple: return false
        }
    }

    /// Why Save refuses to write the library's copy of an EPUB that was
    /// only in the cloud when the sheet opened: writing it would download
    /// it first, while the interface waited. Nil when the save can go ahead.
    static func writeRefusal(isCloudOnly: Bool, writesToFile: Bool) -> String? {
        guard isCloudOnly, writesToFile else { return nil }
        return "The book's EPUB file is only in the cloud, so it can't be written until the book is downloaded. "
            + "Turn off writing to the file, or download the book first."
    }
}

/// Reads what Book Info shows, off the main thread, and never downloads a
/// book whose file is only in the cloud (FR02): for that book it shows the
/// metadata the library keeps. Tests replace each read.
struct LibraryBookInfoReader: Sendable {
    /// Whether the item at a URL is dataless. It is asked only of an item
    /// that a look made with downloading switched off has found
    /// (`LocalBookFiles.availability(of:isDataless:)`), so asking never
    /// brings anything down from the cloud.
    var isDataless: @Sendable (URL) -> Bool
    /// Reads the metadata of the EPUB file at a URL.
    var readEPUBMetadata: @Sendable (URL) throws -> EPUBMetadata
    /// Reads the metadata of the audio file at a URL.
    var readAudioMetadata: @Sendable (URL) async -> AudioMetadata
    /// How long reading an audio file's tags may take before Book Info
    /// stops waiting and shows the metadata the library keeps. Tests pass a
    /// short one.
    var audioTagsTimeLimit: Duration = AsyncBridge.audioTagsTimeLimit
    /// The audio files whose tag read passed its limit, which are not read
    /// again until TextMouth is opened again. Tests pass their own.
    var abandonedReads: AsyncBridge.AbandonedReads = .session

    /// The reads the app uses. An EPUB is read with dataless files left in
    /// the cloud, so one evicted after the check fails at once instead of
    /// downloading.
    static let system = LibraryBookInfoReader(
        isDataless: { DatalessFiles.isDataless($0) },
        readEPUBMetadata: { file in
            try DatalessFiles.withoutDownloading { try EPUBParser.readMetadata(url: file) }
        },
        readAudioMetadata: { await AudioPlaybackService.extractFullMetadata(from: $0) }
    )

    /// What Book Info shows for `book`, with every look at its files and
    /// every read of them made off the main thread. The library's own edits
    /// are laid over what the file says, as the editors expect.
    @MainActor
    func info(for book: Book) async -> LibraryBookInfo {
        let file = book.bookFileURL
        let cloudChecked = Self.cloudCheckedItems(of: book)
        let reader = self
        switch book.format {
        case .epub:
            let read = await Task.detached(priority: .userInitiated) {
                reader.readEPUB(at: file, unlessInCloud: cloudChecked)
            }.value
            switch read {
            case .metadata(let metadata):
                return .epub(book.mergingEditableEPUBMetadata(metadata), isCloudOnly: false)
            case .onlyInCloud:
                return .epub(book.storedEPUBMetadata, isCloudOnly: true)
            case .unreadable:
                return .simple
            }
        case .audio:
            let isCloudOnly = await Task.detached(priority: .userInitiated) { reader.isAnyInCloud(cloudChecked) }.value
            if isCloudOnly {
                return .audio(book.storedAudioMetadata, isCloudOnly: true)
            }
            // A tag read that never returns (a file that hangs AVFoundation)
            // would leave the sheet on its loading state for good: after the
            // limit, or for a file an earlier read gave up on, the sheet
            // shows the metadata the library keeps. That is not the
            // cloud-only case, so the sheet says nothing of a download.
            let tags = await Task.detached(priority: .userInitiated) {
                try? AsyncBridge.waitForResult(
                    reading: file,
                    timeLimit: reader.audioTagsTimeLimit,
                    abandoned: reader.abandonedReads
                ) { await reader.readAudioMetadata(file) }
            }.value
            guard let tags else {
                return .audio(book.storedAudioMetadata, isCloudOnly: false)
            }
            return .audio(book.mergingEditableAudioMetadata(tags), isCloudOnly: false)
        case .txt, .markdown, .html, .webarchive, .ssml, .docx, .rtf, .rtfd, .doc, .odt, .wordml, .braille, .daisy, .pdf, .mobi, .kfx:
            return .simple
        }
    }

    /// What reading an EPUB's metadata found.
    private enum EPUBRead {
        /// The metadata in the file.
        case metadata(EPUBMetadata)
        /// The file is only in the cloud, so it was not read.
        case onlyInCloud
        /// The file could not be read for another reason.
        case unreadable
    }

    /// The items that decide whether `book`'s file is only in the cloud, in
    /// the order they are looked at: the package holding the file, when the
    /// book has one, and then the file. iCloud Drive evicts a package as one
    /// item, leaving the package's folder dataless, and a look at the file
    /// inside it with downloading allowed brings the whole book back down
    /// (board #624); a sync service that syncs each file evicts the file on
    /// its own. A file outside its package, as an old book's can be, is
    /// judged by itself alone.
    private static func cloudCheckedItems(of book: Book) -> [URL] {
        let file = book.bookFileURL
        let package = BookPackage(book)
        guard package.isPackage, MaintenanceFileAccess.isItem(file, inside: package.url) else { return [file] }
        return [package.url, file]
    }

    /// Whether any of `items` is only in the cloud, each looked at with one
    /// lstat(2) made with downloading switched off, as the reader looks at a
    /// chapter's files (`LocalBookFiles.availability(of:isDataless:)`): a
    /// look through a folder only in the cloud is refused at once and counts
    /// as in the cloud, and nothing is ever brought down to answer. Looks on
    /// the calling thread, which must not be the main thread.
    private func isAnyInCloud(_ items: [URL]) -> Bool {
        items.contains { LocalBookFiles.availability(of: $0, isDataless: isDataless) == .inCloud }
    }

    /// Reads the metadata of the EPUB at `file` on the calling thread,
    /// unless any of `cloudChecked` (`cloudCheckedItems(of:)`) is only in the
    /// cloud. A file evicted after the check counts as only in the cloud
    /// too.
    private func readEPUB(at file: URL, unlessInCloud cloudChecked: [URL]) -> EPUBRead {
        if isAnyInCloud(cloudChecked) {
            return .onlyInCloud
        }
        do {
            return .metadata(try readEPUBMetadata(file))
        } catch {
            return DatalessFiles.isDownloadRefusal(error) || isAnyInCloud(cloudChecked) ? .onlyInCloud : .unreadable
        }
    }
}

extension Book {
    /// The EPUB metadata the library keeps for this book, which Book Info
    /// shows while the file is only in the cloud. A field the library keeps
    /// none of shows empty; a save that leaves it empty leaves it unknown
    /// (`Book.MetadataEdit`), so the file's value shows once the book is
    /// downloaded.
    var storedEPUBMetadata: EPUBMetadata {
        EPUBMetadata(
            title: title,
            author: author,
            publisher: epubPublisher ?? "",
            publicationDate: epubPublicationDate ?? "",
            isbn: epubISBN ?? "",
            language: epubLanguage ?? "",
            identifier: epubIdentifier ?? "",
            epubVersion: epubVersion ?? ""
        )
    }

    /// The audio metadata the library keeps for this book, which Book Info
    /// shows while the file is only in the cloud: its names, its measured
    /// length, and its file's type. An album, genre, or year the library
    /// keeps none of shows empty; a save that leaves it empty leaves it
    /// unknown (`Book.MetadataEdit`), so the file's tags show once the book
    /// is downloaded.
    var storedAudioMetadata: AudioMetadata {
        mergingEditableAudioMetadata(AudioMetadata(
            duration: audioDuration.map(TimeFormatting.format) ?? "",
            fileFormat: bookFileURL.pathExtension.uppercased()
        ))
    }
}
