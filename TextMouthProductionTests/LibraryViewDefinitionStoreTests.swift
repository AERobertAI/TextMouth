import Combine
import XCTest
@testable import TextMouth

/// The store of the Library's views (design section 8): the list kept in
/// the preferences store, saved only when it changes, followed whoever
/// changes it, and mirrored in config.json through the settings model, so a
/// config.json without the key, as an older TextMouth writes it, loses
/// nothing. Every store here is on a sandboxed preferences store of the
/// test's own.
final class LibraryViewDefinitionStoreTests: XCTestCase {

    /// A new store reads the shipped list until one is saved.
    @MainActor
    func testANewStoreReadsTheShippedList() throws {
        let defaults = try isolatedDefaults()
        let store = LibraryViewDefinitionStore(preferences: defaults)
        XCTAssertEqual(store.list, .shipped)
        XCTAssertNil(defaults.object(forKey: "libraryViews"))
        XCTAssertEqual(LibraryViewDefinitionStore.preference.key, "libraryViews")
    }

    /// A change is saved, and another store on the same preferences reads
    /// it; an update returns what the operation returned.
    @MainActor
    func testAChangeIsSavedAndReadByAnotherStore() throws {
        let defaults = try isolatedDefaults()
        let store = LibraryViewDefinitionStore(preferences: defaults)
        let changed = store.update { $0.setVisibility(.hidden, of: .feeds) }
        XCTAssertTrue(changed)
        XCTAssertEqual(store.list.view(.feeds)?.visibility, .hidden)
        let other = LibraryViewDefinitionStore(preferences: defaults)
        XCTAssertEqual(other.list, store.list)
    }

    /// An update that changes nothing writes nothing and publishes nothing.
    @MainActor
    func testAnUpdateThatChangesNothingWritesAndPublishesNothing() throws {
        let defaults = try isolatedDefaults()
        let store = LibraryViewDefinitionStore(preferences: defaults)
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        let changed = store.update { $0.setVisibility(.whenApplicable, of: .feeds) }
        XCTAssertFalse(changed)
        XCTAssertNil(defaults.object(forKey: "libraryViews"))
        XCTAssertEqual(publications, 0)
        subscription.cancel()
    }

    /// A change another writer makes in the preferences, such as the
    /// settings model applying config.json, reaches the list at once.
    @MainActor
    func testAChangeByAnotherWriterReachesTheList() throws {
        let defaults = try isolatedDefaults()
        let store = LibraryViewDefinitionStore(preferences: defaults)
        var list = LibraryViewDefinitionList.shipped
        list.move(.category(.readingList), by: -1)
        LibraryViewDefinitionStore.preference.write(list, to: defaults)
        XCTAssertEqual(store.list, list)
    }

    /// What the preferences hold that is not a JSON array reads as the
    /// shipped list, and an entry this TextMouth cannot read survives the
    /// store exactly as it was.
    @MainActor
    func testTheStoreReadsWhatItCanAndKeepsTheRest() throws {
        let defaults = try isolatedDefaults()
        defaults.set(Data("{\"id\": \"Folders\"}".utf8), forKey: "libraryViews")
        XCTAssertEqual(LibraryViewDefinitionStore.preference.read(from: defaults), .shipped)
        defaults.set("Folders", forKey: "libraryViews")
        XCTAssertEqual(LibraryViewDefinitionStore.preference.read(from: defaults), .shipped)

        let unknown = try LibraryViewDefinitionTests.json(#"{"id": "Audiobooks", "visibility": "always", "shelf": [1, 2]}"#)
        let list = LibraryViewDefinitionList(fileEntries: [unknown] + LibraryViewDefinitionList.shipped.fileEntries)
        LibraryViewDefinitionStore.preference.write(list, to: defaults)
        let read = LibraryViewDefinitionStore.preference.read(from: defaults)
        XCTAssertEqual(read, list)
        XCTAssertEqual(read.fileEntries.first, unknown)
        XCTAssertEqual(read.unreadableCount, 1)
    }

    // MARK: - config.json

    /// The views config.json gives reach the store through the settings
    /// model, a change in the store reaches config.json, and a config.json
    /// without the key, as an older TextMouth writes it, leaves the views
    /// as they are.
    @MainActor
    func testTheViewsTravelThroughConfigJSONBothWays() throws {
        let defaults = try isolatedDefaults()
        let service = ConfigService(fileURL: try makeConfigFileURL())
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        let store = LibraryViewDefinitionStore(preferences: defaults)

        var file = service.config
        file.libraryViews = ConfigService.AppConfig.customizedLibraryViews
        settings.applyConfigChanges(file)
        XCTAssertEqual(store.list.fileEntries, ConfigService.AppConfig.customizedLibraryViews)
        XCTAssertEqual(store.list.view(.feeds)?.visibility, .hidden)

        store.update { $0.setVisibility(.hidden, of: .category(.readingList)) }
        settings.syncToConfig()
        XCTAssertEqual(service.config.libraryViews, store.list.fileEntries)

        let kept = store.list
        var older = service.config
        older.libraryViews = nil
        settings.applyConfigChanges(older)
        XCTAssertEqual(store.list, kept)

        var empty = service.config
        empty.libraryViews = []
        settings.applyConfigChanges(empty)
        XCTAssertEqual(store.list, kept)
    }

    /// A name too long in config.json is cut when the file is applied, and
    /// the cut is logged as config.json's, by its place alone.
    @MainActor
    func testARepairOfConfigJSONIsLoggedAsItsOwn() throws {
        let defaults = try isolatedDefaults()
        let service = ConfigService(fileURL: try makeConfigFileURL())
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        let store = LibraryViewDefinitionStore(preferences: defaults)
        let custom = UUID().uuidString
        let name = String(repeating: "Q", count: 75)
        var file = service.config
        file.libraryViews = [
            try LibraryViewDefinitionTests.json(#"{"id": "\#(custom)", "name": "\#(name)", "visibility": "always", "filter": {"lists": ["books"]}}"#),
        ]
        settings.applyConfigChanges(file)
        XCTAssertEqual(store.list.views.first?.name, String(repeating: "Q", count: 60))
        let lines = debugLogLines(containing: "libraryViews[0].name")
        XCTAssertTrue(lines.contains { $0.contains("STORED_VALUE_REPAIRED config.json") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(name) }, "the log holds the name the listener typed")
    }
}
