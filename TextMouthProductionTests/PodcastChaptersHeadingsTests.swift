import XCTest
@testable import TextMouth

/// A podcast episode's chapters, kept beside its audio in its package as
/// podcastChapters.json (FMT25), become the chapters, and so the headings,
/// of a book of one file whose audio has no chapters of its own, when they
/// fit the audio. The file is TextMouth's own, never taken for the book; it
/// goes with the audio when an episode's download is deleted; and an edit
/// of the audio drops it, since its times no longer fit. The chapters come
/// from a copy of the format sample or are made here; every audio file is
/// written here, and none is played.
@MainActor
final class PodcastChaptersHeadingsTests: XCTestCase {
    // MARK: - Helpers

    /// The sample's chapters, read from a copy of it.
    private func sampleChapters() throws -> PodcastChapters {
        try PodcastChapters.read(Data(contentsOf: copyOfFormatSample("podcast-chapters-json/chapters.json")))
    }

    /// The sample's chapters as the file an episode's download keeps
    /// beside its audio (`PodcastChapters.normalizedJSON()`).
    private func sampleChaptersFile() throws -> Data {
        try sampleChapters().normalizedJSON()
    }

    // MARK: - The File

    /// The chapters are podcastChapters.json at the top of the package, a
    /// file of TextMouth's own that is never taken for the book: a package
    /// holding an episode's audio and its chapters is the audio's.
    func testTheChaptersFileIsNamedInThePackageAndNeverTakenForTheBook() throws {
        XCTAssertEqual(TextMouthPaths.podcastChaptersFileName, "podcastChapters.json")
        let package = try makeSandboxDirectory("PodcastChaptersPackage")
        XCTAssertEqual(
            TextMouthPaths.podcastChaptersPath(in: package),
            package.appendingPathComponent("podcastChapters.json")
        )
        XCTAssertFalse(FileImportService.isPackageContentName("podcastChapters.json"))

        try Data().write(to: package.appendingPathComponent("Episode.mp3"))
        try sampleChaptersFile().write(to: TextMouthPaths.podcastChaptersPath(in: package))
        XCTAssertEqual(try FileImportService.retainedContentURL(in: package).lastPathComponent, "Episode.mp3")
    }

    // MARK: - The Episode's Download Deleted

    /// Deleting an episode's download, its package kept, removes the
    /// chapters kept beside the audio with it, and keeps the record and the
    /// transcript, which are the listener's.
    func testDeletingAnEpisodesDownloadRemovesItsChaptersAndKeepsItsTranscript() throws {
        let package = try makeSandboxDirectory("PodcastChaptersEpisode")
            .appendingPathComponent("Episode.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let names = [
            "Episode.mp3", TextMouthPaths.bookInfoFileName, TextMouthPaths.transcriptFileName,
            TextMouthPaths.podcastChaptersFileName,
        ]
        for name in names {
            try Data("{}".utf8).write(to: package.appendingPathComponent(name))
        }
        let row = Book(
            title: "Episode",
            format: .audio,
            filePath: package.appendingPathComponent("Episode.mp3").path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: package.lastPathComponent
        )

        FeedItemPackage.removeWhatTheFileMade(of: row, from: package)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: package.path).sorted(),
            [TextMouthPaths.bookInfoFileName, TextMouthPaths.transcriptFileName]
        )
    }
}
