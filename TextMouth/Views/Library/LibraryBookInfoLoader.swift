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
    /// Whether the file at a URL is only in the cloud.
    var isDataless: @Sendable (URL) -> Bool
    /// Reads the metadata of the EPUB file at a URL.
    var readEPUBMetadata: @Sendable (URL) throws -> EPUBMetadata
    /// Reads the metadata of the audio file at a URL.
    var readAudioMetadata: @Sendable (URL) async -> AudioMetadata

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

    /// What Book Info shows for `book`, with every read of its file made off
    /// the main thread. The library's own edits are laid over what the file
    /// says, as the editors expect.
    @MainActor
    func info(for book: Book) async -> LibraryBookInfo {
        let file = book.bookFileURL
        let reader = self
        switch book.format {
        case .epub:
            let read = await Task.detached(priority: .userInitiated) { reader.readEPUB(at: file) }.value
            switch read {
            case .metadata(let metadata):
                return .epub(book.mergingEditableEPUBMetadata(metadata), isCloudOnly: false)
            case .onlyInCloud:
                return .epub(book.storedEPUBMetadata, isCloudOnly: true)
            case .unreadable:
                return .simple
            }
        case .audio:
            let isCloudOnly = await Task.detached(priority: .userInitiated) { reader.isDataless(file) }.value
            if isCloudOnly {
                return .audio(book.storedAudioMetadata, isCloudOnly: true)
            }
            let tags = await Task.detached(priority: .userInitiated) { await reader.readAudioMetadata(file) }.value
            return .audio(book.mergingEditableAudioMetadata(tags), isCloudOnly: false)
        case .txt, .markdown, .html, .docx, .daisy, .pdf:
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

    /// Reads the metadata of the EPUB at `file` on the calling thread,
    /// unless the file is only in the cloud. A file evicted after the check
    /// counts as only in the cloud too.
    private func readEPUB(at file: URL) -> EPUBRead {
        if isDataless(file) {
            return .onlyInCloud
        }
        do {
            return .metadata(try readEPUBMetadata(file))
        } catch {
            return DatalessFiles.isDownloadRefusal(error) || isDataless(file) ? .onlyInCloud : .unreadable
        }
    }
}

extension Book {
    /// The EPUB metadata the library keeps for this book, which Book Info
    /// shows while the file is only in the cloud.
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
    /// length, and its file's type.
    var storedAudioMetadata: AudioMetadata {
        mergingEditableAudioMetadata(AudioMetadata(
            duration: audioDuration.map(TimeFormatting.format) ?? "",
            fileFormat: bookFileURL.pathExtension.uppercased()
        ))
    }
}
