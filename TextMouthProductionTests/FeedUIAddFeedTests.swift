import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Add Feed (FR03), as the listener meets it: a sheet with an address field,
/// which VoiceOver's focus starts in, and the Move dialog's folder picker,
/// choosing where the feed's own folder goes, whose Create takes the Return
/// key from Subscribe while its New Folder fields are shown; subscribing
/// makes a folder named after the feed there, only once the feed has been
/// read; a page naming several feeds turns the sheet to a choice of them,
/// Subscribe taking Return back; a failure stays in the sheet in the
/// engine's words; a plain-http feed is warned about
/// once, as the sheet closes. Every feed is served by a stub server, so no
/// test reaches the network.
@MainActor
final class FeedUIAddFeedTests: XCTestCase {

    // MARK: - A Folder of the Feed's Own

    /// Subscribing into a new folder makes one named after the feed inside
    /// the folder chosen, on disk too, and the feed's downloads go there.
    func testANewFeedGetsAFolderNamedAfterItInsideTheFolderChosen() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolder")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        await world.start()

        let outcome = try await world.center.subscribe(
            to: world.server.url("/feed.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )

        guard case .subscribed(let feed) = outcome else { return XCTFail("expected a subscription, got \(outcome)") }
        let folder = try XCTUnwrap(world.library.library.folders.first { $0.id == feed.folderID })
        XCTAssertEqual(folder.fullPath, "\(world.folder.path)/The Tactile Atlas")
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.folder.url.appendingPathComponent("The Tactile Atlas").path))
        XCTAssertEqual(world.center.feed(inFolder: folder.id)?.id, feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.folderID, folder.id)
    }

    /// A name taken by a folder already there gets the next number.
    func testATakenNameGetsTheNextNumber() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderTaken")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        try world.library.createFolderReturningFolder(name: "The Tactile Atlas", parentPath: world.folder.path)
        try world.library.createFolderReturningFolder(name: "The Tactile Atlas 2", parentPath: world.folder.path)

        let feed = try await subscribeIntoNewFolder(world)

        let path = world.library.feedFolderPath(forFolderID: feed.folderID)
        XCTAssertEqual(path, "\(world.folder.path)/The Tactile Atlas 3")
    }

    /// A subscription that fails makes no folder, and neither does a page
    /// naming several feeds until one of them is subscribed to.
    func testNothingIsMadeUntilASubscriptionSucceeds() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderNothing")
        let first = world.server.url("/one.xml")
        let second = world.server.url("/two.xml")
        world.server.serve("/missing.xml", StubResponse(status: 404))
        world.server.serve("/page.html", StubResponse(
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(FeedXML.page(naming: [first, second]).utf8)
        ))
        world.server.serve("/two.xml", .feed(FeedXML.rss(title: "Second Show", items: [Self.item])))
        await world.start()
        let folders = world.library.library.folders.count
        let choice = FeedFolderChoice.newFolder(inParentPath: world.folder.path)

        do {
            _ = try await world.center.subscribe(to: world.server.url("/missing.xml").absoluteString, into: choice)
            XCTFail("a missing feed was subscribed to")
        } catch {
            XCTAssertEqual(world.library.library.folders.count, folders, "a failed subscription made a folder")
        }

        let page = try await world.center.subscribe(to: world.server.url("/page.html").absoluteString, into: choice)
        XCTAssertEqual(page, .choose([
            FeedLink(url: first, title: nil, mimeType: "application/rss+xml"),
            FeedLink(url: second, title: nil, mimeType: "application/rss+xml"),
        ]))
        XCTAssertEqual(world.library.library.folders.count, folders, "a page naming feeds made a folder")

        let chosen = try await world.center.subscribe(to: second.absoluteString, into: choice)
        guard case .subscribed(let feed) = chosen else { return XCTFail("expected a subscription, got \(chosen)") }
        XCTAssertEqual(world.library.feedFolderPath(forFolderID: feed.folderID), "\(world.folder.path)/Second Show")
    }

    /// A folder chosen to hold the feed's folder that is gone by the time
    /// the feed is read is said plainly, and nothing is subscribed.
    func testAFolderGoneMeanwhileIsSaidPlainly() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderGone")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [Self.item])))
        await world.start()

        do {
            _ = try await world.center.subscribe(
                to: world.server.url("/feed.xml").absoluteString,
                into: .newFolder(inParentPath: "\(world.folder.path)/Not There")
            )
            XCTFail("a feed was subscribed into a folder that is gone")
        } catch let error as FeedSubscribeError {
            XCTAssertEqual(error, .folderNotMade(FeedFolderError(message: FeedFolderNaming.parentMissingMessage)))
            XCTAssertEqual(error.message, FeedFolderNaming.parentMissingMessage)
        }
        XCTAssertTrue(world.center.feeds.isEmpty)
    }

    /// A feed's title becomes a folder name as New Folder would take it,
    /// cut at a word when it runs long, and "Feed" when nothing of it can be
    /// a folder's name; taken names are followed by numbers.
    func testAFeedsTitleBecomesAFolderName() {
        XCTAssertEqual(FeedFolderNaming.baseName(for: "  Planet Money  "), "Planet Money")
        XCTAssertEqual(FeedFolderNaming.baseName(for: "Rivers/Canals"), "Rivers-Canals")
        XCTAssertEqual(FeedFolderNaming.baseName(for: ".."), "Feed")
        XCTAssertEqual(FeedFolderNaming.baseName(for: "Show.tmb"), "Feed")
        let long = Array(repeating: "harbour", count: 20).joined(separator: " ")
        let cut = FeedFolderNaming.baseName(for: long)
        XCTAssertLessThanOrEqual(cut.count, FeedFolderNaming.maximumLength)
        XCTAssertTrue(long.hasPrefix(cut))
        XCTAssertFalse(cut.hasSuffix(" "))
        XCTAssertEqual(FeedFolderNaming.candidates(for: "Atlas").prefix(3), ["Atlas", "Atlas 2", "Atlas 3"])
        XCTAssertEqual(FeedFolderNaming.candidates(for: "Atlas").last, "Atlas 99")
    }

    // MARK: - The Sheet's Work

    /// Subscribe waits for an address that could name a feed.
    func testSubscribeWaitsForAnAddress() throws {
        let world = try FeedTestWorld(self, label: "FeedUIModelEnabled")
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { _ in })

        XCTAssertFalse(model.canSubscribe)
        model.address = "not an address at all"
        XCTAssertFalse(model.canSubscribe)
        model.address = "ftp://files.example/feed"
        XCTAssertFalse(model.canSubscribe)
        model.address = "example.com/feed.xml"
        XCTAssertTrue(model.canSubscribe)
        model.address = "feed://example.com/feed.xml"
        XCTAssertTrue(model.canSubscribe)
    }

    /// Subscribing says it is checking the address, then hands the feed to
    /// the sheet's owner, with its folder made where the sheet said.
    func testSubscribingAnnouncesAndFinishes() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIModelSubscribe")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        await world.start()
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        model.address = world.server.url("/feed.xml").absoluteString

        await model.subscribe()?.value

        let feed = try XCTUnwrap(model.subscribedFeed)
        XCTAssertEqual(feed.title, "The Tactile Atlas")
        XCTAssertEqual(world.library.feedFolderPath(forFolderID: feed.folderID), "\(world.folder.path)/The Tactile Atlas")
        XCTAssertEqual(heard, [FeedWording.checkingAddress])
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.failureMessage)
    }

    /// A page naming several feeds turns the sheet to a choice, the first
    /// chosen, which Subscribe subscribes to; Back returns to the address.
    func testAPageNamingSeveralFeedsTurnsTheSheetToAChoice() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIModelChoice")
        let first = world.server.url("/posts.xml")
        let second = world.server.url("/comments.xml")
        world.server.serve("/page.html", StubResponse(
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(FeedXML.page(naming: [first, second]).utf8)
        ))
        world.server.serve("/posts.xml", .feed(FeedXML.rss(title: "Posts", items: [Self.item])))
        await world.start()
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        model.address = world.server.url("/page.html").absoluteString

        await model.subscribe()?.value

        XCTAssertTrue(model.isChoosing)
        XCTAssertEqual(model.links.map(\.url), [first, second])
        XCTAssertEqual(model.chosenLinkIndex, 0)
        XCTAssertEqual(heard.last, FeedWording.choosePrompt(count: 2))
        XCTAssertNil(model.subscribedFeed)

        model.back()
        XCTAssertFalse(model.isChoosing)
        XCTAssertEqual(model.address, world.server.url("/page.html").absoluteString, "Back lost the address")

        await model.subscribe()?.value
        await model.subscribe()?.value
        XCTAssertEqual(model.subscribedFeed?.title, "Posts")
    }

    /// A failure stays in the sheet, in the engine's words, with the
    /// address as typed, and is announced; typing again clears it.
    func testAFailureStaysInTheSheetInTheEnginesWords() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIModelFailure")
        world.server.serve("/feed.xml", StubResponse(status: 404))
        await world.start()
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        let address = world.server.url("/feed.xml").absoluteString
        model.address = address

        await model.subscribe()?.value

        let expected = FeedSubscribeError.refreshFailed(.fetch(.notFound), host: world.server.host).message
        XCTAssertEqual(model.failureMessage, expected)
        XCTAssertEqual(heard, [FeedWording.checkingAddress, expected])
        XCTAssertEqual(model.address, address)
        XCTAssertNil(model.subscribedFeed)
        XCTAssertTrue(world.center.feeds.isEmpty)
    }

    /// The places offered for a feed's folder: the top level and every
    /// folder shallow enough to hold one more, never a feed's own folder;
    /// New Folder may make one only where it could hold a feed's folder
    /// itself; the window's folder is chosen first when it is offered.
    func testThePlacesOfferedForAFeedsFolder() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIPlaces")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Held Show", items: [Self.item])))
        let base = world.folder.path
        var deepest = base
        for level in 2...BookFolder.maxDepth {
            try world.library.createFolderReturningFolder(name: "Level \(level)", parentPath: deepest)
            deepest += "/Level \(level)"
        }
        let feed = try await subscribeIntoNewFolder(world)
        let feedFolderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let folders = LibraryFeedFolders(center: world.center)

        let parents = AddFeedPlaces.parents(in: world.library.library, feedFolders: folders).map(\.path)
        XCTAssertEqual(parents.first, "", "the top level comes first")
        XCTAssertTrue(parents.contains(base))
        XCTAssertTrue(parents.contains("\(base)/Level 2/Level 3"))
        XCTAssertFalse(parents.contains(deepest), "a folder at the deepest level can't hold a feed's folder")
        XCTAssertFalse(parents.contains(feedFolderPath), "a feed's folder was offered for another feed")

        let newFolderParents = AddFeedPlaces.newFolderParents(in: world.library.library, feedFolders: folders).map(\.path)
        XCTAssertTrue(newFolderParents.contains("\(base)/Level 2"))
        XCTAssertFalse(newFolderParents.contains("\(base)/Level 2/Level 3"))
        XCTAssertFalse(newFolderParents.contains(feedFolderPath))

        XCTAssertEqual(AddFeedPlaces.initialParent(shownPath: base, in: world.library.library, feedFolders: folders), base)
        XCTAssertEqual(AddFeedPlaces.initialParent(shownPath: feedFolderPath, in: world.library.library, feedFolders: folders), "")
        XCTAssertEqual(AddFeedPlaces.initialParent(shownPath: deepest, in: world.library.library, feedFolders: folders), "")
    }

    // MARK: - After the Sheet Closes

    /// A plain-http feed's warning shows once, as the sheet closes, saying
    /// the subscription was made; nothing is announced over it.
    func testAPlainHttpFeedIsWarnedAboutOnceAsTheSheetCloses() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIInsecure")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Open Wire", items: [Self.item])))
        await world.start()
        let presenter = LibraryFeedsPresenter()
        presenter.showAddFeed(center: world.center, parentPath: world.folder.path)
        let model = try XCTUnwrap(presenter.addFeed)
        model.address = world.server.insecureURL("/feed.xml").absoluteString
        await model.subscribe()?.value
        let feed = try XCTUnwrap(model.subscribedFeed)
        XCTAssertTrue(feed.usesInsecureTransport)

        presenter.addFeedSubscribed(feed)
        XCTAssertNil(presenter.addFeed, "the sheet stayed open")
        presenter.addFeedDidClose(in: nil, center: world.center)

        XCTAssertEqual(presenter.notice?.title, FeedWording.insecureTitle)
        XCTAssertEqual(presenter.notice?.message, FeedWording.insecureMessage(title: "Open Wire"))
        XCTAssertEqual(
            FeedWording.insecureMessage(title: "Open Wire"),
            "Subscribed to Open Wire. This feed uses plain http, so what it sends can be read or changed on the way; TextMouth still loads it."
        )
        // Closing again says nothing more.
        presenter.notice = nil
        presenter.addFeedDidClose(in: nil, center: world.center)
        XCTAssertNil(presenter.notice)
    }

    /// An https feed is announced once the sheet has closed, with its
    /// episodes counted, and shows no warning.
    func testAnHttpsFeedIsAnnouncedOnceTheSheetCloses() async throws {
        let world = try FeedTestWorld(self, label: "FeedUISecure")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Closed Wire", items: [Self.item, Self.secondItem])))
        await world.start()
        let presenter = LibraryFeedsPresenter()
        presenter.showAddFeed(center: world.center, parentPath: world.folder.path)
        let model = try XCTUnwrap(presenter.addFeed)
        model.address = world.server.url("/feed.xml").absoluteString
        await model.subscribe()?.value
        let feed = try XCTUnwrap(model.subscribedFeed)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        presenter.addFeedSubscribed(feed)
        presenter.addFeedDidClose(in: nil, center: world.center)

        XCTAssertNil(presenter.notice)
        await waitFor("the subscription is announced") { !announcements.messages.isEmpty }
        XCTAssertEqual(announcements.messages, ["Subscribed to Closed Wire: 2 episodes."])
    }

    /// Cancel closes the sheet and stops the subscription under way.
    func testCancelClosesTheSheet() throws {
        let world = try FeedTestWorld(self, label: "FeedUICancel")
        let presenter = LibraryFeedsPresenter()
        presenter.showAddFeed(center: world.center, parentPath: "")
        XCTAssertNotNil(presenter.addFeed)
        // A second request leaves the open sheet as it is.
        let open = presenter.addFeed
        presenter.showAddFeed(center: world.center, parentPath: world.folder.path)
        XCTAssertTrue(presenter.addFeed === open)

        presenter.cancelAddFeed()

        XCTAssertNil(presenter.addFeed)
        presenter.addFeedDidClose(in: nil, center: world.center)
        XCTAssertNil(presenter.notice)
    }

    // MARK: - The Sheet as Drawn

    /// The sheet draws the address field, labelled, which VoiceOver's one
    /// focus request is for, the Search field, labelled, and the folder
    /// picker offering the top level and the folders, labelled; the Move
    /// dialog draws the same picker.
    func testTheSheetDrawsItsLabelledControls() throws {
        let world = try FeedTestWorld(self, label: "FeedUISheetDrawn")
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { _ in })
        let sheet = AddFeedSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onSubscribed: { _ in },
            onCancel: {}
        )

        withHostedView(sheet, size: NSSize(width: 520, height: 600), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty && self.feedEditableFields(in: $0).count == 2
        }) { hosting in
            XCTAssertEqual(feedEditableFields(in: hosting).count, 2, "the address field and the Search field")
            let popUp = descendants(of: hosting, as: NSPopUpButton.self).first
            XCTAssertEqual(popUp?.itemTitles, [LibraryFolderOption.rootLabel, world.folder.path])
            XCTAssertEqual(popUp?.titleOfSelectedItem, world.folder.path)
            XCTAssertEqual(descendants(of: hosting, as: VoiceOverFocusTriggerView.self).count, 1)
            let targets = feedElements(identified: voiceOverFocusID, in: hosting)
            if !targets.isEmpty {
                XCTAssertEqual(targets.map { $0.accessibilityLabel() ?? "" }, [FeedWording.addressLabel])
            }
            let controls = accessibleControls(in: hosting)
            if !controls.isEmpty {
                XCTAssertNotNil(controls.first { $0.label == FeedWording.folderLabel }, "\(controls.map(\.label))")
                XCTAssertNotNil(controls.first { $0.label == FeedWording.addressLabel }, "\(controls.map(\.label))")
                XCTAssertNotNil(controls.first { $0.label == FeedWording.searchLabel }, "\(controls.map(\.label))")
            }
        }

        let move = MoveFolderSheet(
            books: [],
            library: world.library.library,
            lastMovedFolderPath: "",
            onMove: { _ in .success(nil) },
            onCreateFolder: { _, _ in .success(nil) },
            onCancel: {}
        )
        withHostedView(move, size: NSSize(width: 480, height: 300), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty
        }) { hosting in
            XCTAssertEqual(
                descendants(of: hosting, as: NSPopUpButton.self).first?.itemTitles,
                [LibraryFolderOption.rootLabel, world.folder.path]
            )
        }
    }

    /// At the second step the sheet draws a radio button for each feed the
    /// page names, the first chosen.
    func testTheChoiceStepDrawsARadioButtonPerFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIChoiceDrawn")
        world.server.serve("/page.html", StubResponse(
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(FeedXML.page(naming: [world.server.url("/a.xml"), world.server.url("/b.xml"), world.server.url("/c.xml")]).utf8)
        ))
        await world.start()
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { _ in })
        model.address = world.server.url("/page.html").absoluteString
        await model.subscribe()?.value
        XCTAssertEqual(model.links.count, 3)
        let sheet = AddFeedSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onSubscribed: { _ in },
            onCancel: {}
        )

        withHostedView(sheet, size: NSSize(width: 520, height: 420), until: { self.feedRadioChoices(in: $0).count == 3 }) { hosting in
            let radios = feedRadioChoices(in: hosting)
            XCTAssertEqual(radios.count, 3)
            XCTAssertEqual(radios.chosen, 0, "the page's first feed is not the one chosen")
            XCTAssertTrue(feedEditableFields(in: hosting).isEmpty, "the address field stayed at the second step")
        }
    }

    /// A feed a page names reads as its title and its address without the
    /// scheme, or its address alone.
    func testAFeedAPageNamesReadsAsItsTitleAndAddress() throws {
        let address = try XCTUnwrap(URL(string: "https://news.example/feeds/posts/?format=rss"))
        XCTAssertEqual(
            FeedWording.linkTitle(FeedLink(url: address, title: "Posts", mimeType: "application/rss+xml")),
            "Posts, news.example/feeds/posts?format=rss"
        )
        XCTAssertEqual(
            FeedWording.linkTitle(FeedLink(url: address, title: nil, mimeType: "application/rss+xml")),
            "news.example/feeds/posts?format=rss"
        )
        XCTAssertEqual(FeedWording.choosePrompt(count: 3), "That page names 3 feeds. Choose one, then Subscribe.")
        XCTAssertEqual(
            FeedWording.folderHelp(parentPath: ""),
            "TextMouth makes a folder named after the feed in Library Root, and its episodes and articles download into it."
        )
        XCTAssertEqual(FeedWording.subscribed(title: "Atlas", counts: FeedItemCounts(listed: 1, noun: .episode)), "Subscribed to Atlas: 1 episode.")
        XCTAssertEqual(
            FeedWording.subscribed(title: "Notes", counts: FeedItemCounts(listed: 3, total: FeedEntryTotal(count: 3), noun: .article)),
            "Subscribed to Notes: 3 articles."
        )
        XCTAssertEqual(
            FeedWording.subscribed(title: "Planet Money", counts: FeedItemCounts(listed: 10, total: FeedEntryTotal(count: 381), noun: .episode)),
            "Subscribed to Planet Money: 10 of 381 episodes kept."
        )
    }

    // MARK: - The Return Key

    /// With the new folder's fields shown and keyboard focus in the name
    /// field, Return presses the picker's Create and never Subscribe: a
    /// folder that can't be made keeps the fields, and Return tries again;
    /// with no name typed, Return subscribes to nothing; once the folder is
    /// made and the fields close, Return subscribes to the address, and the
    /// feed's folder goes inside the folder made.
    func testReturnCreatesTheNewFolderWhileItsFieldsAreShownAndSubscribesOtherwise() throws {
        let world = try FeedTestWorld(self, label: "FeedUIReturn")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [Self.item])))
        guard startTurningTheRunLoop(world) else { return }
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { heard.append($0) })
        model.address = world.server.url("/feed.xml").absoluteString
        let creates = CallLog<String>()
        let subscribed = CallLog<String>()
        // The world's own folder stands for the folder made: it is in the
        // pop-up from the start, so the pop-up can show it chosen once
        // "made", as it does in the app once the library publishes the new
        // folder, and the feed's folder then really goes inside it. The
        // first try is refused, as a name in use is, and the second works.
        let folderName = world.folder.path
        let sheet = AddFeedSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { name, parent in
                creates.record(parent.isEmpty ? name : "\(parent)/\(name)")
                return creates.calls.count == 1
                    ? .failure("Could not create folder: refused once for the test")
                    : .success(nil)
            },
            onSubscribed: { subscribed.record($0.title) },
            onCancel: {},
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 520, height: 720), until: { !self.newFolderNameFields(in: $0).isEmpty }) { hosting in
            try typeNewFolderName(folderName, in: hosting)
            guard pressReturnKey(in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(creates.calls, [folderName], "Return did not press Create")
            XCTAssertTrue(heard.isEmpty, "Return pressed Subscribe as well: \(heard)")

            // Refused, the fields stay with the name. With the name cleared,
            // Create is unavailable, and Return subscribes to nothing.
            settleHostedView(hosting)
            XCTAssertEqual(newFolderNameFields(in: hosting).count, 1, "the refused folder's fields closed")
            try typeNewFolderName("", in: hosting)
            XCTAssertFalse(pressReturnKey(in: hosting), "a button took Return with no name typed")
            settleHostedView(hosting)
            XCTAssertEqual(creates.calls.count, 1, "Return pressed Create with no name")
            XCTAssertTrue(heard.isEmpty, "Return pressed Subscribe with the fields shown: \(heard)")
            XCTAssertFalse(model.isWorking)

            // Typed again, the name makes the folder, which is the place
            // chosen, and the fields are gone, so Return subscribes into it.
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
            XCTAssertEqual(heard, [FeedWording.checkingAddress], "Return did not press Subscribe once the fields closed")
            XCTAssertEqual(creates.calls.count, 2, "Return pressed Create once the fields closed")
            XCTAssertTrue(waitUntil(timeout: 10) { subscribed.calls == ["The Tactile Atlas"] }, "the feed was not subscribed to: \(subscribed.calls)")
        }
        let feed = try XCTUnwrap(model.subscribedFeed)
        XCTAssertEqual(world.library.feedFolderPath(forFolderID: feed.folderID), "\(folderName)/The Tactile Atlas")
    }

    /// A page naming several feeds replaces the address step, folder picker
    /// and all, so Subscribe takes Return back even when the new folder's
    /// fields were shown as the page was read; Back brings the address step
    /// back with the fields closed.
    func testReturnSubscribesAtTheChoiceStepAfterTheFieldsWereShown() throws {
        let world = try FeedTestWorld(self, label: "FeedUIReturnChoice")
        let first = world.server.url("/posts.xml")
        let second = world.server.url("/comments.xml")
        world.server.serve("/page.html", StubResponse(
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(FeedXML.page(naming: [first, second]).utf8)
        ))
        world.server.serve("/posts.xml", .feed(FeedXML.rss(title: "Posts", items: [Self.item])))
        guard startTurningTheRunLoop(world) else { return }
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        model.address = world.server.url("/page.html").absoluteString
        let subscribed = CallLog<String>()
        let sheet = AddFeedSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            // Refused, so the fields stay shown, with their name, as the
            // page is read.
            onCreateFolder: { _, _ in .failure("Could not create folder: refused for the test") },
            onSubscribed: { subscribed.record($0.title) },
            onCancel: {},
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 520, height: 720), until: { !self.newFolderNameFields(in: $0).isEmpty }) { hosting in
            try typeNewFolderName("Shows", in: hosting)
            guard pressReturnKey(in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(heard.isEmpty, "Return pressed Subscribe with the fields shown: \(heard)")
            settleHostedView(hosting)
            XCTAssertEqual(newFolderNameFields(in: hosting).count, 1, "the refused folder's fields closed")

            // Subscribe pressed as a click presses it: the page names two
            // feeds, and the choice of them replaces the fields.
            model.subscribe()
            XCTAssertTrue(waitUntil(timeout: 10) { model.isChoosing }, "the page's feeds were not offered")
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return self.newFolderNameFields(in: hosting).isEmpty
            }, "the fields stayed with the choice step")
            settleHostedView(hosting)

            // Return subscribes to the feed chosen.
            XCTAssertTrue(pressReturnKey(in: hosting), "nothing took Return at the choice step")
            XCTAssertEqual(heard.last, FeedWording.checkingAddress, "Return did not press Subscribe at the choice step")
            XCTAssertTrue(waitUntil(timeout: 10) { subscribed.calls == ["Posts"] }, "the feed chosen was not subscribed to: \(subscribed.calls)")

            // Back: the address step returns with the fields closed.
            model.back()
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return !self.descendants(of: hosting, as: NSPopUpButton.self).isEmpty
            }, "the address step did not return")
            settleHostedView(hosting)
            XCTAssertTrue(newFolderNameFields(in: hosting).isEmpty, "the fields reopened after Back")
        }
        XCTAssertEqual(heard, [FeedWording.checkingAddress, FeedWording.choosePrompt(count: 2), FeedWording.checkingAddress])
    }

    // MARK: - The Command

    /// Library > Add Feed… takes Shift-Command-F, the Add Feed action's
    /// default since it became editable (FR12's branch D), which no other
    /// default shortcut and no other menu command uses.
    func testAddFeedsShortcutClashesWithNothing() throws {
        let binding = KeyBinding(key: "f", command: true, shift: true)
        XCTAssertEqual(ShortcutAction.defaultBindings[.addFeed], [binding])
        XCTAssertFalse(
            ShortcutAction.defaultBindings.filter { $0.key != .addFeed }.values.flatMap { $0 }.contains(binding),
            "\(binding.displayString) is another action's default too"
        )
        // The app's menus, which hold every other menu command's key.
        guard let menu = NSApp.mainMenu else { throw XCTSkip("the test host has no main menu") }
        let items = feedMenuItems(of: menu)
        guard let addFeed = items.first(where: { $0.title == FeedWording.addFeedCommand }) else {
            throw XCTSkip("the test host's menus are not built")
        }
        XCTAssertTrue(Self.isShiftCommandF(addFeed), "Add Feed… has \(addFeed.keyEquivalentModifierMask) \(addFeed.keyEquivalent)")
        XCTAssertEqual(items.filter(Self.isShiftCommandF).map(\.title), [FeedWording.addFeedCommand])
    }

    /// Whether `item`'s key is Shift-Command-F, written either as "f" with
    /// Shift held or as a capital "F", which AppKit reads as Shift.
    private static func isShiftCommandF(_ item: NSMenuItem) -> Bool {
        let key = item.keyEquivalent
        guard key.lowercased() == "f" else { return false }
        var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        if key == "F" {
            modifiers.insert(.shift)
        }
        return modifiers == [.command, .shift]
    }

    // MARK: - Helpers

    /// An episode every test feed lists: an item offering audio, which no
    /// test downloads.
    private static let item = FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/audio/1.mp3")
    /// A second episode.
    private static let secondItem = FeedXML.Item(guid: "ep-2", title: "The second visit", enclosure: "https://atlas.example/audio/2.mp3")

    /// Subscribes `world` to its feed at /feed.xml into a new folder inside
    /// its own, starting its engine first.
    private func subscribeIntoNewFolder(_ world: FeedTestWorld) async throws -> Feed {
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(
            to: world.server.url("/feed.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedUIAddFeedTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }

}

// MARK: - The Return Key and the New Folder's Fields

// What the feed sheets' tests of the Return key share with each other; the
// Move sheet's test (`LibraryFolderPickerTests`) keeps its own. These tests
// are synchronous: they turn the run loop while a hosted view is alive, and
// under an async test that turning cannot run the main actor's work, so a
// button's Task would never finish.
extension XCTestCase {
    /// Starts `world`'s engine and turns the run loop until what it starts
    /// has finished, as `world.start()` awaits it; fails the test, and
    /// returns false, when that takes too long.
    @MainActor
    func startTurningTheRunLoop(_ world: FeedTestWorld, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let finished = CallLog<Bool>()
        Task {
            await world.start()
            finished.record(true)
        }
        let started = waitUntil(timeout: 10) { !finished.calls.isEmpty }
        XCTAssertTrue(started, "the engine's start did not finish", file: file, line: line)
        return started
    }

    /// Presses Return in `hostingView`'s window as the app receives a key:
    /// offered as a key equivalent first, which a button with that shortcut
    /// takes, and otherwise sent on to the control with keyboard focus.
    /// Returns whether a key equivalent took it; some macOS releases hand
    /// an offscreen window none.
    @MainActor
    func pressReturnKey(in hostingView: NSView) -> Bool {
        guard let window = hostingView.window, let event = keyDown(.return, in: window) else { return false }
        if window.performKeyEquivalent(with: event) { return true }
        window.sendEvent(event)
        return false
    }

    /// Gives the new folder's name field keyboard focus and makes `name`
    /// its text, through the window's field editor as the keyboard does,
    /// so the picker's binding follows; an empty `name` clears the field.
    /// Skips where an offscreen window gives the field no focus.
    @MainActor
    func typeNewFolderName(_ name: String, in hostingView: NSView) throws {
        let field = try XCTUnwrap(newFolderNameFields(in: hostingView).first, "the name field was not drawn")
        try typeReplacingText(name, in: field, of: hostingView)
    }

    /// Gives `field` keyboard focus and makes `text` its whole text,
    /// through the window's field editor as the keyboard does, so the
    /// field's binding follows; empty `text` clears the field. Skips where
    /// an offscreen window gives the field no focus.
    @MainActor
    func typeReplacingText(_ text: String, in field: NSTextField, of hostingView: NSView) throws {
        guard let window = hostingView.window, window.makeFirstResponder(field),
              let editor = window.firstResponder as? NSTextView else {
            throw XCTSkip("This macOS gives an offscreen window's field no keyboard focus")
        }
        editor.selectAll(nil)
        if text.isEmpty {
            editor.delete(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        settleHostedView(hostingView)
    }

    /// Lets SwiftUI apply its pending updates, as after typing or a press.
    @MainActor
    func settleHostedView(_ hostingView: NSView) {
        _ = waitUntil(timeout: 0.25) {
            hostingView.layoutSubtreeIfNeeded()
            return false
        }
    }

    /// The new folder's name field, drawn while the picker's fields are
    /// shown.
    @MainActor
    func newFolderNameFields(in root: NSView) -> [NSTextField] {
        feedEditableFields(in: root).filter { $0.placeholderString == "Folder name" }
    }
}
