import AVFoundation
import XCTest
@testable import TextMouth

/// What the audio editor keeps in this Mac's caches (FR04): the folders a
/// crash left, removed at launch while every folder an open editor uses is
/// kept, and a filter's processed stretch that macOS emptied from the
/// caches, made again when the editor next needs it. No test plays a sound.
@MainActor
final class AudioEditCachesTests: XCTestCase {

    // MARK: - The Launch Sweep

    /// The sweep removes each book's scratch folder no use of the book
    /// holds, each folder a sweep cut short set aside, and each clip folder
    /// no open window has; it keeps the folders in use, and leaves alone
    /// anything not named as a book's.
    func testTheSweepRemovesWhatACrashLeftAndKeepsWhatIsInUse() throws {
        let caches = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: caches) }
        let scratchRoot = caches.appendingPathComponent("Audio Edits", isDirectory: true)
        let clipsRoot = caches.appendingPathComponent("Audio Editor Clips", isDirectory: true)
        let stale = UUID()
        let inUse = UUID()
        let staleBook = try folder(stale.uuidString, in: scratchRoot, holding: "processed-1.caf")
        let usedBook = try folder(inUse.uuidString, in: scratchRoot, holding: "silence-8000-1.caf")
        let cutShort = try folder(AudioEditCaches.setAsidePrefix + "earlier", in: scratchRoot, holding: "processed-2.caf")
        let notABook = try folder("Notes", in: scratchRoot, holding: "notes.txt")
        let closedWindow = try folder("A", in: clipsRoot, holding: "clip.caf")
        let openWindow = try folder("B", in: clipsRoot, holding: "clip.caf")

        let result = AudioEditCaches.removeStale(
            scratchRoot: scratchRoot,
            clipsRoot: clipsRoot,
            isBookInUse: { $0 == inUse },
            isClipFolderInUse: { $0 == "B" }
        )

        XCTAssertEqual(result, AudioEditCaches.Result(removed: 3, kept: 2))
        for removed in [staleBook, cutShort, closedWindow] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
        for kept in [usedBook, notABook, openWindow] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        XCTAssertFalse(left.contains { $0.hasPrefix(AudioEditCaches.setAsidePrefix) }, "a folder set aside was left: \(left)")
    }

    /// The library's sweep at launch removes a book's scratch folder and a
    /// window's clip folder a crash left, and keeps those of an editor open
    /// now: its book's, while its session uses the book, and its window's
    /// clips, while the window is open.
    func testTheLibrarysSweepKeepsTheFoldersOfAnOpenEditor() async throws {
        let harness = try await openRamp(seconds: 4)
        let model = harness.model
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.copy()
        XCTAssertNotNil(model.clip?.file, "\(harness.announcements.sentences)")
        let scratch = try AudioEditScratch.folder(for: harness.fixture.book.id)
        let staleBook = try folder(UUID().uuidString, in: AudioEditScratch.root, holding: "processed-3.caf")
        let staleClips = try folder(UUID().uuidString, in: AudioEditCaches.clipsRoot, holding: "clip.caf")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: staleBook)
            try? FileManager.default.removeItem(at: staleClips)
        }

        let result = await withCheckedContinuation { continuation in
            harness.fixture.library.removeStaleAudioEditCachesInBackground { continuation.resume(returning: $0) }
        }

        XCTAssertGreaterThanOrEqual(result.removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleBook.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleClips.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "the open editor's scratch folder was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.clipFolder.path), "the open window's clips were removed")
        XCTAssertTrue(AudioEditCaches.isClipFolderInUse(model.clipFolder.lastPathComponent))

        model.windowClosed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.clipFolder.path))
        XCTAssertFalse(AudioEditCaches.isClipFolderInUse(model.clipFolder.lastPathComponent))
    }

    // MARK: - A Stretch the Caches Lost

    /// A filter's processed stretch that macOS emptied from the caches is
    /// made again, under the same name, when the editor next needs it: for
    /// the preview, for audio copied, and for an export, which holds the
    /// filtered sound.
    func testAFilteredStretchPurgedFromTheCachesIsMadeAgainWhenNeeded() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 4, for: self)
        fixture.library.audioFilterEngine = { .builtIn }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await model.loadPreview()
        await model.applyFilter(AudioFilterPreset(id: UUID(), name: "Quieter", chain: "volume=-6dB"), to: .wholeFile)
        let scratch = try AudioEditScratch.folder(for: fixture.book.id)
        let stretches = try processedStretches(in: scratch)
        XCTAssertFalse(stretches.isEmpty, "the filter kept no processed stretch")

        try FileManager.default.removeItem(at: scratch)
        await model.loadPreview()
        XCTAssertTrue(model.hasPreview, "\(harness.announcements.sentences)")
        XCTAssertEqual(try processedStretches(in: scratch), stretches, "made again under the same name")

        try FileManager.default.removeItem(at: scratch)
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.copy()
        XCTAssertNotNil(model.clip?.file, "\(harness.announcements.sentences)")

        try FileManager.default.removeItem(at: scratch)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("purged-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        await model.export(as: .wav, to: destination)
        XCTAssertEqual(harness.announcements.sentences.last, "Exported “\(destination.lastPathComponent)”.")
        let samples = try AudioTestFixtures.floatSamples(of: destination)
        XCTAssertEqual(samples.count, 32_000)
        let unfiltered = Float(32_000 * AudioTestFixtures.rampStep)
        XCTAssertEqual(AudioTestFixtures.peak(samples), unfiltered * 0.501, accuracy: unfiltered * 0.01, "the export holds the filtered sound")
    }

    /// Two renders of one stretch at once, as a preview and the level
    /// measurement of the one before can ask for, both get its processed
    /// sound, kept once, with nothing half written left behind.
    func testTwoRendersOfOneStretchAtOnceBothGetIt() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 2, for: self)
        let base = try await AudioEditBase.load(fixture.book.bookFileURL, name: fixture.book.fileInPackage)
        let scratch = try AudioEditScratch.folder(for: fixture.book.id)
        let processor = AudioFilterProcessor(
            sources: AudioEditComposition.Sources(base: base, package: fixture.package, scratch: scratch),
            engine: .builtIn
        )

        async let first = processor.process(base.timeline, chain: "volume=-6dB")
        async let second = processor.process(base.timeline, chain: "volume=-6dB")
        let (one, other) = try await (first, second)

        XCTAssertEqual(one, other)
        XCTAssertEqual(one.length, 16_000)
        XCTAssertEqual(try processedStretches(in: scratch).count, 1)
        let partial = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(partial, [], "a partial render was left behind")
    }

    // MARK: - Helpers

    /// A folder named `name` in `parent`, made with one small file named
    /// `file` in it.
    private func folder(_ name: String, in parent: URL, holding file: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: folder.appendingPathComponent(file))
        return folder
    }

    /// The names of the processed stretches in a book's scratch folder, in
    /// order.
    private func processedStretches(in scratch: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix("processed-") }
            .sorted()
    }
}
