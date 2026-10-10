import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Export dialog and its command (FR05) as the user meets them: a
/// checkbox for each kind of item, labelled with its size, the first one
/// checked and taking VoiceOver's focus; a kind only in the cloud shown
/// unavailable, with the reason; the export into the folder chosen, ending
/// with one announcement; and the setting that puts an Export button in
/// the reader's toolbar, mirrored in config.json.
///
/// SwiftUI builds the spoken labels of its own checkboxes and buttons only
/// for a connected assistive app, so their words are pinned through
/// `BookExportWording` and `BookExportChoice`, where they come from, and
/// the checkboxes are found as the AppKit buttons SwiftUI draws for them.
/// Every export goes to a sandbox folder, never the user's Documents.
@MainActor
final class BookExportSheetTests: XCTestCase {

    // MARK: - The Dialog's Model

    /// Listing a text book gives a checkbox for each kind it holds, each
    /// labelled with its size, the reading text's as an estimate, with the
    /// first checked and Export available.
    func testListingGivesACheckboxForEachKindWithItsSize() async throws {
        let world = try makeIntegrationWorld("Export Dialog List")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Export Dialog List Folder"))

        await model.load()

        let cache = MarkdownCacheService.cacheURL(for: book)
        let source = size(of: book.bookFileURL)
        let markdown = size(of: cache)
        XCTAssertEqual(model.title, "Export \(book.title)")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.choices.map(\.label), [
            "Original file, \(source)",
            "Text as Markdown, \(markdown)",
            "Text as plain text, about \(markdown)",
        ])
        XCTAssertEqual(model.checked, [.originalFile])
        XCTAssertTrue(model.canExport)
        XCTAssertNil(model.cloudNotice)
    }

    /// Export writes the checked kinds into the folder chosen, off the main
    /// thread, announces how many items went where, and leaves the dialog
    /// nothing to say, so it closes.
    func testExportWritesTheCheckedKindsAndAnnouncesThem() async throws {
        let world = try makeIntegrationWorld("Export Dialog Export")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Export Dialog Export Folder")
        let model = BookExportModel(books: [book], library: world.library, destination: folder)
        await model.load()
        model.setChecked(true, for: .markdown)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(outcome.exported.count, 2)
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertNil(model.summary)
        XCTAssertEqual(model.phase, .finished(outcome))
        XCTAssertEqual(announcements.messages, ["Exported 2 items to \(BookExportWording.folderName(of: folder))."])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    /// A kind only in the cloud is unavailable, saying so in its label and
    /// in the line below the checkboxes; an export of the rest keeps its
    /// words in the dialog, the refusal included.
    func testAKindInTheCloudIsUnavailableAndNamed() async throws {
        let world = try makeIntegrationWorld("Export Dialog Cloud")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book).standardizedFileURL.path
        let cloud = MaintenanceFileAccess(
            isDataless: { $0.standardizedFileURL.path == cache },
            refusesRead: { $0.standardizedFileURL.path == cache }
        )
        let folder = try makeSandboxDirectory("Export Dialog Cloud Folder")
        let model = BookExportModel(books: [book], destination: folder, access: cloud)
        await model.load()
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        XCTAssertEqual(model.choices.map(\.isAvailable), [true, false, false])
        XCTAssertEqual(model.choices.dropFirst().map(\.label), ["Text as Markdown, in the cloud", "Text as plain text, in the cloud"])
        let refusal = LibraryCloudWording.notDownloaded(titles: [book.title])
        XCTAssertEqual(model.cloudNotice, refusal)

        model.setChecked(true, for: .markdown)
        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(outcome.exported.count, 1)
        XCTAssertFalse(BookExportModel.didEverything(outcome))
        let words = "Exported 1 item to \(BookExportWording.folderName(of: folder)). \(refusal)"
        XCTAssertEqual(model.summary, words)
        XCTAssertEqual(announcements.messages, [words])
    }

    /// With several books, each checkbox counts the books holding its kind,
    /// and the dialog counts the books in its title.
    func testSeveralBooksAreCountedPerKind() async throws {
        let world = try makeIntegrationWorld("Export Dialog Several")
        let audiobook = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1])
        let textBook = try world.importBook(from: writeSource(named: "Lock Keeper.md"))
        let model = BookExportModel(
            books: [audiobook, textBook],
            destination: try makeSandboxDirectory("Export Dialog Several Folder")
        )

        await model.load()

        XCTAssertEqual(model.title, "Export 2 Books")
        XCTAssertEqual(model.choices.map(\.kind), [.audio, .originalFile, .markdown, .plainText])
        XCTAssertTrue(model.choices.allSatisfy { $0.label.contains(", 1 book, ") }, "\(model.choices.map(\.label))")
        XCTAssertEqual(model.checked, [.audio])
    }

    /// A folder inside TextMouth's data directory is refused, saying why,
    /// and nothing is written there.
    func testAFolderInsideTheLibraryIsRefused() async throws {
        let world = try makeIntegrationWorld("Export Dialog Inside Library")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let inside = TextMouthPaths.root.appendingPathComponent("Exports \(UUID().uuidString)", isDirectory: true)
        let model = BookExportModel(books: [book], destination: inside)
        await model.load()
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = await model.export()

        XCTAssertNil(outcome)
        XCTAssertEqual(model.summary, BookExportWording.destinationInLibrary)
        XCTAssertEqual(announcements.messages, [BookExportWording.destinationInLibrary])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path), "the export wrote into the library")
        XCTAssertTrue(BookExportModel.isInsideDataDirectory(TextMouthPaths.root))
        XCTAssertFalse(BookExportModel.isInsideDataDirectory(try makeSandboxDirectory("Export Dialog Outside")))
    }

    /// With nothing checked, Export is unavailable and exports nothing.
    func testNothingIsExportedWithNothingChecked() async throws {
        let world = try makeIntegrationWorld("Export Dialog Unchecked")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Export Dialog Unchecked Folder"))
        await model.load()

        model.setChecked(false, for: .originalFile)

        XCTAssertFalse(model.canExport)
        let outcome = await model.export()
        XCTAssertNil(outcome, "Export ran with nothing checked")
    }

    // MARK: - The Dialog as Drawn

    /// The dialog draws a checkbox for each kind, the first checked and the
    /// one VoiceOver's focus moves to, and a kind only in the cloud
    /// unavailable.
    func testTheDialogDrawsACheckboxPerKindTheFirstTakingFocus() throws {
        let world = try makeIntegrationWorld("Export Dialog Drawn")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book).standardizedFileURL.path
        let cloud = MaintenanceFileAccess(isDataless: { $0.standardizedFileURL.path == cache })
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Export Dialog Drawn Folder"),
            access: cloud
        )

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 3 }) { hostingView in
            let boxes = checkboxes(in: hostingView)
            XCTAssertEqual(boxes.count, 3, "one checkbox per kind")
            XCTAssertEqual(boxes.map { $0.state == .on }, [true, false, false])
            XCTAssertEqual(boxes.map(\.isEnabled), [true, false, false], "the kinds in the cloud are unavailable")
            XCTAssertEqual(
                descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count,
                1,
                "VoiceOver's focus is asked for once, for the first checkbox"
            )
        }
    }

    /// Every word the dialog shows and speaks.
    func testTheDialogsWords() {
        XCTAssertEqual(BookExportWording.title(bookTitles: ["Emma"]), "Export Emma")
        XCTAssertEqual(BookExportWording.title(bookTitles: ["Emma", "Persuasion"]), "Export 2 Books")
        XCTAssertEqual(BookExportWording.commandTitle, "Export…")
        XCTAssertEqual(BookExportWording.commandTitle(count: 1), "Export…")
        XCTAssertEqual(BookExportWording.commandTitle(count: 3), "Export 3 Books…")
        XCTAssertEqual(
            BookExportKind.allCases.map(BookExportWording.name(of:)),
            [
                "Audio", "Original file", "Text as Markdown", "Text as plain text", "Original recording",
                "Original audio (before edits)", "Transcript",
            ]
        )
        XCTAssertEqual(Set(BookExportKind.allCases.map(BookExportWording.hint(for:))).count, BookExportKind.allCases.count)
        XCTAssertEqual(BookExportWording.destination(folderName: "Documents"), "Export to: Documents")
        XCTAssertEqual(BookExportWording.progress(done: 3, total: 40), "Exporting 3 of 40 items…")
        XCTAssertEqual(BookExportWording.progress(done: 0, total: 0), "Exporting…")
        let megabyte = ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .audio, bookCount: 1, availableItemCount: 1, fileCount: 12, byteCount: 1_200_000, inCloudCount: 0),
            "Audio, 12 files, \(megabyte)"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .audio, bookCount: 3, availableItemCount: 2, fileCount: 30, byteCount: 1_200_000, inCloudCount: 1),
            "Audio, 2 books, \(megabyte), 1 book in the cloud"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .markdown, bookCount: 1, availableItemCount: 0, fileCount: 0, byteCount: 0, inCloudCount: 1),
            "Text as Markdown, in the cloud"
        )
    }

    // MARK: - The Reader Toolbar's Setting

    /// The reader toolbar's Export button is off until it is turned on.
    /// Turning it on in Playback settings announces the change, so open
    /// readers show the button, and saves it to config.json; an edit of
    /// config.json turning it off reaches the setting and is announced too.
    func testTheToolbarSettingFollowsSettingsAndConfigJSON() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        var announced = 0
        let subscription = settings.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }

        XCTAssertFalse(settings.showExportInReaderToolbar, "the button is off until it is turned on")
        settings.showExportInReaderToolbar = true
        service.flushScheduledSave()

        XCTAssertGreaterThan(announced, 0, "turning it on announced nothing")
        XCTAssertEqual(defaults.object(forKey: BookExportPreferences.showInReaderToolbar.key) as? Bool, true)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["showExportInReaderToolbar"] as? Bool, true)

        let before = announced
        var edit = service.config
        edit.showExportInReaderToolbar = false
        settings.applyConfigChanges(edit)

        XCTAssertFalse(settings.showExportInReaderToolbar)
        XCTAssertGreaterThan(announced, before, "the edit of config.json announced nothing")
    }

    /// With the setting on, a reader window's toolbar holds one more item,
    /// the Export button; with it off, it holds none. The toolbar is drawn
    /// as SwiftUI draws a window's, in AppKit's toolbar, beside an item of
    /// the reader's own that is always there.
    func testTheReaderToolbarShowsExportOnlyWhileTheSettingIsOn() throws {
        let world = try makeIntegrationWorld("Export Toolbar")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let content = Text("Reader")
            .toolbar { ToolbarItem { Button("Where Am I?") {} } }
            .modifier(ReaderBookCommandsSupport(viewModel: reader, exportModel: .constant(nil), transcription: TranscriptionPresenter()))

        let host = ToolbarHost(content)
        defer { host.close() }
        guard host.waitForToolbar(self) else {
            throw XCTSkip("This macOS draws no toolbar for a hosted SwiftUI view")
        }
        let withoutExport = host.itemCount

        world.settings.showExportInReaderToolbar = true
        XCTAssertTrue(waitUntil { host.itemCount == withoutExport + 1 }, "the button did not show")

        world.settings.showExportInReaderToolbar = false
        XCTAssertTrue(waitUntil { host.itemCount == withoutExport }, "the button did not go")
        XCTAssertEqual(BookExportWording.toolbarLabel, "Export this book")
        XCTAssertEqual(BookExportWording.settingTitle, "Show Export in the reader toolbar")
    }

    // MARK: - File > Export… Without a Window to Take It

    /// File > Export… goes to the Library window or the book's window in
    /// front, or the window a sheet in front belongs to; with another window
    /// in front, such as Settings, or none, it says why instead: that no
    /// Library window or book is open, or, when one is open behind, to
    /// switch to it.
    func testExportSaysWhyWhenNoLibraryOrBookWindowIsInFront() {
        let settings = makeWindow()
        let library = makeWindow()
        let reader = makeWindow()
        defer { [settings, library, reader].forEach { $0.close() } }

        XCTAssertEqual(
            ExportCommandRouting.refusal(keyWindow: settings, libraryWindows: [], readerWindows: []),
            BookExportWording.noWindowOpen
        )
        XCTAssertEqual(
            ExportCommandRouting.refusal(keyWindow: nil, libraryWindows: [], readerWindows: []),
            BookExportWording.noWindowOpen
        )
        XCTAssertEqual(
            ExportCommandRouting.refusal(keyWindow: settings, libraryWindows: [library], readerWindows: []),
            BookExportWording.noWindowInFront
        )
        XCTAssertEqual(
            ExportCommandRouting.refusal(keyWindow: nil, libraryWindows: [], readerWindows: [reader]),
            BookExportWording.noWindowInFront
        )
        XCTAssertNil(ExportCommandRouting.refusal(keyWindow: library, libraryWindows: [library], readerWindows: [reader]))
        XCTAssertNil(ExportCommandRouting.refusal(keyWindow: reader, libraryWindows: [library], readerWindows: [reader]))
        XCTAssertEqual(BookExportWording.noWindowOpen, "No Library window or book is open, so there is nothing to export.")
    }

    /// The command announces why it cannot export and posts nothing; taken
    /// by a window in front, it posts the export command and announces
    /// nothing. A window closed but kept, as SwiftUI keeps closed windows,
    /// counts as none.
    func testExportFromTheMenuPostsOrSaysWhy() {
        let settings = makeWindow()
        let library = makeWindow()
        defer { [settings, library].forEach { $0.close() } }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        var posted = 0

        ExportCommandRouting.perform(keyWindow: settings, libraryWindows: [], readerWindows: [], post: { posted += 1 })
        XCTAssertEqual(announcements.messages, [BookExportWording.noWindowOpen])
        XCTAssertEqual(posted, 0, "the command was posted with no window to take it")

        ExportCommandRouting.perform(keyWindow: library, libraryWindows: [library], readerWindows: [], post: { posted += 1 })
        XCTAssertEqual(posted, 1, "the command was not posted")
        XCTAssertEqual(announcements.messages.count, 1, "an export taken was announced as refused")

        XCTAssertEqual(ExportCommandRouting.openWindows([library]), [], "a window never shown counted as open")
    }

    // MARK: - Fixtures

    /// Two chapters, as a Markdown book with chapter markers holds them.
    private static let twoChapters = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.
    """

    /// Writes the two-chapter book as a file named `name` in a sandbox
    /// folder of its own, for an import to read.
    private func writeSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("Export Dialog Source").appendingPathComponent(name)
        try Data(Self.twoChapters.utf8).write(to: file)
        return file
    }

    /// A window never shown, standing for one of the app's windows: kept
    /// alive after it closes, so a test's closing it releases nothing early.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The size of the file at `url` as the dialog words it.
    private func size(of url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: FileStamp(of: url)?.byteCount ?? -1, countStyle: .file)
    }

    /// The checkboxes SwiftUI drew inside `view`: the untitled AppKit
    /// buttons beside the labels it draws itself, in order.
    private func checkboxes(in view: NSView) -> [NSButton] {
        descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) && $0.title.isEmpty }
    }
}

// MARK: - Test Support

/// Captures what VoiceOver is asked to announce, for a test that awaits,
/// until `stop()` puts the previous poster back.
@MainActor
final class AnnouncementCapture {
    /// The words announced, oldest first.
    private(set) var messages: [String] = []
    /// The poster in place before the capture began.
    private let previous: VoiceOverAnnouncer.Poster

    init() {
        previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { [weak self] announcement, _ in
            self?.messages.append(announcement.message)
        }
    }

    /// Puts the previous poster back.
    func stop() {
        VoiceOverAnnouncer.poster = previous
    }
}

/// A SwiftUI view hosted in an offscreen window whose toolbar SwiftUI
/// draws, as it draws a window's toolbar in the app.
@MainActor
private final class ToolbarHost {
    /// The window, never shown.
    let window: NSWindow

    init<Content: View>(_ content: Content) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.sceneBridgingOptions = [.toolbars]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Hosted toolbar"
        window.contentView = hostingView
    }

    /// Whether SwiftUI gave the window a toolbar within a few seconds.
    func waitForToolbar(_ test: XCTestCase) -> Bool {
        test.waitUntil(timeout: 5) {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.toolbar != nil
        }
    }

    /// How many items the toolbar holds now.
    var itemCount: Int {
        window.contentView?.layoutSubtreeIfNeeded()
        return window.toolbar?.items.count ?? 0
    }

    /// Closes the window.
    func close() {
        window.close()
    }
}

