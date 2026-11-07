import SwiftUI

// MARK: - Book Info of an Episode or Article in Its Feed (FR11)

extension Book {
    /// Whether Book Info shows this book read-only, with no metadata editor
    /// and no Save (FR11, branch C; the user's answer to late question 4):
    /// while it is an episode or article in its feed, whose details come
    /// from the feed. The Library's Book Info, the reader's, and the
    /// reader's Book Info button all ask this.
    var hasReadOnlyBookInfo: Bool {
        isFeedItem
    }
}

extension LibraryViewModel {
    /// The title of the feed `book` belongs to while it is an episode or
    /// article in its feed (FR11), as Speak Info and Book Info name it, its
    /// feed subscribed or not (FR11, branch D); nil for a book of the
    /// library's own, or once its feed's record is gone.
    func feedTitle(of book: Book) -> String? {
        book.feedLink.flatMap { feeds.store.record(of: $0.feedID)?.feed.title }
    }
}

/// One labelled detail of a read-only Book Info: what it is, its value as
/// shown, and, where VoiceOver should say it otherwise, as spoken. VoiceOver
/// reads each as one element: "Title, Ep. 368".
struct BookInfoDetail: Equatable, Sendable {
    /// What the detail is: "Title".
    let label: String
    /// The value as shown: "1:04:00".
    let value: String
    /// The value as VoiceOver says it, where it differs from what is shown:
    /// "1 hour, 4 minutes"; nil to say it as shown.
    var spokenValue: String? = nil
}

/// Book Info for an episode or article while it belongs to its feed (FR11,
/// branch C): its details as the feed gave them, none of which can be
/// edited, so no field takes typing and there is no metadata editor and no
/// Save. A line under the heading says why. Each detail is a labelled value
/// VoiceOver reads as one element, whose value can be selected and copied;
/// Done closes the sheet, as Return and Escape do.
struct FeedItemBookInfoSheet: View {
    /// The episode or article.
    let book: Book
    /// What was read of its file, for an episode's tags, or what the
    /// library keeps while its file is only in the cloud.
    let info: LibraryBookInfo
    /// The title of the feed it belongs to, while the feed's record is here.
    let feedTitle: String?
    /// What the episode's transcript came from, once it has been read; empty
    /// until then, and for an episode or article without a transcript.
    @StateObject private var transcript = TranscriptBookInfoModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FeedItemBookInfoWording.heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // Why nothing here can be changed, read before the details.
            Text(FeedItemBookInfoWording.whyReadOnly(isArticle: !book.format.isAudio))
                .fixedSize(horizontal: false, vertical: true)
            if info.isCloudOnly {
                Label(LibraryBookInfo.cloudOnlyNote, systemImage: "cloud")
                    .font(.callout)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        FeedItemBookInfoWording.details(of: book, info: info, feedTitle: feedTitle, transcriptLine: transcript.line),
                        id: \.label
                    ) { detail in
                        FeedInfoValue(label: detail.label, value: detail.value, spokenValue: detail.spokenValue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                // Return presses Done: nothing in the sheet takes typing. A
                // button carries one shortcut, so Escape closes the sheet
                // through the key equivalent below instead.
                Button(FeedItemBookInfoWording.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 450, height: 440)
        .navigationTitle("Info: \(book.title)")
        // The transcript is read off the main thread, without downloading
        // it; its row appears once it has answered, in the scrolling list,
        // so the sheet keeps its size.
        .task(id: book.id) {
            await transcript.load(for: book)
        }
        // Escape closes the sheet too, wherever focus is, as Return does.
        .background(SilentKeyEquivalent(key: .escape, action: { dismiss() }))
    }
}

// MARK: - Words

/// The words of an episode's or article's read-only Book Info (FR11, branch
/// C), and of the reader's Book Info button, which says whether Book Info
/// edits.
enum FeedItemBookInfoWording {
    /// The sheet's heading, as every Book Info's.
    static let heading = "Book Information"
    /// The button that closes the sheet.
    static let done = "Done"

    /// The line under the heading saying why nothing can be changed, and
    /// the way out (FR11, branch D): "An episode's details come from its
    /// feed; Move to Library… makes it a book you can edit."
    static func whyReadOnly(isArticle: Bool) -> String {
        "\(isArticle ? "An article's" : "An episode's") details come from its feed; "
            + "\(ShortcutAction.moveToLibrary.title) makes it a book you can edit."
    }

    /// What VoiceOver says for the reader's Book Info button: "Edit book
    /// metadata" for a book the listener can edit, and "Show book
    /// information" for an episode or article in its feed, whose Book Info
    /// is read-only (`Book.hasReadOnlyBookInfo`).
    static func readerButtonLabel(readOnly: Bool) -> String {
        readOnly ? "Show book information" : "Edit book metadata"
    }

    /// The details of `book`, an episode or article, in the order the sheet
    /// shows them, each left out when it has no value: its title, its
    /// artist (an episode) or author, the title of its feed (`feedTitle`)
    /// where a book's Speak Info names its folder, an episode's album,
    /// genre, year, duration, and file format from `info`, an article's
    /// format and word count, and when it was added and last opened. An
    /// episode's duration is the measured one when the library has it,
    /// spoken in words. An episode's "Transcript" follows its format, saying
    /// where its transcript came from (`transcriptLine`,
    /// `TranscriptStore.bookInfoLine(for:)`), and is left out without one.
    static func details(
        of book: Book,
        info: LibraryBookInfo,
        feedTitle: String?,
        transcriptLine: String? = nil
    ) -> [BookInfoDetail] {
        var details = [BookInfoDetail(label: "Title", value: book.title)]
        switch info {
        case .audio(let metadata, _):
            details.append(BookInfoDetail(label: "Artist", value: metadata.artist))
            details.append(BookInfoDetail(label: "Feed", value: feedTitle ?? ""))
            details.append(BookInfoDetail(label: "Album", value: metadata.album))
            details.append(BookInfoDetail(label: "Genre", value: metadata.genre))
            details.append(BookInfoDetail(label: "Year", value: metadata.year))
            details.append(duration(of: book, read: metadata.duration))
            details.append(BookInfoDetail(label: "Format", value: metadata.fileFormat))
            details.append(BookInfoDetail(label: TranscriptionWording.bookInfoLabel, value: transcriptLine ?? ""))
        case .epub, .simple:
            details.append(BookInfoDetail(label: "Author", value: book.author))
            details.append(BookInfoDetail(label: "Feed", value: feedTitle ?? ""))
            details.append(BookInfoDetail(label: "Format", value: book.format.displayName))
            if let words = book.totalWordCount {
                details.append(BookInfoDetail(label: "Word count", value: "\(words)"))
            }
        }
        details.append(BookInfoDetail(label: "Added", value: FeedWording.itemDate(book.dateAdded)))
        if let lastOpened = book.lastOpened {
            details.append(BookInfoDetail(label: "Last opened", value: FeedWording.itemDate(lastOpened)))
        }
        return details.filter { !$0.value.isEmpty }
    }

    /// An episode's duration: the one the library measured, shown as the
    /// clock shows it and spoken in words, or else `read`, the one its tags
    /// gave, as given.
    private static func duration(of book: Book, read: String) -> BookInfoDetail {
        guard let measured = book.audioDuration, measured.isFinite, measured > 0 else {
            return BookInfoDetail(label: "Duration", value: read)
        }
        return BookInfoDetail(label: "Duration", value: TimeFormatting.format(measured), spokenValue: TimeFormatting.spoken(measured))
    }
}
