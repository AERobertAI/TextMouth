import SwiftUI
import XCTest
@testable import TextMouth

/// The Folder Settings sheet (FR19): its wording, its facts, the two
/// listening options it saves, and the hosted sheet's controls, keys, and
/// gone-folder line. The sheet is hosted directly here; the Library window
/// presents it in task F.
@MainActor
final class FolderSettingsSheetTests: XCTestCase {

    // MARK: - Fixtures

    /// A world with a library, a feed engine, and sandboxed preferences.
    private func makeWorld(_ label: String) throws -> FeedTestWorld {
        try FeedTestWorld(self, label: label)
    }

    /// The model for the folder `folderID` of `world`, reading the global
    /// "When book ends" from the world's sandboxed preferences.
    private func makeModel(_ world: FeedTestWorld, folderID: UUID) -> FolderSettingsModel {
        FolderSettingsModel(
            folderID: folderID,
            library: world.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            wordsPerMinute: 200,
            defaults: world.preferences
        )
    }

    /// A text book at `path`, opened a sixth of the way through when
    /// `opened`.
    private func book(_ title: String, in path: String, opened: Bool) -> Book {
        Book(
            title: title,
            format: .txt,
            filePath: "/nonexistent/\(title).txt",
            md5Hash: title,
            folderPath: path,
            lastOpened: opened ? Date() : nil,
            readingPosition: opened ? ReadingPosition(chapterIndex: 0, characterOffset: 1_000) : nil,
            totalWordCount: 1_000,
            totalCharacterCount: 6_000
        )
    }

    /// The facts of a roomy folder, whose every optional fact is shown.
    private let roomy = FolderInfoFacts(
        name: "Classics", bookCount: 12, unopenedCount: 3, feedCount: 2, subfolderCount: 2,
        timeRemaining: 14 * 3_600 + 3 * 60
    )

    /// The facts of an empty folder, whose optional facts are all absent.
    private let bare = FolderInfoFacts(
        name: "Bare", bookCount: 0, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil
    )

    // MARK: - Wording

    /// Every fixed word of the sheet, pinned exactly, since the listener
    /// hears them through VoiceOver and reads them in braille.
    func testTheSheetsWordsArePinned() {
        XCTAssertEqual(FolderSettingsWording.title, "Folder Settings")
        XCTAssertEqual(FolderSettingsWording.locationLabel, "Location")
        XCTAssertEqual(FolderSettingsWording.booksLabel, "Books")
        XCTAssertEqual(FolderSettingsWording.subfoldersLabel, "Subfolders")
        XCTAssertEqual(FolderSettingsWording.feedsLabel, "Feeds")
        XCTAssertEqual(FolderSettingsWording.timeRemainingLabel, "Time remaining")
        XCTAssertEqual(FolderSettingsWording.listeningHeading, "Listening")
        XCTAssertEqual(FolderSettingsWording.done, "Done")
        XCTAssertEqual(FolderSettingsWording.folderGone, "This folder is no longer in the library.")
        XCTAssertEqual(LibraryFolderOption.rootLabel, "Library Root")
    }

    /// A folder with books, subfolders, feeds, and a known time left shows
    /// all five facts, each value the words Speak Info speaks.
    func testARoomyFoldersFactsAreAllShown() {
        XCTAssertEqual(
            FolderSettingsWording.facts(of: roomy, parentPath: "Audio/Fiction"),
            [
                .init(label: "Location", value: "Audio/Fiction"),
                .init(label: "Books", value: "12 books, 3 unopened"),
                .init(label: "Subfolders", value: "2 subfolders"),
                .init(label: "Feeds", value: "2 feeds"),
                .init(label: "Time remaining", value: "14 hours, 3 minutes remaining in total"),
            ]
        )
    }

    /// A folder at the library's top level reads "Library Root"; the
    /// subfolders, feeds, and time rows are absent when it has none, and an
    /// unknown time is no row.
    func testAnEmptyFoldersOptionalFactsAreAbsent() {
        XCTAssertEqual(
            FolderSettingsWording.facts(of: bare, parentPath: ""),
            [
                .init(label: "Location", value: "Library Root"),
                .init(label: "Books", value: "0 books"),
            ]
        )
        // One of each, singular, and no unopened books to mention.
        let single = FolderInfoFacts(name: "One", bookCount: 1, unopenedCount: 0, feedCount: 1, subfolderCount: 1, timeRemaining: nil)
        XCTAssertEqual(
            FolderSettingsWording.facts(of: single, parentPath: "").map(\.value),
            ["Library Root", "1 book", "1 subfolder", "1 feed"]
        )
    }

    /// The sheet's values are the phrases Speak Info builds its summaries
    /// from, so the two cannot drift apart.
    func testTheFactsAreSpeakInfosPhrases() {
        let brief = LibraryInfoWording.briefParts(of: roomy)
        let full = LibraryInfoWording.fullParts(of: roomy)
        XCTAssertEqual(brief, ["Classics", "Folder", "12 books, 3 unopened", "2 feeds"])
        XCTAssertEqual(full, ["2 subfolders", "14 hours, 3 minutes remaining in total"])
        let values = FolderSettingsWording.facts(of: roomy, parentPath: "").map(\.value)
        XCTAssertTrue(values.contains(brief[2]))
        XCTAssertTrue(values.contains(brief[3]))
        XCTAssertTrue(values.contains(full[0]))
        XCTAssertTrue(values.contains(full[1]))
    }

    // MARK: - The Model

    /// The model reads a folder's facts from the library, with its books
    /// counted below it, its subfolder, and a feed's folder inside it.
    func testTheModelsFactsCountTheFoldersTree() async throws {
        let world = try makeWorld("FolderSettingsFacts")
        let base = world.bookFolder.fullPath
        _ = try world.library.createFolderReturningFolder(name: "Shelf", parentPath: base)
        world.library.library.books += [
            book("Read", in: base, opened: true),
            book("Unread", in: base, opened: false),
            book("Shelved", in: "\(base)/Shelf", opened: true),
        ]
        await world.start()
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [
            FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/audio/ep-1.mp3"),
        ])))
        let outcome = try await world.center.subscribe(
            to: world.server.url("/atlas.xml").absoluteString, into: .newFolder(inParentPath: base)
        )
        guard case .subscribed = outcome else { return XCTFail("subscribing offered a choice: \(outcome)") }

        let model = makeModel(world, folderID: world.bookFolder.id)
        let facts = try XCTUnwrap(model.facts)
        XCTAssertEqual(facts.name, base)
        XCTAssertEqual(facts.bookCount, 3)
        XCTAssertEqual(facts.unopenedCount, 1)
        XCTAssertEqual(facts.feedCount, 1)
        XCTAssertEqual(facts.subfolderCount, 2, "the Shelf and the feed's own folder")
        let rows = FolderSettingsWording.facts(of: facts, parentPath: try XCTUnwrap(model.folder).parentPath)
        XCTAssertEqual(rows.map(\.label), ["Location", "Books", "Subfolders", "Feeds", "Time remaining"])
        XCTAssertEqual(rows[1].value, "3 books, 1 unopened")
        XCTAssertEqual(rows[2].value, "2 subfolders")
        XCTAssertEqual(rows[3].value, "1 feed")
    }

    /// A folder's choices save through the library at once, and a change
    /// back to the standard choices stores nothing.
    func testTheModelSavesEachChoiceThroughTheLibrary() throws {
        let world = try makeWorld("FolderSettingsSave")
        let id = world.bookFolder.id
        let model = makeModel(world, folderID: id)

        XCTAssertNil(model.continuation)
        XCTAssertTrue(model.skipsFinished)
        XCTAssertNil(world.library.listeningOptions(ofFolder: id), "a folder starts with nothing stored")

        model.continuation = .playBookAbove
        XCTAssertEqual(world.library.listeningOptions(ofFolder: id), ListeningOptions(continuation: .playBookAbove))
        model.skipsFinished = false
        XCTAssertEqual(
            world.library.listeningOptions(ofFolder: id),
            ListeningOptions(continuation: .playBookAbove, skipsFinished: false)
        )
        XCTAssertEqual(model.continuation, .playBookAbove)
        XCTAssertFalse(model.skipsFinished)

        // Back to the defaults one choice at a time: nothing is stored.
        model.continuation = nil
        XCTAssertEqual(world.library.listeningOptions(ofFolder: id), ListeningOptions(skipsFinished: false))
        model.skipsFinished = true
        XCTAssertNil(world.library.listeningOptions(ofFolder: id), "standard choices must store nothing")
        XCTAssertNil(world.library.library.folders.first { $0.id == id }?.listeningOptions)
    }

    /// A choice another window makes shows in the model, as does a rename,
    /// and the model never touches the options of a folder it does not
    /// show.
    func testTheModelFollowsChangesMadeElsewhere() throws {
        let world = try makeWorld("FolderSettingsElsewhere")
        let id = world.bookFolder.id
        let other = try world.library.createFolderReturningFolder(name: "Other", parentPath: "")
        let model = makeModel(world, folderID: id)

        world.library.setListeningOptions(ListeningOptions(continuation: .stop, skipsFinished: false), ofFolder: id)
        XCTAssertEqual(model.continuation, .stop)
        XCTAssertFalse(model.skipsFinished)
        XCTAssertNil(world.library.listeningOptions(ofFolder: other.id))

        model.skipsFinished = true
        XCTAssertEqual(world.library.listeningOptions(ofFolder: id), ListeningOptions(continuation: .stop))
        XCTAssertNil(world.library.listeningOptions(ofFolder: other.id))

        // A folder deleted elsewhere is gone from the model too.
        world.library.library.folders.removeAll { $0.id == id }
        XCTAssertNil(model.folder)
        XCTAssertNil(model.facts)
    }

    /// The model names the global "When book ends" as the Playback tab
    /// keeps it, the default being Stop.
    func testTheModelReadsTheGlobalEndOfBookBehavior() throws {
        let world = try makeWorld("FolderSettingsGlobal")
        let model = makeModel(world, folderID: world.bookFolder.id)
        XCTAssertEqual(model.globalEndOfBookBehavior, .stop)
        world.preferences.set(EndOfBookBehavior.continueNext.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        XCTAssertEqual(model.globalEndOfBookBehavior, .continueNext)
    }

    // MARK: - The Sheet as Drawn

    /// The hosted sheet draws the pop-up with its four choices, the first
    /// naming the global one, and the labelled controls VoiceOver speaks.
    func testTheSheetDrawsTheListeningControls() throws {
        let world = try makeWorld("FolderSettingsDrawn")
        world.preferences.set(EndOfBookBehavior.continueNext.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        let model = makeModel(world, folderID: world.bookFolder.id)
        let sheet = FolderSettingsSheet(model: model, onDone: {})

        withHostedView(sheet, size: NSSize(width: 480, height: 420), until: {
            self.descendants(of: $0, as: NSPopUpButton.self).count == 1
        }) { hosting in
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.count, 1, "only When a book ends is a pop-up")
            XCTAssertEqual(popUps.first?.itemTitles, [
                "Use the global setting (Continue to Next Book)",
                "Play the book below",
                "Play the book above",
                "Stop",
            ])
            XCTAssertEqual(popUps.first?.titleOfSelectedItem, "Use the global setting (Continue to Next Book)")
            // The checkbox, and no pre-download control: a folder's books
            // are on this Mac already.
            let checkboxes = feedCheckboxes(in: hosting)
            XCTAssertEqual(checkboxes.count, 1, "the Skip finished books checkbox alone")
            XCTAssertEqual(checkboxes.first?.state, .on)

            if hostedWindowsExposeAccessibility() {
                let controls = accessibleControls(in: hosting)
                let picker = controls.first { $0.role == .popUpButton }
                XCTAssertEqual(picker?.label, "When a book ends")
                XCTAssertEqual(picker?.hint, ListeningOptionsWording.continuationHint(.book))
            }
        }

        // The words the controls speak, pinned where the hosted window
        // cannot show them.
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.book), "When a book ends")
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.book), "Skip finished books")
    }

    /// Choosing in the pop-up saves through the library, and the checkbox
    /// draws what the library holds.
    func testChoosingInTheHostedPopUpSavesAndTheCheckboxFollows() throws {
        let world = try makeWorld("FolderSettingsChoose")
        let id = world.bookFolder.id
        let model = makeModel(world, folderID: id)
        let sheet = FolderSettingsSheet(model: model, onDone: {})

        try withHostedView(sheet, size: NSSize(width: 480, height: 420), until: {
            self.descendants(of: $0, as: NSPopUpButton.self).count == 1
        }) { hosting in
            let popUp = try XCTUnwrap(descendants(of: hosting, as: NSPopUpButton.self).first)
            // Choosing a menu item runs the action SwiftUI gave the item;
            // the pop-up's own target and action are the second way.
            let chose = savesAfterTrying(
                [
                    { popUp.menu?.performActionForItem(at: 3) },
                    { popUp.selectItem(at: 3); _ = popUp.target?.perform(popUp.action, with: popUp) },
                ],
                until: { world.library.listeningOptions(ofFolder: id)?.continuation == .stop }
            )
            XCTAssertTrue(chose, "choosing Stop did not save: \(String(describing: world.library.listeningOptions(ofFolder: id)))")
            XCTAssertEqual(model.continuation, .stop)

            // SwiftUI gives its checkbox no target or action a test can
            // press (see `feedCheckboxes`), so the click's own path, the
            // model's setter the checkbox's binding calls, is driven
            // directly, and the checkbox is checked to draw what was saved.
            let checkbox = try XCTUnwrap(feedCheckboxes(in: hosting).first)
            XCTAssertEqual(checkbox.state, .on)
            model.skipsFinished = false
            XCTAssertEqual(world.library.listeningOptions(ofFolder: id)?.skipsFinished, false)
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return feedCheckboxes(in: hosting).first?.state == .off
                },
                "the checkbox did not draw the choice saved"
            )
            XCTAssertFalse(model.skipsFinished)
        }
    }

    /// Runs each of `attempts` in turn until `condition` holds, waiting a
    /// moment after each for SwiftUI to hand the change on; whether it held
    /// at the end.
    private func savesAfterTrying(_ attempts: [() -> Void], until condition: () -> Bool) -> Bool {
        for attempt in attempts {
            attempt()
            if waitUntil(timeout: 1, condition) { return true }
        }
        return false
    }

    // MARK: - Done, Return, and Escape

    /// Return and Escape each press Done once.
    func testReturnAndEscapeBothReachDone() throws {
        let world = try makeWorld("FolderSettingsKeys")
        let model = makeModel(world, folderID: world.bookFolder.id)
        var dones = 0
        let sheet = FolderSettingsSheet(model: model, onDone: { dones += 1 })

        try withHostedView(sheet, size: NSSize(width: 480, height: 420), until: {
            self.descendants(of: $0, as: SilentKeyEquivalentView.self).count == 1
        }) { hosting in
            guard pressKeyEquivalent(.escape, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(dones, 1, "Escape did not press Done")
            XCTAssertTrue(pressKeyEquivalent(.return, in: hosting), "nothing took Return")
            XCTAssertEqual(dones, 2, "Return did not press Done")
        }
    }

    // MARK: - A Gone Folder

    /// A folder deleted while its sheet is open leaves the line saying so
    /// and Done alone: no pop-up and no checkbox, and Done still closes.
    func testAGoneFolderShowsItsLineAndDoneOnly() throws {
        let world = try makeWorld("FolderSettingsGone")
        let model = makeModel(world, folderID: UUID())
        var dones = 0
        let sheet = FolderSettingsSheet(model: model, onDone: { dones += 1 })

        try withHostedView(sheet, size: NSSize(width: 480, height: 420), until: {
            !self.descendants(of: $0, as: SilentKeyEquivalentView.self).isEmpty
        }) { hosting in
            XCTAssertTrue(descendants(of: hosting, as: NSPopUpButton.self).isEmpty, "a pop-up for a folder that is gone")
            XCTAssertTrue(feedCheckboxes(in: hosting).isEmpty, "a checkbox for a folder that is gone")
            guard pressKeyEquivalent(.escape, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(dones, 1, "Done did not close the sheet of a gone folder")
        }
    }
}
