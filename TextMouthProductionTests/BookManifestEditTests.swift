import XCTest
@testable import TextMouth

/// Edit Manifest in Default Editor and Edit Manifest With… (FR17): which
/// books offer them, the manifest written for a book without one, and how
/// an edit the user saves is taken.
///
/// Every book here is a world's book of silent tracks
/// (`IntegrationWorld.makeSilentAudioBook`): nothing is heard, nothing is
/// opened in another app, and nothing outside the test's sandbox is read.
@MainActor
final class BookManifestEditTests: XCTestCase {

    // MARK: - Which Books (Item 1)

    /// Only an audiobook of the library's own, in a package of its own,
    /// whose audio is a folder of tracks, can have its manifest edited: not
    /// a feed's item, a book without a package, or a text book, whatever
    /// its folder holds.
    func testOnlyALibraryAudiobookOfTracksInItsOwnPackageIsOffered() {
        let audio = Book(title: "Tide Tables", format: .audio, filePath: "/Library/Tide.tmb/audio", md5Hash: "tide", folderPath: "", tmbDirectoryName: "Tide.tmb")
        XCTAssertTrue(BookManifestEditing.canEditManifest(of: audio, isTrackFolder: true))
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: audio, isTrackFolder: false), "A book that is no folder of tracks was offered")

        var feedItem = audio
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:tide")
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: feedItem, isTrackFolder: true), "A feed's item was offered")

        var withoutPackage = audio
        withoutPackage.tmbDirectoryName = ""
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: withoutPackage, isTrackFolder: true), "A book without a package was offered")

        var text = audio
        text.format = .txt
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: text, isTrackFolder: true), "A text book was offered")
    }

    /// A folder of tracks plays one track per heading with or without a
    /// manifest, and with one inside its one folder; a converted DAISY
    /// book's folder of sections and a single-file audiobook do not.
    func testAFolderOfTracksIsFoundWithOrWithoutAManifest() throws {
        let world = try makeIntegrationWorld("Edit Manifest Which Books")
        let plain = try world.makeSilentAudioBook(title: "Plain Tracks", trackDurations: [0.2, 0.2])
        let listed = try world.makeSilentAudioBook(
            title: "Listed Tracks",
            trackDurations: [0.2, 0.2],
            manifest: #"{"tracks": ["02.wav", "01.wav"]}"#
        )
        let sections = try world.makeSegmentedAudioBook(
            title: "Sections",
            files: ["a.wav": 0.4],
            sections: [
                AudioSegment(title: "One", file: "a.wav", startTime: 0, endTime: 0.2),
                AudioSegment(title: "Two", file: "a.wav", startTime: 0.2, endTime: 0.4)
            ]
        )
        let single = try world.makeSilentAudioFileBook(title: "Single File", duration: 0.2)

        XCTAssertTrue(BookManifestEditing.hasTrackFolder(plain), "A folder of tracks without a manifest was not found")
        XCTAssertTrue(BookManifestEditing.hasTrackFolder(listed), "A folder of tracks with a manifest was not found")
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(sections), "A folder of sections was taken for one of tracks")
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(single), "A single-file audiobook was taken for a folder of tracks")

        // A manifest inside the folder's one folder is found where the
        // reader finds it, and its sections count there too.
        let wrapped = try makeSandboxDirectory("Edit Manifest Wrapped")
        let inner = wrapped.appendingPathComponent("Radio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: inner.appendingPathComponent("a.wav"), duration: 0.2)
        try Data(#"{"title": "Wrapped"}"#.utf8).write(to: inner.appendingPathComponent(AudioManifest.fileName))
        XCTAssertEqual(BookManifestEditing.isTrackFolder(wrapped), true)
        try Data(#"{"segments": [{"title": "One", "file": "a.wav", "startTime": 0, "endTime": 0.1}]}"#.utf8)
            .write(to: inner.appendingPathComponent(AudioManifest.fileName))
        XCTAssertEqual(BookManifestEditing.isTrackFolder(wrapped), false, "A wrapped manifest's sections were missed")
    }

    /// A folder only in the cloud, or whose manifest is, is not looked into,
    /// so nothing is downloaded, and it is not offered until it is here.
    func testAFolderOnlyInTheCloudIsNotLookedInto() throws {
        let world = try makeIntegrationWorld("Edit Manifest Cloud")
        let book = try world.makeSilentAudioBook(title: "Cloud Tracks", trackDurations: [0.2], manifest: #"{"title": "Cloud Tracks"}"#)
        let folder = book.bookFileURL

        XCTAssertNil(BookManifestEditing.isTrackFolder(folder, isDataless: { _ in true }))
        XCTAssertNil(BookManifestEditing.isTrackFolder(folder, isDataless: { $0.lastPathComponent == AudioManifest.fileName }))
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(book, isDataless: { _ in true }))
    }

    /// The store records the books whose audio is a folder of tracks, and
    /// only those, so a row and a reader offer the commands for them alone.
    func testTheStoreRecordsOnlyTheFoldersOfTracks() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Store")
        let tracks = try world.makeSilentAudioBook(title: "Store Tracks", trackDurations: [0.2, 0.2])
        let single = try world.makeSilentAudioFileBook(title: "Store Single", duration: 0.2)
        var feedItem = try world.makeSilentAudioBook(title: "Store Episode", trackDurations: [0.2])
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:episode")
        let store = TrackFolderBooks()

        await store.refresh([tracks, single, feedItem])

        XCTAssertEqual(store.bookIDs, [tracks.id])
        XCTAssertTrue(store.contains(tracks.id))
        XCTAssertFalse(store.contains(single.id))
    }
}
