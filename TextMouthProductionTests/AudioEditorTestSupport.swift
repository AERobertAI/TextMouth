import AVFoundation
import XCTest
@testable import TextMouth

// Stand-ins and fixtures shared by the audio editor window's tests (FR04),
// so each exists once. No test of the editor ever plays a sound: the
// player is `FakeAudioEditorPlayer`, which only notes what it was asked.

// MARK: - A Player That Makes No Sound

/// A player for the audio editor that plays nothing: it notes what the
/// editor asked of it, and a test moves its clock and ends its plays.
@MainActor
final class FakeAudioEditorPlayer: AudioEditorPlayback {
    /// One play asked for: where from, and where it was to stop.
    struct Play: Equatable {
        let from: TimeInterval
        let until: TimeInterval?
    }

    var onStop: (@MainActor () -> Void)?
    var onTime: (@MainActor (TimeInterval) -> Void)?

    /// How many frames each preview loaded lasted, in order.
    private(set) var loadedFrames: [Int64] = []
    /// Where each preview was loaded, in order.
    private(set) var loadedAt: [TimeInterval] = []
    /// Every play asked for, in order.
    private(set) var plays: [Play] = []
    /// How many times it was paused.
    private(set) var pauses = 0
    /// Every seek, in order.
    private(set) var seeks: [TimeInterval] = []
    /// Whether it was closed.
    private(set) var isClosed = false
    /// The last preview loaded, kept so its composition can be checked.
    private(set) var preview: AudioEditComposition?

    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0

    func load(_ preview: AudioEditComposition, at time: TimeInterval) {
        self.preview = preview
        loadedFrames.append(preview.frames)
        loadedAt.append(time)
        isPlaying = false
        currentTime = time
    }

    func play(from time: TimeInterval, until end: TimeInterval?) {
        plays.append(Play(from: time, until: end))
        currentTime = time
        isPlaying = true
    }

    func pause() {
        pauses += 1
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        seeks.append(time)
        currentTime = time
        isPlaying = false
    }

    func close() {
        isClosed = true
        isPlaying = false
        onStop = nil
        onTime = nil
    }

    // MARK: What the Test Does

    /// The clock moves to `time` while playing, as the player reports it.
    func tick(to time: TimeInterval) {
        currentTime = time
        onTime?(time)
    }

    /// The play under way stops by itself, at `time`: its end time, or the
    /// end of the audio.
    func finishPlaying(at time: TimeInterval) {
        currentTime = time
        isPlaying = false
        onStop?()
    }
}

// MARK: - Sentences Announced

/// The sentences an editor announced, in order.
@MainActor
final class EditorAnnouncements {
    /// Every sentence, oldest first.
    var sentences: [String] = []

    /// The announcer to hand a model. It holds the recorder weakly, as the
    /// model must not keep it; a model that outlives its recorder, as one a
    /// teardown closes does, says its sentences to no one, and never stops
    /// the test host.
    var announce: @MainActor (String) -> Void {
        { [weak self] sentence in self?.sentences.append(sentence) }
    }
}

// MARK: - A Book to Edit

/// A library of one audiobook in a package of its own, in a folder of the
/// sandbox's library, for the editor's tests: its audio written by the test.
@MainActor
struct AudioEditorTestBook {
    /// The library holding the book.
    let library: LibraryViewModel
    /// The book.
    let book: Book
    /// Its package.
    let package: URL

    /// Frames a second of the books these tests write.
    static let rate = 8_000.0

    /// A book named `name` (its file's name, extension included) whose
    /// audio `write` writes to the URL it is given; the folder, the book's
    /// scratch folder, and the reading text are removed as `test` ends.
    static func make(
        named name: String,
        for test: XCTestCase,
        write: (URL) throws -> Void
    ) throws -> AudioEditorTestBook {
        let folderPath = "Audio Editor \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let package = folder.appendingPathComponent("Editor-Unknown-1-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library()
        let book = Book(
            title: (name as NSString).deletingPathExtension,
            format: .audio,
            filePath: package.appendingPathComponent(name).path,
            md5Hash: "before-\(UUID().uuidString)",
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            AudioEditScratch.remove(for: book.id)
            ReadingTextCache.shared.remove(bookID: book.id)
        }
        try write(book.bookFileURL)
        library.library.addBook(book)
        return AudioEditorTestBook(library: library, book: book, package: package)
    }

    /// A book of `seconds` seconds of an identity ramp (`AudioTestFixtures`),
    /// whose every sample names its frame.
    static func ramp(seconds: Double, named name: String = "Harbour Survey.wav", for test: XCTestCase) throws -> AudioEditorTestBook {
        try make(named: name, for: test) { url in
            try AudioTestFixtures.writeIdentityRamp(to: url, frames: Int(seconds * rate), sampleRate: rate)
        }
    }
}

// MARK: - An Editor on a Ramp

extension XCTestCase {
    /// An editor on `seconds` seconds of an identity ramp in a WAVE file
    /// (`AudioEditorTestBook.ramp`), its preview loaded, playing half a
    /// second after each move only when `playsAfterMoves` says so. The
    /// harness, its library and its recorder of sentences among it, which
    /// the model holds only weakly, is kept until the test ends, when the
    /// editor is closed.
    @MainActor
    func openRamp(seconds: Double, playsAfterMoves: Bool = false) async throws -> EditorHarness {
        let harness = try await EditorHarness.open(try AudioEditorTestBook.ramp(seconds: seconds, for: self), for: self)
        AudioEditorPreferences.playAfterMoves.write(playsAfterMoves, to: harness.store)
        await harness.model.loadPreview()
        addTeardownBlock { @MainActor in harness.model.windowClosed() }
        return harness
    }
}
