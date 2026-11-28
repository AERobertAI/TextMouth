import XCTest

/// Feeds on the iPhone, as XCUITest reads them in the simulator (FR53, phase
/// F1): the Add Feed sheet's order and audit; and, from a subscription to a
/// stand-in feed, the feed in the Library, its folder's items, one episode
/// downloaded and opened in the reader, and Play.
///
/// **No network.** The app a UI test launches answers one address of its own,
/// `https://feeds.textmouth.test/atlas.xml`, and serves every episode as the
/// silent audio file the launch names (`PhoneUITestFeedStub`, debug builds, a
/// sandboxed launch only).
///
/// **Sound.** Subscribing types the address and playing presses Play, so the
/// test that does both runs only where nobody is listening, as every test of
/// the app that types or plays does (`requireSound`); the file it plays is
/// silent, but the keyboard clicks and the simulator plays through the Mac's
/// speakers.
final class FeedUITests: TextMouthUITestCase {
    // MARK: - The Stand-In Feed

    /// The stand-in feed's address, typed into Add Feed (`PhoneUITestFeedStub.feedAddress`).
    private static let feedAddress = "https://feeds.textmouth.test/atlas.xml"
    /// The feed's title.
    private static let feedTitle = "The Tactile Atlas"
    /// The title of its newest episode.
    private static let newestEpisode = "A map you can touch"
    /// The Add Feed sheet's address field, by its label.
    private static let addressLabel = "Feed or web page address"

    /// Writes a silent 16-bit mono WAV file of `seconds` seconds, which every episode of the stand-in feed is served as,
    /// to the test's own temporary folder, and returns its path. Long enough that Play finds it still playing.
    private func writeSilentEpisode(seconds: Int = 30) throws -> String {
        let sampleRate = 8_000
        let bytesPerSecond = sampleRate * 2
        let dataSize = seconds * bytesPerSecond
        var header = Data()
        /// Appends `value` as `bytes` little-endian bytes.
        func append(_ value: Int, bytes: Int) {
            for index in 0..<bytes {
                header.append(UInt8((value >> (8 * index)) & 0xFF))
            }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize, bytes: 4)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(16, bytes: 4)
        append(1, bytes: 2)
        append(1, bytes: 2)
        append(sampleRate, bytes: 4)
        append(bytesPerSecond, bytes: 4)
        append(2, bytes: 2)
        append(16, bytes: 2)
        header.append(contentsOf: Array("data".utf8))
        append(dataSize, bytes: 4)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("feed-episode-\(UUID().uuidString).wav")
        try (header + Data(count: dataSize)).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    /// Launches with an empty library and the stand-in feed's episode file.
    private func launchWithTheStandInFeed() throws -> XCUIApplication {
        let episode = try writeSilentEpisode()
        return try launch(sendingBookAt: nil, environment: ["TEXTMOUTH_UI_FEED_EPISODE": episode])
    }

    /// Opens Add to Library, then Add Feed…, and waits for the sheet.
    private func openAddFeed(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: Self.patience), "No Add to Library:\n\(app.debugDescription)")
        app.buttons["Add to Library"].tap()
        XCTAssertTrue(app.buttons["Add Feed…"].waitForExistence(timeout: Self.patience), "No Add Feed… in the sheet:\n\(app.debugDescription)")
        app.buttons["Add Feed…"].tap()
        XCTAssertTrue(
            app.textFields[Self.addressLabel].waitForExistence(timeout: Self.patience),
            "The Add Feed sheet never opened:\n\(app.debugDescription)"
        )
    }

    /// The button whose label begins with `start`: a row says more than its title.
    private func button(beginning start: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
    }

    // MARK: - Add Feed

    /// The Add Feed sheet reads its heading, Cancel, the address field with its help line, Subscribe, the row for the
    /// feed's folder, then the search, and passes the audit; Cancel closes it with nothing subscribed.
    func testTheAddFeedSheetHasItsOrder() throws {
        let app = try launchWithTheStandInFeed()
        openAddFeed(in: app)

        let elements = try elementsOfSheet(titled: "Add Feed", in: app)
        assertOrder([
            "Add Feed", "Cancel", Self.addressLabel, "A feed address, such as a link ending in .rss or .xml…", "Subscribe",
            "Folder to hold the feed's own folder", "Search for a podcast",
        ], in: elements)
        let accepted: [Accepted] = [
            .navigationTitle("Add Feed"), .barItem("Cancel"), .dimmedButton("Subscribe"), .dimmedButton("Search"),
            .clippedField(Self.addressLabel),
        ] + Accepted.sectionHeader("Search for a podcast")
        try audit(app, screen: "Add Feed sheet", accepting: accepted)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: Self.patience), "Cancel did not return to the Library:\n\(app.debugDescription)")
        XCTAssertFalse(button(beginning: Self.feedTitle, in: app).exists, "Cancel subscribed")
    }

    // MARK: - Subscribe, List, Download, Play

    /// Subscribing to the stand-in feed lists it in the Library's Feeds section, the Feeds view lists it alone, its folder
    /// lists its two episodes, each said in the Mac's words and offering its commands, and opening one downloads it, opens
    /// it in the reader, and plays. Types and plays, so it runs only where nobody listens.
    func testSubscribingListsTheFeedItsEpisodesAndPlaysOne() throws {
        try requireSound("Typing the feed's address, and pressing Play")
        let app = try launchWithTheStandInFeed()
        openAddFeed(in: app)
        try type(Self.feedAddress, intoFieldLabeled: Self.addressLabel, in: app)
        app.buttons["Subscribe"].tap()

        // The sheet closes, and the feed is a row of the Library's Feeds section.
        let feed = button(beginning: "\(Self.feedTitle), Feed", in: app)
        XCTAssertTrue(feed.waitForExistence(timeout: Self.patience), "The feed was not listed after Subscribe:\n\(app.debugDescription)")
        let top = try elementsInOrder(of: app)
        assertOrder(["Library", "Feeds", "\(Self.feedTitle), Feed…", "Settings", "Sort books by…", "Add to Library"], in: top)
        try audit(app, screen: "Library with a feed", informing: .dynamicType, accepting: LibraryUITests.systemParts)

        // The Feeds view lists the feed alone.
        app.buttons["Library view"].tap()
        XCTAssertTrue(app.buttons["Feeds"].waitForExistence(timeout: Self.patience), "The Library view sheet offered no Feeds:\n\(app.debugDescription)")
        app.buttons["Feeds"].tap()
        XCTAssertTrue(
            button(beginning: "\(Self.feedTitle), Feed", in: app).waitForExistence(timeout: Self.patience),
            "The Feeds view lists no feed:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.navigationBars["Library: Feeds"].exists, "The Feeds view's title is missing:\n\(app.debugDescription)")

        // The feed's folder lists its items, newest first, each one element.
        button(beginning: "\(Self.feedTitle), Feed", in: app).tap()
        let episode = button(beginning: "\(Self.newestEpisode), Not Downloaded", in: app)
        XCTAssertTrue(episode.waitForExistence(timeout: Self.patience), "No row for the newest episode:\n\(app.debugDescription)")
        let items = try elementsInOrder(of: app)
        assertOrder([
            Self.feedTitle, "Episodes (2)", "\(Self.newestEpisode), Not Downloaded…", "Ridges and valleys, Not Downloaded…",
            "2 episodes…", "Sort books by…", "Add to Library",
        ], in: items)
        try audit(app, screen: "A feed's folder", informing: .dynamicType, accepting: LibraryUITests.systemParts)

        // Opening the episode downloads it, and the reader opens on it; Play plays it.
        episode.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: Self.patience), "The reader never opened on the episode:\n\(app.debugDescription)")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == nil OR value != %@", "Loading"), object: app.buttons["Play"])
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: Self.patience), .completed, "The episode never finished loading")
        try pressPlay(in: app)
        try pressPause(in: app)
    }
}
