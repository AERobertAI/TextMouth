import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Subscriptions in OPML (FR03): reading the lists other feed readers
/// export, nested categories, letter case, duplicates, and damaged markup
/// included, never loading an external entity; writing them, so a list
/// TextMouth exports reads back the same; importing a list into a folder the
/// listener picks, each feed into a folder of its own, saying how it went;
/// and exporting to a file. Feeds are served by a stub server.
@MainActor
final class FeedUIOPMLTests: XCTestCase {

    // MARK: - Reading

    /// A reader's export gives each feed once, in document order, from any
    /// depth of categories, whatever the letter case of its address's
    /// attribute; categories and addresses that are not web addresses give
    /// nothing, and a feed: link is read as https.
    func testReadingAnotherReadersExport() throws {
        let data = try Data(contentsOf: try requireFile("feeds/opml-subscriptions.opml"))

        let subscriptions = try FeedOPML.subscriptions(in: data)

        XCTAssertEqual(subscriptions.map(\.title), ["The Tactile Atlas", "Harbour Notes & Tides", "Night Trams"])
        XCTAssertEqual(subscriptions.map(\.feedURL.absoluteString), [
            "https://atlas.example/feed.xml",
            "http://harbour.example/rss",
            "https://trams.example/atom",
        ])
        XCTAssertEqual(subscriptions.first?.siteURL?.absoluteString, "https://atlas.example/")
        XCTAssertNil(subscriptions.last?.siteURL)
    }

    /// A list whose markup is not well-formed, as with a bare "&" in a
    /// title, is read after XMLDocument's tidying.
    func testADamagedListIsReadAfterTidying() throws {
        let data = try Data(contentsOf: try requireFile("feeds/opml-damaged.opml"))

        let subscriptions = try FeedOPML.subscriptions(in: data)

        XCTAssertEqual(subscriptions.map(\.feedURL.absoluteString), ["https://qa.example/feed", "https://second.example/feed"])
        XCTAssertEqual(subscriptions.last?.title, "Second Show")
        XCTAssertTrue(subscriptions.first?.title.hasPrefix("Q") ?? false, subscriptions.first?.title ?? "")
    }

    /// A feed, an empty file, and a list with no feeds are each said
    /// plainly.
    func testWhatIsNoListIsSaidPlainly() throws {
        let feed = try Data(contentsOf: try requireFile("feeds/anchor-episodic.xml"))
        XCTAssertThrowsError(try FeedOPML.subscriptions(in: feed)) { error in
            XCTAssertEqual(error as? OPMLReadError, .notOPML)
        }
        XCTAssertThrowsError(try FeedOPML.subscriptions(in: Data("  \n".utf8))) { error in
            XCTAssertEqual(error as? OPMLReadError, .empty)
        }
        let empty = Data("<opml version=\"2.0\"><head/><body><outline text=\"Category\"/></body></opml>".utf8)
        XCTAssertThrowsError(try FeedOPML.subscriptions(in: empty)) { error in
            XCTAssertEqual(error as? OPMLReadError, .noFeeds)
        }
        XCTAssertEqual(OPMLReadError.notOPML.message, "That file isn't an OPML list of subscriptions.")
        XCTAssertEqual(OPMLReadError.noFeeds.message, "That OPML file lists no feeds.")
    }

    /// An external entity is never loaded, however the list names it.
    func testAnExternalEntityIsNeverLoaded() throws {
        let markup = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE opml [<!ENTITY secret SYSTEM "file:///etc/hosts">]>
        <opml version="2.0"><body>
        <outline type="rss" text="Leak &secret;" xmlUrl="https://leak.example/feed"/>
        </body></opml>
        """
        let subscriptions = (try? FeedOPML.subscriptions(in: Data(markup.utf8))) ?? []
        for subscription in subscriptions {
            XCTAssertFalse(subscription.title.contains("localhost"), "an external entity was loaded: \(subscription.title)")
        }
    }

    // MARK: - Writing

    /// The exported document lists each feed as an outline of type "rss",
    /// with its title as text and title, its address, and its web site,
    /// every character escaped.
    func testTheExportedDocument() throws {
        var feed = Feed(feedURL: try XCTUnwrap(URL(string: "https://atlas.example/feed.xml?a=1&b=2")), folderID: UUID(), subscribedDate: Date())
        feed.title = "Maps & \"Tides\" <Live>"
        feed.siteLink = URL(string: "https://atlas.example/")
        let date = Date(timeIntervalSince1970: 1_791_000_000)

        let text = String(decoding: FeedOPML.document(listing: [feed], title: "TextMouth Subscriptions", date: date), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">"), text)
        XCTAssertTrue(text.contains("<title>TextMouth Subscriptions</title>"), text)
        XCTAssertTrue(text.contains("<dateCreated>\(FeedOPML.rfc822(date))</dateCreated>"), text)
        XCTAssertTrue(text.contains(
            "<outline type=\"rss\" text=\"Maps &amp; &quot;Tides&quot; &lt;Live&gt;\" title=\"Maps &amp; &quot;Tides&quot; &lt;Live&gt;\" "
                + "xmlUrl=\"https://atlas.example/feed.xml?a=1&amp;b=2\" htmlUrl=\"https://atlas.example/\"/>"
        ), text)
        XCTAssertEqual(FeedOPML.rfc822(date), "Sat, 03 Oct 2026 04:00:00 GMT")
        XCTAssertEqual(FeedOPML.escaped("a\tb\nc'"), "a&#9;b&#10;c&apos;")
    }

    /// A list TextMouth exports reads back as the same subscriptions.
    func testAnExportReadsBackTheSame() throws {
        let folderID = UUID()
        var first = Feed(feedURL: try XCTUnwrap(URL(string: "https://atlas.example/feed.xml")), folderID: folderID, subscribedDate: Date())
        first.title = "The Tactile Atlas"
        first.siteLink = URL(string: "https://atlas.example/")
        var second = Feed(feedURL: try XCTUnwrap(URL(string: "http://harbour.example/rss?x=1&y=2")), folderID: folderID, subscribedDate: Date())
        second.title = "Harbour Notes & Tides\tby the 'Pier'"

        let data = FeedOPML.document(listing: [first, second], title: "Round trip", date: Date())
        let read = try FeedOPML.subscriptions(in: data)

        XCTAssertEqual(read, [
            OPMLSubscription(title: first.title, feedURL: first.feedURL, siteURL: first.siteLink),
            OPMLSubscription(title: second.title, feedURL: second.feedURL, siteURL: nil),
        ])
    }

    // MARK: - Importing

    /// An import subscribes to each feed in turn, each into a folder of its
    /// own inside the folder picked, leaves a feed subscribed already as it
    /// was, names the failures and the plain-http feeds, and says how it
    /// went.
    func testImportingSubscribesEachIntoAFolderOfItsOwn() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLImport")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        world.server.serve("/harbour.xml", .feed(FeedXML.rss(title: "Harbour Notes", items: [Self.item])))
        world.server.serve("/old.xml", .feed(FeedXML.rss(title: "Old Friend", items: [Self.item])))
        world.server.serve("/gone.xml", StubResponse(status: 410))
        _ = try await world.subscribe("/old.xml")
        let subscriptions = [
            OPMLSubscription(title: "The Tactile Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil),
            OPMLSubscription(title: "Old Friend", feedURL: world.server.url("/old.xml"), siteURL: nil),
            OPMLSubscription(title: "Gone Show", feedURL: world.server.url("/gone.xml"), siteURL: nil),
            OPMLSubscription(title: "Harbour Notes", feedURL: world.server.insecureURL("/harbour.xml"), siteURL: nil),
        ]
        var heard: [String] = []
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: subscriptions,
            center: world.center,
            parentPath: world.folder.path,
            announce: { heard.append($0) }
        )

        await model.start()?.value

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.subscribed, ["The Tactile Atlas", "Harbour Notes"])
        XCTAssertEqual(summary.alreadySubscribed, ["Old Friend"])
        XCTAssertEqual(summary.failed.map(\.title), ["Gone Show"])
        XCTAssertEqual(summary.insecure, ["Harbour Notes"])
        XCTAssertFalse(summary.stopped)
        XCTAssertNil(model.progress)
        XCTAssertEqual(heard, [summary.sentence])
        XCTAssertTrue(summary.sentence.hasPrefix("Subscribed to 2 feeds. 1 was subscribed already. Couldn't subscribe to Gone Show ("), summary.sentence)
        for title in ["The Tactile Atlas", "Harbour Notes"] {
            let feed = try XCTUnwrap(world.center.feeds.first { $0.title == title })
            XCTAssertEqual(world.library.feedFolderPath(forFolderID: feed.folderID), "\(world.folder.path)/\(title)")
        }
        XCTAssertNil(model.start(), "an ended import started again")
    }

    /// Stopped before it starts, an import subscribes to nothing and says
    /// it was stopped.
    func testStoppingAnImport() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLStop")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "The Tactile Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil)],
            center: world.center,
            parentPath: world.folder.path,
            announce: { _ in }
        )

        let work = model.start()
        model.stop()
        await work?.value

        XCTAssertEqual(model.summary?.stopped, true)
        XCTAssertEqual(model.summary?.subscribed, [])
        XCTAssertTrue(world.center.feeds.isEmpty)
        XCTAssertEqual(model.summary?.sentence, "No feed was subscribed to. The import was stopped before its end.")
    }

    /// Choosing a list opens the Import OPML sheet with its subscriptions;
    /// a file that is no list is said plainly instead.
    func testChoosingAListOpensTheSheetOrSaysWhy() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLChoose")
        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)

        await presenter.readOPMLFile(try requireFile("feeds/opml-subscriptions.opml"), in: context, parentPath: world.folder.path).value

        XCTAssertEqual(presenter.opmlImport?.subscriptions.count, 3)
        XCTAssertEqual(presenter.opmlImport?.fileName, "opml-subscriptions.opml")
        XCTAssertEqual(presenter.opmlImport?.parentPath, world.folder.path)

        presenter.opmlImport = nil
        await presenter.readOPMLFile(try requireFile("feeds/anchor-episodic.xml"), in: context, parentPath: "").value
        XCTAssertNil(presenter.opmlImport)
        XCTAssertEqual(presenter.notice?.message, OPMLReadError.notOPML.message)
        XCTAssertEqual(heard, [OPMLReadError.notOPML.message])
    }

    // MARK: - Exporting

    /// Exporting writes every subscription to the file chosen and says how
    /// many went where; with none, it says there is nothing to export.
    func testExportingWritesEverySubscription() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLExport")
        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        await world.start()

        presenter.chooseOPMLDestination(in: context)
        XCTAssertEqual(presenter.notice?.message, FeedWording.nothingToExport)

        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        world.server.serve("/harbour.xml", .feed(FeedXML.rss(title: "Harbour Notes", items: [Self.item])))
        _ = try await world.subscribe("/atlas.xml")
        _ = try await world.center.subscribe(to: world.server.url("/harbour.xml").absoluteString, into: .newFolder(inParentPath: world.folder.path))
        let file = try makeSandboxDirectory("FeedUIOPMLExportFolder").appendingPathComponent("Mine.opml")

        presenter.exportOPML(to: file, in: context)

        let read = try FeedOPML.subscriptions(in: Data(contentsOf: file))
        XCTAssertEqual(read.map(\.title), ["Harbour Notes", "The Tactile Atlas"])
        XCTAssertEqual(heard.last, "Exported 2 subscriptions to Mine.opml.")
    }

    // MARK: - The Sheet as Drawn

    /// The Import OPML sheet draws the folder picker, labelled, offering the
    /// top level and the library's folders.
    func testTheImportSheetDrawsItsFolderPicker() throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLDrawn")
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil)],
            center: world.center,
            parentPath: "",
            announce: { _ in }
        )
        let sheet = OPMLImportSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onClose: {}
        )

        withHostedView(sheet, size: NSSize(width: 520, height: 360), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty
        }) { hosting in
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).first?.itemTitles, [LibraryFolderOption.rootLabel, world.folder.path])
            let controls = accessibleControls(in: hosting)
            if !controls.isEmpty {
                XCTAssertNotNil(controls.first { $0.label == FeedWording.importFolderLabel }, "\(controls.map(\.label))")
            }
        }
        XCTAssertEqual(
            FeedWording.importLists(fileName: "subscriptions.opml", count: 1),
            "subscriptions.opml lists 1 feed. Each gets a folder of its own, named after it."
        )
    }

    // MARK: - Helpers

    /// An episode every test feed lists.
    private static let item = FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/1.mp3")
}
