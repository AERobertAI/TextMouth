import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Subscriptions in OPML (FR03): reading the lists other feed readers
/// export, nested categories, letter case, duplicates, and damaged markup
/// included, never loading an external entity; writing them, so a list
/// TextMouth exports reads back the same; importing a list into a folder the
/// listener picks, each feed into a folder of its own, saying how it went,
/// the picker's Create taking the Return key from Import while its New
/// Folder fields are shown; and exporting to a file. Feeds are served by a
/// stub server.
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
        // Tabs and line breaks are written as character references, which an attribute keeps;
        // the shared writer (XMLEscaping) leaves an apostrophe, which a double-quoted attribute may hold.
        feed.title = "a\tb\nc'"
        let written = String(decoding: FeedOPML.document(listing: [feed], title: "t", date: date), as: UTF8.self)
        XCTAssertTrue(written.contains("text=\"a&#9;b&#10;c'\""), written)
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

    /// A title holding a Windows line break (CR LF, one Character in Swift)
    /// reads back with it, as do an old Mac one (CR) and a line feed: each is
    /// written as character references, which XML keeps, where a raw break
    /// in an attribute reads back as a space. So does a title whose "&",
    /// "<", or quote has a combining accent after it, making one Character
    /// with it, which written raw would break the markup.
    func testLineBreaksAndAccentedMarkupInATitleReadBackTheSame() throws {
        var feed = Feed(feedURL: try XCTUnwrap(URL(string: "https://locks.example/feed.xml")), folderID: UUID(), subscribedDate: Date())
        // Each title in a list of its own, so a title that breaks the markup
        // can't hide what happens to the other.
        for title in ["Locks\r\nand Weirs\rof the\nCanal", "Weirs &\u{301} Locks <\u{301} \"\u{301}"] {
            feed.title = title
            let data = FeedOPML.document(listing: [feed], title: "Line\r\nbreaks", date: Date())

            XCTAssertEqual(try FeedOPML.subscriptions(in: data).map(\.title), [title], String(decoding: data, as: UTF8.self))
        }
        // A form feed or another character XML forbids is left out, so the document still reads.
        feed.title = "Locks\u{0C}and\u{01}Weirs\r\nof"
        let written = String(decoding: FeedOPML.document(listing: [feed], title: "t", date: Date()), as: UTF8.self)
        XCTAssertTrue(written.contains("text=\"Locks andWeirs&#13;&#10;of\""), written)
        XCTAssertEqual(try FeedOPML.subscriptions(in: Data(written.utf8)).map(\.title), ["Locks andWeirs\r\nof"])
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

    /// A feed the file lists that is in the library already, unsubscribed
    /// from (FR11, branch D), stays as the listener chose, unsubscribed, and
    /// the import names it by the library's title, saying Resubscribe checks
    /// it again, rather than calling it subscribed already (REV11, board
    /// #1814).
    func testAnImportNamesAFeedYouUnsubscribedFrom() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLUnsubscribed")
        world.server.serve("/old.xml", .feed(FeedXML.rss(title: "Old Friend", items: [Self.item])))
        let old = try await world.subscribe("/old.xml")
        world.center.unsubscribe(old.id)
        var heard: [String] = []
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "Old Friend, from my other reader", feedURL: world.server.url("/old.xml"), siteURL: nil)],
            center: world.center,
            parentPath: world.folder.path,
            announce: { heard.append($0) }
        )

        await model.start()?.value

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.unsubscribed, ["Old Friend"])
        XCTAssertEqual(summary.alreadySubscribed, [])
        XCTAssertEqual(summary.subscribed, [])
        XCTAssertEqual(
            summary.sentence,
            "No feed was subscribed to. Old Friend is in your library, unsubscribed. "
                + "Choose Resubscribe on its row, or in its Feed Info, to check it again."
        )
        XCTAssertEqual(heard, [summary.sentence])
        XCTAssertEqual(world.center.store.record(of: old.id)?.feed.isSubscribed, false, "the import resubscribed the feed")
        XCTAssertEqual(
            FeedWording.importFoundUnsubscribed(["Old Friend", "Night Trams"]),
            "Old Friend and Night Trams are in your library, unsubscribed. "
                + "Choose Resubscribe on a feed's row, or in its Feed Info, to check it again."
        )
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
        // The alert speaks for itself (REV14 feeds 6).
        XCTAssertEqual(heard, [], "the alert's words were announced too")
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
        XCTAssertEqual(heard, [], "the alert's words were announced too")

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

    /// An export leaves out a feed the listener unsubscribed from (FR11,
    /// branch D), which is no subscription, so another reader importing the
    /// file never subscribes to it again, and says how many it left out;
    /// with every feed unsubscribed from, it says there is nothing to export
    /// and why (REV11, board #1814).
    func testAnExportLeavesOutTheFeedsYouUnsubscribedFrom() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLExportUnsubscribed")
        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        world.server.serve("/harbour.xml", .feed(FeedXML.rss(title: "Harbour Notes", items: [Self.item])))
        let atlas = try await world.subscribe("/atlas.xml")
        let outcome = try await world.center.subscribe(
            to: world.server.url("/harbour.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let harbour) = outcome else { return XCTFail("\(outcome)") }
        world.center.unsubscribe(harbour.id)
        let file = try makeSandboxDirectory("FeedUIOPMLExportUnsubscribedFolder").appendingPathComponent("Mine.opml")

        presenter.exportOPML(to: file, in: context)

        let read = try FeedOPML.subscriptions(in: Data(contentsOf: file))
        XCTAssertEqual(read.map(\.title), ["The Tactile Atlas"])
        XCTAssertEqual(heard.last, "Exported 1 subscription to Mine.opml. 1 feed you unsubscribed from was left out.")
        XCTAssertEqual(
            FeedWording.exported(count: 0, fileName: "Mine.opml", unsubscribedCount: 2),
            "Exported 0 subscriptions to Mine.opml. 2 feeds you unsubscribed from were left out."
        )

        world.center.unsubscribe(atlas.id)
        presenter.chooseOPMLDestination(in: context)
        XCTAssertEqual(presenter.notice?.message, "There are no subscriptions to export: every feed in your library is unsubscribed.")
        XCTAssertEqual(FeedWording.nothingSubscribedToExport, presenter.notice?.message)
        XCTAssertFalse(heard.contains(FeedWording.nothingSubscribedToExport), "the alert's words were announced too")
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

    // MARK: - The Return Key

    /// With the new folder's fields shown and keyboard focus in the name
    /// field, Return presses the picker's Create and never Import: a folder
    /// that can't be made keeps the fields, and Return tries again; with no
    /// name typed, Return imports nothing; once the folder is made and the
    /// fields close, Return imports into it.
    func testReturnCreatesTheNewFolderWhileItsFieldsAreShownAndImportsOtherwise() throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLReturn")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        guard startTurningTheRunLoop(world) else { return }
        var heard: [String] = []
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "The Tactile Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil)],
            center: world.center,
            parentPath: "",
            announce: { heard.append($0) }
        )
        let creates = CallLog<String>()
        // The world's own folder stands for the folder made, as in the Add
        // Feed test: in the pop-up from the start, so it can show as chosen
        // once "made", and the feed's folder really goes inside it. The
        // first try is refused, as a name in use is, and the second works.
        let folderName = world.folder.path
        let sheet = OPMLImportSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { name, parent in
                creates.record(parent.isEmpty ? name : "\(parent)/\(name)")
                return creates.calls.count == 1
                    ? .failure("Could not create folder: refused once for the test")
                    : .success(nil)
            },
            onClose: {},
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 520, height: 480), until: { !self.newFolderNameFields(in: $0).isEmpty }) { hosting in
            try typeNewFolderName(folderName, in: hosting)
            guard pressReturnKey(in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(creates.calls, [folderName], "Return did not press Create")
            settleHostedView(hosting)
            XCTAssertFalse(model.isRunning || model.summary != nil, "Return pressed Import as well")

            // Refused, the fields stay with the name. With the name cleared,
            // Create is unavailable, and Return imports nothing.
            XCTAssertEqual(newFolderNameFields(in: hosting).count, 1, "the refused folder's fields closed")
            try typeNewFolderName("", in: hosting)
            XCTAssertFalse(pressReturnKey(in: hosting), "a button took Return with no name typed")
            settleHostedView(hosting)
            XCTAssertEqual(creates.calls.count, 1, "Return pressed Create with no name")
            XCTAssertFalse(model.isRunning || model.summary != nil, "Return pressed Import with the fields shown")

            // Typed again, the name makes the folder, which is the place
            // chosen, and the fields are gone, so Return imports into it.
            try typeNewFolderName(folderName, in: hosting)
            XCTAssertTrue(pressReturnKey(in: hosting))
            XCTAssertEqual(creates.calls, [folderName, folderName], "Return did not press Create again")
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return self.newFolderNameFields(in: hosting).isEmpty
            }, "the made folder's fields stayed open")
            let popUp = descendants(of: hosting, as: NSPopUpButton.self).first
            XCTAssertTrue(waitUntil { popUp?.titleOfSelectedItem == folderName }, "the place chosen is \(popUp?.titleOfSelectedItem ?? "none")")
            settleHostedView(hosting)
            XCTAssertTrue(pressReturnKey(in: hosting))
            XCTAssertTrue(waitUntil(timeout: 10) { model.summary != nil }, "Return did not press Import once the fields closed")
            XCTAssertEqual(creates.calls.count, 2, "Return pressed Create once the fields closed")
        }
        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.subscribed, ["The Tactile Atlas"])
        XCTAssertEqual(heard, [summary.sentence])
        let feed = try XCTUnwrap(world.center.feeds.first { $0.title == "The Tactile Atlas" })
        XCTAssertEqual(world.library.feedFolderPath(forFolderID: feed.folderID), "\(folderName)/The Tactile Atlas")
    }

    /// Once the import has ended, Return presses Done, with the new folder's
    /// fields shown or not: they are unavailable then, with the picker.
    func testReturnPressesDoneOnceTheImportHasEnded() throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLDone")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        guard startTurningTheRunLoop(world) else { return }
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "The Tactile Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil)],
            center: world.center,
            parentPath: world.folder.path,
            announce: { _ in }
        )
        var closes = 0
        let sheet = OPMLImportSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onClose: { closes += 1 },
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 520, height: 480), until: { !self.newFolderNameFields(in: $0).isEmpty }) { hosting in
            try typeNewFolderName("Shows", in: hosting)

            // Import pressed as a click presses it, with the fields shown.
            model.start()
            XCTAssertTrue(waitUntil(timeout: 10) { model.summary != nil }, "the import did not end")
            settleHostedView(hosting)
            guard pressReturnKey(in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(closes, 1, "Return did not press Done")
        }
    }

    /// While the new folder's fields are shown, Escape closes them, says
    /// so, and keeps the place chosen, rather than closing the sheet; once
    /// they are closed, a second Escape presses Cancel. Until October 10,
    /// 2026 the first Escape pressed Cancel.
    func testEscapeClosesTheNewFolderFieldsBeforeTheSheet() throws {
        let world = try FeedTestWorld(self, label: "FeedUIOPMLEscape")
        guard startTurningTheRunLoop(world) else { return }
        let model = OPMLImportModel(
            fileName: "subscriptions.opml",
            subscriptions: [OPMLSubscription(title: "The Tactile Atlas", feedURL: world.server.url("/atlas.xml"), siteURL: nil)],
            center: world.center,
            parentPath: world.folder.path,
            announce: { _ in }
        )
        var closes = 0
        let sheet = OPMLImportSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onClose: { closes += 1 },
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 520, height: 480), until: { !self.newFolderNameFields(in: $0).isEmpty }) { hosting in
            try typeNewFolderName("Shows", in: hosting)
            let recorder = try recordingAnnouncements {
                guard pressKey(.escape, in: hosting) else {
                    throw XCTSkip("This macOS hands an offscreen window no key equivalents")
                }
                XCTAssertTrue(waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return self.newFolderNameFields(in: hosting).isEmpty
                }, "Escape left the fields open")
            }
            XCTAssertEqual(closes, 0, "Escape pressed Cancel with the fields open")
            XCTAssertEqual(recorder.announcements.map(\.message), [
                LibraryFolderPicker.newFolderCancelledAnnouncement(pickerLabel: FeedWording.importFolderLabel, chosen: world.folder.path)
            ])

            settleHostedView(hosting)
            XCTAssertTrue(pressKey(.escape, in: hosting), "nothing took the second Escape")
            XCTAssertEqual(closes, 1, "the second Escape did not press Cancel")
        }
        XCTAssertFalse(model.isRunning, "an import started")
        XCTAssertNil(model.summary)
    }

    // MARK: - Helpers

    /// An episode every test feed lists.
    private static let item = FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/1.mp3")
}
