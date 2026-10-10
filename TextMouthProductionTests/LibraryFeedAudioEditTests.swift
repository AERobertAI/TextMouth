import XCTest
@testable import TextMouth

/// Feed items are not editable (FR11, question 4), so Edit Audio… is not
/// offered for an episode in its feed's folder, in the library's rows or the
/// reader's Book menu, and is refused with a sentence of its own should it
/// ever reach one. Its package is found where it is all the same: a downloaded
/// episode's Edit Audio… used to look for its audio in the library folder and
/// fail with a false "missing audio" error, and the launch's sweep of the
/// originals looked there too (REV10, item 5). No real window opens.
@MainActor
final class LibraryFeedAudioEditTests: XCTestCase {

    /// Edit Audio… is offered for an audiobook of the library's own, and not
    /// for a feed's episode, which can still be transcribed.
    func testEditAudioIsNotOfferedForAFeedsEpisode() {
        let episode = Self.episode(of: UUID())
        var audiobook = episode
        audiobook.feedLink = nil

        XCTAssertEqual(LibraryAudioCommand.commands(for: [episode]).map(\.title), [TranscriptionWording.transcribeCommandTitle])
        XCTAssertEqual(LibraryAudioCommand.commands(for: [audiobook]).first?.title, AudioEditorWording.editAudioCommand)
        XCTAssertFalse(AudioEditorLauncher.canEdit(episode))
        XCTAssertTrue(AudioEditorLauncher.canEdit(audiobook))
    }

    /// Should Edit Audio… reach a feed's episode, it is refused with a
    /// sentence saying why, and nothing opens.
    func testEditAudioRefusesAFeedsEpisodeSayingWhy() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 1, for: self)
        var episode = fixture.book
        episode.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:ep-1")
        let script = LauncherScript()

        let outcome = await AudioEditorLauncher.open(episode, in: fixture.library, from: nil, controller: script.windows, services: script.services)

        XCTAssertEqual(outcome, .refused(AudioEditorWording.feedEpisodeNotEditable))
        XCTAssertEqual(script.announced, ["An episode in its feed can't be edited."])
        XCTAssertTrue(script.presented.isEmpty)
    }

    /// An episode's audio is found in its package in its feed's folder,
    /// where the original policy's sweep looks for it, and a book of the
    /// library's own's in its library folder, as each book's package is.
    func testAnEpisodesAudioIsFoundInItsFeedsFolder() {
        let feedID = UUID()
        let episode = Self.episode(of: feedID)
        var audiobook = episode
        audiobook.feedLink = nil
        audiobook.folderPath = "Talks"

        let place = AudioBookPlace(book: episode)
        XCTAssertEqual(place.package, FeedPaths.packageDirectory(named: episode.tmbDirectoryName, of: feedID, in: TextMouthPaths.root))
        XCTAssertEqual(place.package, episode.tmbDirectory)
        XCTAssertEqual(place.sweepPackage.url, place.package)
        XCTAssertEqual(AudioBookPlace(book: audiobook).package, TextMouthPaths.tmbPath(folderPath: "Talks", tmbName: audiobook.tmbDirectoryName))
    }

    // MARK: - Fixtures

    /// A downloaded episode of the feed `feedID`, its package in that feed's
    /// folder.
    private static func episode(of feedID: UUID) -> Book {
        let name = "Ep-368-\(UUID().uuidString).tmb"
        let package = FeedPaths.packageDirectory(named: name, of: feedID, in: TextMouthPaths.root)
        return Book(
            title: "Ep. 368",
            format: .audio,
            filePath: package.appendingPathComponent("episode.m4a").path,
            md5Hash: name,
            tmbDirectoryName: name,
            feedLink: FeedBookLink(feedID: feedID, itemID: "guid:ep-368")
        )
    }
}
