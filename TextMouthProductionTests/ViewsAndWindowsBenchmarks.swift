import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import TextMouth

/// Opt-in measurements for the views and windows review (PERF26 to PERF33):
/// what one publish costs the library list and the reader's sheets, what a
/// closed reader still holds, how many times a cloud refresh publishes, how
/// often Storage settings redraw, whether a waiting VoiceOver focus request
/// keeps a closed window alive, and how many test sandboxes the temporary
/// folder holds. Each result is printed as one `PERFVIEWSFIX <label>
/// <json>` line, for the before-and-after numbers in the commits and the
/// report.
///
/// Normal runs skip every test here. Set TEXTMOUTH_VIEW_BENCHMARKS=1 to run
/// them; for xcodebuild, TEST_RUNNER_TEXTMOUTH_VIEW_BENCHMARKS=1. Times are
/// main-thread CPU in a Debug build, and vary with the machine's load;
/// counts of body evaluations, derivations, and publishes do not.
@MainActor
final class ViewsAndWindowsBenchmarks: XCTestCase {
    /// The environment variable that opts in.
    nonisolated static let optInVariable = "TEXTMOUTH_VIEW_BENCHMARKS"

    /// The views whose body evaluations the list measurements count.
    private static let listViews = ["LibraryView.list", "LibraryBookListRow", "BookRow"]
    /// The views whose body evaluations the sheet measurements count.
    private static let sheetViews = [
        "HeadingNavigatorView", "HeadingNavigatorRow", "BookVoicePickerView", "BookmarkPanelView", "SleepTimerView",
    ]

    // MARK: - VoiceOver Focus (PERF33)

    /// Whether a VoiceOver focus request still waiting for a window keeps
    /// that window alive after it closes: within the request's delay, and
    /// once the request has run. The window's content is emptied, never
    /// removed, so the request gives up safely in every version of the app.
    func testFocusRequestAndClosedWindow() throws {
        try requireOptIn()
        let kinds: [(String, () -> NSView)] = [
            ("standard", {
                let trigger = StandardVoiceOverFocusTriggerView()
                trigger.focusDelay = 1.0
                return trigger
            }),
            ("sheet", {
                let trigger = VoiceOverFocusTriggerView()
                trigger.focusDelay = 1.0
                return trigger
            }),
        ]
        for (kind, makeTrigger) in kinds {
            weak var closedWindow: NSWindow?
            autoreleasepool {
                let window = OffscreenTestWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.isReleasedWhenClosed = false
                window.title = "Views and windows benchmark"
                let content = NSView()
                window.contentView = content
                // Joining the window schedules the request, a second away.
                content.addSubview(makeTrigger())
                window.contentView = NSView()
                window.close()
                closedWindow = window
            }
            settle(nil, seconds: 0.1)
            let aliveWithinDelay = closedWindow != nil
            settle(nil, seconds: 1.3)
            emit("focus.\(kind)", [
                "aliveWithinDelay": aliveWithinDelay,
                "aliveAfterRequestRan": closedWindow != nil,
            ])
        }
    }

    // MARK: - Test Sandboxes (PERF26)

    /// The hosted-test sandboxes in the temporary folder, and how many
    /// belong to a process that has ended.
    func testSandboxInventory() throws {
        try requireOptIn()
        let temporary = FileManager.default.temporaryDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.hasPrefix(TextMouthRuntime.sandboxNamePrefix) }
        let processes = names.compactMap(TextMouthRuntime.sandboxProcess(named:))
        let running = processes.filter(TextMouthRuntime.isProcessRunning)
        emit("sandboxes", [
            "total": names.count,
            "processRunning": running.count,
            "processEnded": processes.count - running.count,
        ])
    }

    // MARK: - Closed Reader (PERF27)

    /// What a reader keeps once its window closes, for a tiny book and for
    /// a 2-million-character book with a minute of rendered speech, and the
    /// malloc growth each leaves while held, as SwiftUI holds a closed
    /// window's reader. The difference is what grows with the book.
    func testWhatAClosedReaderKeeps() throws {
        try requireOptIn()
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let tinyBook = try makeMarkdownBook(chapters: 1, charactersPerChapter: 400, sectionsPerChapter: 1)
        let bigBook = try makeMarkdownBook(chapters: 40, charactersPerChapter: 50_000, sectionsPerChapter: 4)
        // A first reader pays the one-time costs: frameworks, voices, fonts.
        _ = readerLifecycle(of: tinyBook, settings: settings, renderedSeconds: 0)
        let tiny = readerLifecycle(of: tinyBook, settings: settings, renderedSeconds: 0)
        let big = readerLifecycle(of: bigBook, settings: settings, renderedSeconds: 60)
        let tinyGrowth = tiny["growthWhileClosedReaderHeldMB"] as? Double ?? 0
        let bigGrowth = big["growthWhileClosedReaderHeldMB"] as? Double ?? 0
        emit("readerClose", [
            "tiny": tiny,
            "big": big,
            "bigMinusTinyMB": ((bigGrowth - tinyGrowth) * 100).rounded() / 100,
        ])
    }

    /// Opens a reader for `book` in a hosted ReaderView, gives it
    /// `renderedSeconds` of rendered speech, closes it as its window's
    /// disappearance does, takes the view down, and holds it, as SwiftUI
    /// holds a closed reader window's reader. (An offscreen window that
    /// never becomes key escapes that retention, so the benchmark holds the
    /// reader itself.) Reports what the closed reader still holds and the
    /// malloc growth it leaves.
    private func readerLifecycle(of book: Book, settings: SettingsViewModel, renderedSeconds: TimeInterval) -> [String: Any] {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        settle(nil, seconds: 0.5)
        let before = mallocBytesInUse()
        var reader: ReaderViewModel? = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: settings,
            notificationCenter: NotificationCenter()
        )
        if let reader {
            let hosted = hostOffscreen(
                ReaderView(viewModel: reader)
                    .environmentObject(SoundEffectService())
                    .environmentObject(settings)
            )
            _ = waitUntil(timeout: 60) {
                hosted.hostingView.layoutSubtreeIfNeeded()
                return !reader.isLoading
            }
            if renderedSeconds > 0 {
                reader.speechService.audioEngine._installRenderedAudioForTesting(lasting: renderedSeconds)
            }
            settle(hosted.hostingView, seconds: 1)
            reader.close()
            takeDown(hosted.window)
        }
        settle(nil, seconds: 1.5)
        let result: [String: Any] = [
            "contentKept": reader?.content != nil,
            "headingsKept": reader?.headings.count ?? 0,
            "renderedAudioKept": reader?.holdsRenderedSpeech ?? false,
            "textWindowKeptCharacters": reader?.displayVisibleTextWindow.count ?? 0,
            "growthWhileClosedReaderHeldMB": megabytes(mallocBytesInUse() - before),
        ]
        reader = nil
        settle(nil, seconds: 1)
        return result
    }

    // MARK: - Library List (PERF28)

    /// What one publish that changes one book costs a hosted LibraryView at
    /// four places in a 643-book library, with the window open and after it
    /// closes: main-thread time, how many lists the model derived, and how
    /// many times the list and its rows ran per publish.
    func testLibraryListPerPublish() throws {
        try requireOptIn()
        let model = LibraryViewModel(initializeServices: false)
        model.library = ViewsAndWindowsFixtures.shapedLibrary()
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        guard let changing = model.library.books.first(where: { $0.folderPath == ViewsAndWindowsFixtures.manualFolder })?.id else {
            return XCTFail("The shaped library has no book in manual order")
        }
        var offset = 1_000
        let changeOneBook: (Int) -> Void = { _ in
            offset += 1
            ViewsAndWindowsFixtures.move(changing, to: offset, in: model)
        }
        for place in Self.places {
            let savedSorts = model.library.folderSortSettings
            if let sort = place.sort {
                model.library.folderSortSettings[place.location.sortSettingsKey] = sort
            }
            let view = LibraryView(
                currentFolderPath: .constant(place.location.folderPath),
                category: .constant(place.location.category),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings)
            let layoutStart = mainThreadCPU()
            let hosted = hostOffscreen(view)
            let firstLayout = milliseconds(since: layoutStart)
            settle(hosted.hostingView, seconds: 1)
            var open = perPublish(hosted.hostingView, model: model, counting: Self.listViews, changeOneBook)
            open["firstLayoutMs"] = firstLayout
            open["pureRepublish"] = perPublish(hosted.hostingView, model: model, counting: Self.listViews) { _ in
                model.objectWillChange.send()
            }
            emit("list.\(place.name)", open)
            // The same publishes once the window has closed, its view kept:
            // nothing lays out a closed window, so neither does this.
            hosted.window.close()
            settle(nil, seconds: 0.5)
            emit("list.\(place.name).closed", perPublish(nil, model: model, counting: Self.listViews, changeOneBook))
            takeDown(hosted.window)
            settle(nil, seconds: 0.3)
            model.library.folderSortSettings = savedSorts
        }
    }

    /// A place in the library a list is measured at.
    private struct Place {
        let name: String
        let location: LibraryLocation
        let sort: FolderSortSetting?
    }

    /// The places measured: every book by Date Added, the root's folders,
    /// and the 134-book folder by title and in manual order.
    private static let places = [
        Place(name: "allItems643", location: LibraryLocation(category: .allItems, folderPath: ""), sort: nil),
        Place(name: "rootFolder", location: LibraryLocation(category: .folders, folderPath: ""), sort: nil),
        Place(
            name: "manualFolder134Title",
            location: LibraryLocation(category: .folders, folderPath: ViewsAndWindowsFixtures.manualFolder),
            sort: FolderSortSetting(sortField: .title, sortAscending: true)
        ),
        Place(
            name: "manualFolder134Manual",
            location: LibraryLocation(category: .folders, folderPath: ViewsAndWindowsFixtures.manualFolder),
            sort: FolderSortSetting(sortField: .manual, sortAscending: true)
        ),
    ]

    // MARK: - Reader Sheets (PERF30)

    /// What one reader publish (every 0.12 s while a book plays) costs each
    /// of the reader's sheets, presented as ReaderView presents them: inside
    /// a parent that observes the reader and builds the sheet again each
    /// time it redraws.
    func testReaderSheetsPerPublish() throws {
        try requireOptIn()
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let book = try makeMarkdownBook(chapters: 36, charactersPerChapter: 6_000, sectionsPerChapter: 4)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: settings,
            notificationCenter: NotificationCenter()
        )
        defer { reader.close() }
        _ = waitUntil(timeout: 60) { !reader.isLoading }
        let sheets: [(String, AnyView)] = [
            ("headings", AnyView(ReaderSheetHost(reader: reader) { HeadingNavigatorView(viewModel: $0) })),
            ("voice", AnyView(ReaderSheetHost(reader: reader) { BookVoicePickerView(viewModel: $0) })),
            ("bookmarks", AnyView(ReaderSheetHost(reader: reader) { BookmarkPanelView(viewModel: $0) })),
            ("sleepTimer", AnyView(ReaderSheetHost(reader: reader) {
                SleepTimerView(
                    viewModel: $0,
                    sleepTimerService: $0.sleepTimerService,
                    onStartPlayback: {},
                    onClose: {},
                    autoClose: false
                )
            })),
        ]
        for (name, sheet) in sheets {
            let hosted = hostOffscreen(sheet, size: NSSize(width: 600, height: 700))
            settle(hosted.hostingView, seconds: 1.5)
            var result = perPublish(hosted.hostingView, counting: Self.sheetViews) { _ in reader.objectWillChange.send() }
            result["headings"] = reader.headings.count
            emit("sheet.\(name)", result)
            takeDown(hosted.window)
            settle(nil, seconds: 0.5)
        }
    }

    // MARK: - Cloud Refresh (PERF31)

    /// How many times one cloud refresh of 643 books publishes the shared
    /// states, the first time and again with nothing changed.
    func testCloudRefreshPublishes() async throws {
        try requireOptIn()
        let states = BookCloudStates()
        let storage = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
        let books = ViewsAndWindowsFixtures.shapedLibrary().books
        for (index, book) in books.enumerated() {
            storage.setState(index % 2 == 0 ? .inCloud : .downloaded, of: book.id)
        }
        let packages = books.map { BookPackage($0) }
        var publishes = 0
        let counter = states.objectWillChange.sink { _ in publishes += 1 }
        defer { counter.cancel() }
        let firstStart = mainThreadCPU()
        await states.refresh(packages, using: storage)
        let first = publishes
        let firstMs = milliseconds(since: firstStart)
        let secondStart = mainThreadCPU()
        await states.refresh(packages, using: storage)
        emit("cloudRefresh643", [
            "firstPublishes": first,
            "firstMainThreadMs": firstMs,
            "secondPublishes": publishes - first,
            "secondMainThreadMs": milliseconds(since: secondStart),
        ])
    }

    // MARK: - Storage Settings (PERF32)

    /// How many times the Storage settings pane redraws per library publish.
    func testStorageSettingsPerPublish() throws {
        try requireOptIn()
        let model = LibraryViewModel(initializeServices: false)
        model.library = ViewsAndWindowsFixtures.shapedLibrary()
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        guard let changing = model.library.books.first?.id else { return XCTFail("The shaped library is empty") }
        let hosted = hostOffscreen(
            StorageSettingsView().environmentObject(model).environmentObject(settings),
            size: NSSize(width: 600, height: 1_400)
        )
        settle(hosted.hostingView, seconds: 1)
        var offset = 1_000
        let result = perPublish(hosted.hostingView, counting: ["StorageSettingsView"]) { _ in
            offset += 1
            ViewsAndWindowsFixtures.move(changing, to: offset, in: model)
        }
        emit("storageSettings", result)
        takeDown(hosted.window)
    }

    // MARK: - Measuring

    /// Skips the calling test unless the benchmarks were asked for.
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment[Self.optInVariable] == "1" else {
            throw XCTSkip("Set \(Self.optInVariable)=1 (TEST_RUNNER_\(Self.optInVariable)=1 for xcodebuild) to run")
        }
    }

    /// Prints one result line for the log to be grepped.
    private func emit(_ label: String, _ values: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("PERFVIEWSFIX \(label) \(data.map { String(decoding: $0, as: UTF8.self) } ?? "{}")")
    }

    /// CPU time the calling thread, here the main thread, has used, in
    /// nanoseconds.
    private func mainThreadCPU() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    /// Main-thread milliseconds since `start`, to two decimals.
    private func milliseconds(since start: UInt64) -> Double {
        (Double(mainThreadCPU() - start) / 10_000).rounded() / 100
    }

    /// Megabytes, to two decimals.
    private func megabytes(_ bytes: Int) -> Double {
        (Double(bytes) / 1_048_576 * 100).rounded() / 100
    }

    /// What `publish` costs the views in `view`, averaged over `count`
    /// publishes after three warm-ups: main-thread milliseconds, how many
    /// times the body of each view in `names` ran per publish, and, given
    /// `model`, how many lists its cache derived per publish.
    private func perPublish(
        _ view: NSView?,
        model: LibraryViewModel? = nil,
        count: Int = 20,
        counting names: [String],
        _ publish: (Int) -> Void
    ) -> [String: Any] {
        for warmUp in 0..<3 {
            publish(-1 - warmUp)
            flush(view)
        }
        let countsBefore = names.map { ViewBodyCounter.count(of: $0) }
        let derivationsBefore = model?.listCache.derivationCount ?? 0
        let start = mainThreadCPU()
        for index in 0..<count {
            publish(index)
            flush(view)
        }
        var result: [String: Any] = ["msPerPublish": milliseconds(since: start) / Double(count)]
        for (name, countBefore) in zip(names, countsBefore) {
            result["\(name) per publish"] = Double(ViewBodyCounter.count(of: name) - countBefore) / Double(count)
        }
        if let model {
            result["derivations per publish"] = Double(model.listCache.derivationCount - derivationsBefore) / Double(count)
        }
        return result
    }
}
