import Foundation
import XCTest
@testable import TextMouth

// MARK: - The User's Two Feeds (FR11)

/// The user's two feeds as their records stood on October 7, 2026
/// (FEED-ITEMS-RESEARCH-2026-10-07.md, section 6, read then without
/// changing anything), made again in a test's world, so the move to the
/// "List and download" choice and its first launch are tested on records
/// shaped like the user's. The user's own library is never read.
///
/// - "Finish It!": 381 episodes, one a week, the newest the day before the
///   world's clock, each about 63 MB (the newest 5 come to 315.8 MB, as the
///   user's do); every entry kept through the feed's own override of -1;
///   none downloaded, none played; and "Ep. 368", whose download was deleted
///   25 seconds after it finished, unplayed, which kept nothing.
/// - "The Digital Antiquarian": its 10 newest entries, kept under the
///   global number, 8 articles and 2 episodes (a 5.7 MB video, played as
///   audio, and a 2.1 MB episode), the second newest an article downloaded
///   as `articleBookID`, which the user opened.
///
/// Their episodes' addresses are the world's stub server's, so a test that
/// serves them can download them; nothing here serves them.
@MainActor
struct UsersFeeds {
    /// "Finish It!"'s record.
    let finishIt: FeedRecord
    /// "The Digital Antiquarian"'s record.
    let antiquarian: FeedRecord
    /// The book the downloaded article of "The Digital Antiquarian" is.
    let articleBookID = UUID()

    /// How many bytes each of "Finish It!"'s episodes says it has.
    static let finishItEpisodeBytes: Int64 = 63_160_000

    /// The two records, in `world`: "Finish It!" downloading into the
    /// world's folder, and "The Digital Antiquarian" into a folder of its own
    /// made inside it.
    init(_ world: FeedTestWorld) throws {
        let subscribed = world.day(-0.5)
        var finishItFeed = Feed(
            id: try XCTUnwrap(UUID(uuidString: "74086855-5F3A-4C1E-9B2D-6A1E8F0C3D21")),
            feedURL: world.server.url("/finish-it.xml"),
            folderID: world.bookFolder.id,
            subscribedDate: subscribed
        )
        finishItFeed.title = "Finish It!"
        finishItFeed.keepEntriesOverride = -1
        finishItFeed.entryTotal = FeedEntryTotal(count: 381)
        finishItFeed.updatedDate = subscribed
        let episodes = (1...381).reversed().map { number -> FeedItem in
            var item = FeedItem(
                id: "guid:finish-it-\(number)",
                guid: "finish-it-\(number)",
                title: "Ep. \(number)",
                summary: Self.text("Episode \(number) of a show about finishing things."),
                published: world.day(-1 - Double(381 - number) * 7),
                firstSeen: subscribed,
                enclosure: FeedEnclosure(
                    url: world.server.url("/finish-it/\(number).m4a"),
                    mimeType: "audio/mp4",
                    length: Self.finishItEpisodeBytes
                ),
                duration: 64 * 60,
                episodeNumber: number
            )
            if number == 368 {
                item.downloadDeletedDate = subscribed.addingTimeInterval(-60)
            }
            return item
        }
        finishIt = FeedRecord(feed: finishItFeed, items: episodes)

        var antiquarianFeed = Feed(
            id: try XCTUnwrap(UUID(uuidString: "6452A5C0-8D1B-4E7A-A3F6-2C9B0E5D7F14")),
            feedURL: world.server.url("/antiquarian.xml"),
            folderID: try world.library.makeFeedFolder(named: "The Digital Antiquarian", inParentPath: world.folder.path),
            subscribedDate: subscribed
        )
        antiquarianFeed.title = "The Digital Antiquarian"
        antiquarianFeed.updatedDate = subscribed
        let downloaded = articleBookID
        let entries: [(title: String, enclosure: FeedEnclosure?)] = [
            ("The Story of Zork, Part 4", nil),
            ("The Lamentable Later Life of Lemmings", nil),
            ("A Visit to the Computer Museum", FeedEnclosure(url: world.server.url("/antiquarian/museum.mp4"), mimeType: "video/mp4", length: 5_700_000)),
            ("Infocom's Last Days", nil),
            ("Reading Aloud in 1984", FeedEnclosure(url: world.server.url("/antiquarian/reading.m4a"), mimeType: "audio/mp4", length: 2_100_000)),
            ("The Story of Zork, Part 3", nil),
            ("The Story of Zork, Part 2", nil),
            ("The Story of Zork, Part 1", nil),
            ("Before the Text Adventure", nil),
            ("A Note on Sources", nil),
        ]
        let items = entries.enumerated().map { index, entry -> FeedItem in
            FeedItem(
                id: "guid:antiquarian-\(index)",
                guid: "antiquarian-\(index)",
                title: entry.title,
                content: entry.enclosure == nil ? Self.text(Self.article(entry.title)) : nil,
                published: world.day(-2 - Double(index) * 7),
                firstSeen: subscribed,
                enclosure: entry.enclosure,
                state: index == 1 ? .downloaded(bookID: downloaded) : .notDownloaded
            )
        }
        antiquarian = FeedRecord(feed: antiquarianFeed, items: items)
    }

    /// The downloaded article's row, as each feed's own index holds it since
    /// FR11's branch A1 moved it into its feed's folder: opened a day before
    /// the world's clock, with a reading position, no bookmarks, and no voice
    /// or speed of its own. A test adds it to its library's books, where a
    /// row whose file is here lives while TextMouth runs; nothing reads its
    /// file.
    func articleRow(in world: FeedTestWorld) -> Book {
        let title = "The Lamentable Later Life of Lemmings"
        let name = "\(title).tmb"
        let package = FeedPaths.packageDirectory(named: name, of: antiquarian.feed.id, in: TextMouthPaths.root)
        return Book(
            id: articleBookID,
            title: title,
            author: "The Digital Antiquarian",
            format: .html,
            filePath: package.appendingPathComponent("\(title).html").path,
            md5Hash: "lemmings",
            dateAdded: world.day(-9),
            lastOpened: world.day(-1),
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 4_200),
            tmbDirectoryName: name,
            feedLink: FeedBookLink(feedID: antiquarian.feed.id, itemID: "guid:antiquarian-1")
        )
    }

    /// Writes both records into `world`'s Feeds folder, as the records the
    /// engine reads when it starts.
    func write(to world: FeedTestWorld) throws {
        try FileManager.default.createDirectory(at: world.recordsFolder, withIntermediateDirectories: true)
        for record in [finishIt, antiquarian] {
            let data = try FeedRecordCoding.encoder().encode(record)
            try data.write(to: FeedPaths.recordFile(of: record.feed.id, in: world.recordsFolder), options: .atomic)
        }
    }

    /// A text as a feed gives one, read as the reconciler reads it.
    private static func text(_ plain: String) -> FeedText {
        FeedText(html: "<p>\(plain)</p>", plainText: plain, markdown: plain)
    }

    /// An article's text, long enough that its download never fetches its
    /// web page (`FeedEpisodeImporter.shortArticleWords`).
    private static func article(_ title: String) -> String {
        "\(title). " + (1...60).map { "Paragraph \($0) says what the games were like." }.joined(separator: " ")
    }
}
