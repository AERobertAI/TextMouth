import SwiftUI
import Combine

/// Root view for a library window. Each library window has its own navigation state.
struct LibraryWindowView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var libraryWindowRouter: LibraryWindowRouter
    @Environment(\.openWindow) private var openWindow

    @State private var currentFolderPath = ""
    /// The view this window shows (October 30, 2026): nil until the window
    /// first appears, when it takes the first view the View pop-up offers
    /// and keeps it, however the list of views changes, until the listener
    /// chooses another (or it is deleted).
    @State private var viewID: LibraryViewID?
    /// The Library's views, observed so the title and the view shown follow
    /// a change made in Settings or config.json.
    @ObservedObject private var views = LibraryViewDefinitionStore.shared
    @State private var showFileImporter = false
    /// Presents the New from Text sheet, from the toolbar or through the
    /// router for File > New from Text....
    @State private var showTextInput = false
    /// The NSWindow hosting this library view, captured via WindowAccessor
    @State private var hostWindow: PlatformWindow?
    /// The app-wide actions that reached this window while the library's
    /// files were on their way from the cloud, such as books opened from
    /// Finder, in order: all taken once the library opens, all refused, with
    /// the books named, if it does not.
    @State private var heldGlobalActions: [GlobalAction] = []

    /// Finder-style folder navigation history (back/forward with Cmd+[ / Cmd+])
    @StateObject private var folderNav = FolderNavigationHistory()
    /// The removal preferences, observed so the Remove Book dialog's words
    /// follow a change made in Settings, even while the dialog is open.
    @ObservedObject private var removal = RemovalPreferencesModel.shared

    var body: some View {
        // Read while the view is installed, as SwiftUI requires, and lent to
        // the router with this window's way of taking app-wide actions.
        let openReaderWindow = openWindow
        ZStack {
            // While the data directory can't be used, the whole window says
            // why, with Try Again and Quit, in place of the library (FR02).
            if let unavailability = libraryViewModel.dataDirectoryUnavailability {
                DataDirectoryUnavailableView(
                    unavailability: unavailability,
                    notice: libraryViewModel.dataDirectoryRefusalNotice,
                    onAnnounce: { libraryViewModel.announceDataDirectoryUnavailability(from: hostWindow) },
                    onTryAgain: { libraryViewModel.retryDataDirectory() },
                    onQuit: {
                        // Quitting is the Mac's; an iPhone app closes from
                        // the system, so the button does nothing there.
                        #if os(macOS)
                        QuitRequest.ask()
                        #endif
                    }
                )
            } else {
                LibraryView(
                    currentFolderPath: $currentFolderPath,
                    shownViewID: shownViewID,
                    showFileImporter: $showFileImporter,
                    showTextInput: $showTextInput,
                    onOpenBook: { book in
                        // No book opens while the library moves (FR02).
                        guard !refuseWhileTheLibraryMoves(.openBookWindow(book.id)) else { return }
                        openWindow(id: BookReaderWindowView.windowID, value: book.id)
                    }
                )
                // The feed downloads section, below the list while feed
                // downloads run, which insets the list by its height and
                // hides nothing of it, since downloads may run for many
                // minutes; redrawn alone, as the downloads report (FR10).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    FeedDownloadProgressObserver(library: libraryViewModel, progress: libraryViewModel.feedDownloadProgress)
                }

                // Import progress overlay, whose Cancel button stops ZIP
                // imports, redrawn alone as the imports report (FR10)
                if libraryViewModel.isImporting {
                    ProgressObserver(progress: libraryViewModel.importProgress) { progress in
                        // Ticks in the steps the time on a book moves in,
                        // counted from when the book under way began, so
                        // that time keeps up between the import's reports.
                        TimelineView(.periodic(from: progress.state.book?.startedAt ?? Date(), by: ImportProgressWording.timeOnBookStep)) { context in
                            LibraryWindowView.importProgressOverlay(for: libraryViewModel, at: context.date)
                        }
                    }
                }

                // Text extraction progress overlay (shown on startup or
                // re-extraction), redrawn alone as each book finishes (TODO PERF12)
                ProgressObserver(progress: libraryViewModel.textExtraction) { extraction in
                    if extraction.isExtracting {
                        ProgressOverlay(
                            title: "Extracting Text",
                            current: extraction.current,
                            total: extraction.total,
                            message: extraction.message,
                            itemNoun: TextExtractionProgress.itemNoun
                        )
                    }
                }

                // The conversion of the library's Ogg audio to AAC, a book at
                // a time, redrawn alone as each track is converted (B06)
                ProgressObserver(progress: libraryViewModel.oggConversion) { conversion in
                    if conversion.isConverting {
                        ProgressOverlay(
                            title: OggConversionProgress.title,
                            current: conversion.current,
                            total: conversion.total,
                            message: conversion.message,
                            itemNoun: OggConversionProgress.itemNoun
                        )
                    }
                }
            }
        }
        .background(WindowAccessor(onWindowFound: { window in
            if let previousWindow = hostWindow, previousWindow !== window {
                libraryWindowRouter.unregister(previousWindow)
            }
            hostWindow = window
            registerForGlobalActions(window, openingReadersWith: openReaderWindow)
            NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        }))
        // Tell SwiftUI that an existing Library scene can receive any incoming
        // file URL. Without this registration, external book opens fall
        // through to a newly-created instance of the first WindowGroup.
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .focusedValue(\.activeWindowType, .library)
        .onAppear {
            // A new window keeps the view it opens at, the first one offered.
            if viewID == nil {
                viewID = shownView.id
            }
            // SwiftUI shows a closed Library window again, rather than open
            // a new one, for a book opened from Finder; the window takes
            // app-wide actions again from then on. A window appearing for
            // the first time registers once its hosting window is found.
            if let hostWindow {
                registerForGlobalActions(hostWindow, openingReadersWith: openReaderWindow)
            }
            NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        }
        .onDisappear {
            refuseHeldGlobalActions()
            if let hostWindow {
                libraryWindowRouter.unregister(hostWindow)
            }
        }
        .navigationTitle(windowTitle)
        // A held action is taken when the library opens, or refused when the
        // fetch ends without it.
        .onChange(of: libraryViewModel.dataDirectoryUnavailability) {
            releaseHeldGlobalActions(openingReadersWith: openReaderWindow)
        }
        // Nor can they open when another library was chosen.
        .onChange(of: libraryViewModel.librarySwitchPending) {
            if libraryViewModel.librarySwitchPending {
                refuseHeldGlobalActions()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: FileImportService.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                // Chosen at the Reading List, the books join it, and go to
                // the folder this window showed last (FR09).
                libraryViewModel.importFiles(
                    urls: urls,
                    toFolder: currentFolderPath,
                    from: ImportOrigin(window: hostWindow),
                    addingToReadingList: shownView.kind == .readingList
                )
            case .failure(let error):
                libraryViewModel.errorMessage = error.localizedDescription
                libraryViewModel.showError = true
            }
        }
        .alert(libraryViewModel.errorTitle ?? "Error", isPresented: $libraryViewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryViewModel.errorMessage ?? "An unknown error occurred.")
        }
        // Remove book confirmation dialog (supports single or multiple books).
        // Its words say whether the files go to the Trash, are deleted
        // permanently, or stay, as the Trash preference chooses (TODO A08).
        .alert(
            removalChoice.title,
            isPresented: $libraryViewModel.showRemoveBookDialog
        ) {
            Button(removalChoice.deleteButtonTitle, role: .destructive) {
                let books = libraryViewModel.pendingRemoveBooks
                // Feed items' Delete Download says what it kept once the
                // question has closed, so its closing never cuts the words
                // off (REV11 F6).
                if let report = libraryViewModel.removeBooksAndDelete(books) {
                    VoiceOverAnnouncer.announceAfterSheetCloses(report, from: hostWindow)
                }
                libraryViewModel.pendingRemoveBooks = []
            }
            // Not for feed items alone, which Remove from Library Only refuses:
            // their Remove is Delete Download (FR11).
            if removalChoice.offersLibraryOnly {
                Button(removalChoice.keepButtonTitle) {
                    let books = libraryViewModel.pendingRemoveBooks
                    libraryViewModel.removeBooksFromLibraryOnly(books)
                    libraryViewModel.pendingRemoveBooks = []
                }
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingRemoveBooks = []
            }
        } message: {
            if !libraryViewModel.pendingRemoveBooks.isEmpty {
                Text(removalChoice.message)
            }
        }
        // Import questions: replace or keep a duplicate, delete an original
        // file, put a ZIP archive's books in a folder. They wait in one queue
        // and are asked one at a time, each in the window its import started
        // in (TODO I01).
        .importDecisionSheet(for: libraryViewModel, in: hostWindow, router: libraryWindowRouter)
        // While the library moves, its progress and Cancel, in a sheet that
        // keeps this window's library from changing until the move ends
        // (FR02). It closes by itself when the move does.
        .sheet(item: movingLibrary) { move in
            DataDirectoryMoveSheet(move: move)
        }
        // Open Book..., New from Text..., Import Folder…, Go to Library,
        // items opened from Finder, opening a book's reader, and Continue to
        // Next Book are app-wide actions: the router hands each to exactly
        // one window (TODO A05), this one through
        // `takeGlobalAction(_:openingReadersWith:)` when it is chosen.
        .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in
            if isKeyLibraryWindow, let path = folderNav.goBack() {
                currentFolderPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goForward)) { _ in
            if isKeyLibraryWindow, let path = folderNav.goForward() {
                currentFolderPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateUpLevel)) { _ in
            if isKeyLibraryWindow, let parent = FolderNavigationHistory.parentPath(of: currentFolderPath) {
                currentFolderPath = parent
            }
        }
        // Record folder changes into the navigation history and announce them.
        // The sort shown follows the location without any loading: the window
        // title and the list restore it from the library whenever they draw.
        .onChange(of: currentFolderPath) { _, newPath in
            folderNav.recordVisit(to: newPath)
            announceFolderChange(newPath)
        }
    }

    /// The words for the Remove Book confirmation, in the mode the Trash
    /// preference chooses.
    private var removalChoice: RemovalChoiceWording {
        RemovalChoiceWording(
            books: libraryViewModel.pendingRemoveBooks,
            movesToTrash: removal.preferences.movesToTrash
        )
    }

    /// The window title: the location and the sort it shows, restored from
    /// the setting saved for the location by the same function the list
    /// sorts with, so the title agrees with the order and the Sort menu from
    /// the first frame (TODO A06).
    private var windowTitle: String {
        // VoiceOver names the window by its title when moving between
        // windows, so it says why the library isn't shown (FR02).
        if let reason = libraryViewModel.dataDirectoryUnavailability {
            return DataDirectoryUnavailableText.title(for: reason)
        }
        let location = LibraryLocation(view: shownView, folderPath: currentFolderPath)
        return location.windowTitle(sortedBy: libraryViewModel.sortState(at: location))
    }

    /// The view this window shows: the one it keeps, or, before it first
    /// appears, or once the one it kept is deleted, the first view its
    /// pop-up offers (`LibraryViewModel.shownView`).
    private var shownView: LibraryViewDefinition {
        libraryViewModel.shownView(viewID, in: views.list, center: LibraryFeedFolders.shared.center).view
    }

    /// The binding the window's list shows its view through, set by the View
    /// pop-up and a feed row's open: the view this window keeps, even once
    /// it is deleted, so the list notices, moves to the first view offered,
    /// and says so (`LibraryView.followDeletedView`); before the window first
    /// appears, the first view offered.
    private var shownViewID: Binding<LibraryViewID> {
        Binding(get: { viewID ?? shownView.id }, set: { viewID = $0 })
    }

    /// Announce the new folder name and book count to VoiceOver when
    /// navigating; a feed's folder is announced with its feed's items
    /// counted (FR03).
    private func announceFolderChange(_ path: String) {
        let message = FolderNavigationHistory.announcement(
            for: path,
            library: libraryViewModel.library,
            feedFolders: .shared
        )
        // Through the announcer, which picks the window when this one isn't
        // known yet and records rather than posts under hosted tests (TODO
        // 3645).
        VoiceOverAnnouncer.announce(message, from: hostWindow)
    }

    /// True when this library window is the current key (focused) window.
    /// Used to prevent multiple library windows from all responding to the same
    /// global notification (e.g. opening a file dialog in every library window at once).
    private var isKeyLibraryWindow: Bool {
        guard let hostWindow = hostWindow else { return true }
        return hostWindow.isKeyWindow
    }

    // MARK: - App-Wide Actions (TODO A05)

    /// Registers this Library window with the router, lending it the way
    /// this window takes app-wide actions. The router decides which one
    /// window takes each action; this window never acts on an app-wide
    /// notification by itself, since SwiftUI keeps a closed Library window's
    /// view alive and still receiving notifications.
    ///
    /// - Parameters:
    ///   - window: This view's hosting window.
    ///   - openReaderWindow: This window's `openWindow` action, read while
    ///     the view was installed, which opens a book's reader window.
    private func registerForGlobalActions(_ window: PlatformWindow, openingReadersWith openReaderWindow: OpenWindowAction) {
        libraryWindowRouter.register(window) { action in
            takeGlobalAction(action, openingReadersWith: openReaderWindow)
        }
    }

    /// Refuses `actions` because the library can't be used: the window says
    /// so, and the requests the actions carried are dropped with them. Actions
    /// that were held while the files were on their way (`wasHeld`) are
    /// refused together in one sentence that names the books not opened.
    private func refuse(_ actions: [GlobalAction], wasHeld: Bool) {
        let message = wasHeld
            ? DataDirectoryUnavailableText.heldRefusal(of: actions)
            : actions.first.flatMap(DataDirectoryUnavailableText.refusal(of:))
        for action in actions {
            ReaderOpenRefusal.dropRequests(for: action)
        }
        guard let message else { return }
        libraryViewModel.refuseWhileDataDirectoryUnavailable(message, from: hostWindow)
    }

    /// Refuses every held action: the fetch failed, the window is closing, or
    /// another library was chosen. Does nothing when none is held.
    private func refuseHeldGlobalActions() {
        guard !heldGlobalActions.isEmpty else { return }
        let held = heldGlobalActions
        heldGlobalActions = []
        refuse(held, wasHeld: true)
    }

    /// Takes every held action, in order, once the library is open, or
    /// refuses them all when the library is unavailable and no longer on its
    /// way. Nothing happens while the files are still arriving.
    private func releaseHeldGlobalActions(openingReadersWith openReaderWindow: OpenWindowAction) {
        guard !heldGlobalActions.isEmpty else { return }
        let reason = libraryViewModel.dataDirectoryUnavailability
        guard reason?.isGettingFromCloud != true else { return }
        if reason == nil {
            let held = heldGlobalActions
            heldGlobalActions = []
            for action in held {
                takeGlobalAction(action, openingReadersWith: openReaderWindow)
            }
        } else {
            refuseHeldGlobalActions()
        }
    }

    /// Takes an app-wide action the router chose this Library window for.
    /// A panel is presented on this window, brought to the front first: a
    /// reader, Settings, or another Library window may be key, and the panel
    /// must appear where the user and VoiceOver are.
    private func takeGlobalAction(_ action: GlobalAction, openingReadersWith openReaderWindow: OpenWindowAction) {
        // Nothing is added to the library or opened from it while it can't
        // be used (FR02): the window comes forward and says so instead, and
        // a refused open's requests are dropped with it.
        // While the library's files are on their way, the action waits for
        // the library, which opens by itself, instead of being refused.
        if let reason = libraryViewModel.dataDirectoryUnavailability,
           DataDirectoryUnavailableText.refusal(of: action) != nil {
            bringToFront()
            if reason.isGettingFromCloud {
                heldGlobalActions.append(action)
            } else {
                refuse([action], wasHeld: false)
            }
            return
        }
        // Nor while it moves (FR02).
        if refuseWhileTheLibraryMoves(action) {
            bringToFront()
            return
        }
        switch action {
        case .openBookFile:
            bringToFront()
            showFileImporter = true
        case .newFromText:
            bringToFront()
            showTextInput = true
        case .importDAISYFolder:
            bringToFront()
            presentDAISYFolderPanel()
        case .goToLibrary:
            bringToFront()
        case .openFiles(let items):
            // A Library window is already on screen for the items: SwiftUI
            // shows one for them, or the router opened one. The import's
            // progress and questions appear there, and each book imported
            // opens afterwards.
            libraryViewModel.importAndOpenFiles(urls: items, from: ImportOrigin(window: hostWindow))
        case .openBookWindow(let bookID), .continueToNextBook(let bookID):
            // Opens the book's reader window, or brings it forward when it
            // is already open.
            openReaderWindow(id: BookReaderWindowView.windowID, value: bookID)
        }
    }

    /// Brings this Library window to the front as the key window, out of
    /// the Dock first when it was minimized.
    private func bringToFront() {
        #if os(macOS)
        guard let hostWindow else { return }
        if hostWindow.isMiniaturized {
            hostWindow.deminiaturize(nil)
        }
        hostWindow.makeKeyAndOrderFront(nil)
        #endif
    }

    // MARK: - While the Library Moves (FR02)

    /// The move under way, which presents its sheet while there is one. The
    /// model alone ends it: SwiftUI closing the sheet changes nothing.
    private var movingLibrary: Binding<DataDirectoryMoveProgress?> {
        Binding(get: { libraryViewModel.dataDirectoryMove }, set: { _ in })
    }

    /// Refuses `action` while the library moves, when it opens or adds a
    /// book: the move's sheet shows why and VoiceOver hears it, from the key
    /// window, which is the sheet itself while it is in front. A refused
    /// open's requests to start the book or read it from the reading list
    /// are dropped at once, rather than left to wait out their lifetime
    /// (`ReaderOpenRefusal`). Returns whether it was refused.
    private func refuseWhileTheLibraryMoves(_ action: GlobalAction) -> Bool {
        guard let move = libraryViewModel.dataDirectoryMove,
              let refusal = DataDirectoryMoveWording.refusal(of: action) else { return false }
        move.notice = refusal
        VoiceOverAnnouncer.announce(refusal)
        ReaderOpenRefusal.dropRequests(for: action)
        return true
    }

    /// Presents the folder-only panel of Library > Import Folder… as a
    /// sheet on this Library window (on its own while the window is not yet
    /// known), and imports the folders chosen into the folder being viewed
    /// (TODO I02), or, at the Reading List, into the folder viewed last, the
    /// books then joining the list (FR09).
    private func presentDAISYFolderPanel() {
        #if os(macOS)
        let panel = LibraryViewModel.makeDAISYFolderPanel()
        let destination = currentFolderPath
        let origin = ImportOrigin(window: hostWindow)
        let addsToReadingList = shownView.kind == .readingList
        let viewModel = libraryViewModel
        let importChosenFolders: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            viewModel.importDAISYFolders(
                panel.urls,
                toFolder: destination,
                from: origin,
                addingToReadingList: addsToReadingList
            )
        }
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: importChosenFolders)
        } else {
            panel.begin(completionHandler: importChosenFolders)
        }
        #else
        // Importing folders on iPhone is phase 1's: there is no folder
        // panel here, so the command does nothing.
        return
        #endif
    }
}

// MARK: - Progress Overlay

/// Reusable progress overlay for long-running operations (import, extraction, etc.)
///
/// For VoiceOver the overlay is a container labelled with its status
/// (`spokenStatus`). It contains its parts rather than combining them, so a
/// Cancel button inside stays a control of its own that VoiceOver can reach
/// and press (TODO I05).
struct ProgressOverlay: View {
    let title: String
    let current: Int
    let total: Int
    let message: String
    /// The noun the count names the items by, agreeing with the total:
    /// "0 of 1 book extracted", "3 of 10 books processed".
    let itemNoun: CountWording.Noun
    /// Lines shown under the message, each on its own: the import overlay's
    /// time on the book under way and its time left, or that the imports
    /// are cancelling (FR10). A caller that shows any words `spokenSummary`
    /// to read them too, as the import overlay does. None by default.
    var details: [String] = []
    /// What VoiceOver reads for the overlay, when the caller words it, as
    /// the import overlay does with every line it shows (FR10,
    /// `ImportProgressState.spokenStatus`); nil reads the title and the
    /// count, or the message while the bar only spins.
    var spokenSummary: String? = nil
    /// Cancels the operation the overlay shows, from its Cancel button or
    /// the Escape key; nil, the default, shows no Cancel button.
    var onCancel: (@MainActor () -> Void)? = nil

    /// What VoiceOver calls the Cancel button. Only the import overlay has
    /// one, so the name says what it cancels.
    static let cancelButtonLabel = "Cancel Import"
    /// What VoiceOver says the Cancel button does: it stops the ZIP archive
    /// imports under way and queued (`LibraryViewModel.cancelImports()`),
    /// though a book already being imported, such as a single audiobook
    /// archive, is finished first, and every book already imported stays.
    static let cancelButtonHint = "Stops importing ZIP archives after the current book. Books already imported stay in the library."

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 300)

                Text(CountWording.part(current, of: total, itemNoun))
                    .font(.body)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // By position: two details never repeat, but a line's words
            // change as the import moves, and its place stays the same.
            ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Self.cancelButtonLabel)
                    .accessibilityHint(Self.cancelButtonHint)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        // A container, not one combined element: combining would fold the
        // Cancel button into the status, out of VoiceOver's reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenStatus)
    }

    /// What VoiceOver reads for the overlay: the caller's own summary when
    /// it gives one (`spokenSummary`); otherwise its title, then the items
    /// done of the total while the bar has one, whose message, such as the
    /// text cache's "Updating text cache: 3 of 60...", only repeats the
    /// count. While the bar is indeterminate, the message carries the
    /// progress instead, so it follows the title; with no message, the
    /// title is read alone.
    var spokenStatus: String {
        if let spokenSummary {
            return spokenSummary
        }
        if total > 0 {
            return "\(title): \(CountWording.part(current, of: total, itemNoun))"
        }
        return message.isEmpty ? title : "\(title): \(message)"
    }
}

extension LibraryWindowView {
    /// The overlay a Library window shows while imports run, as it is at
    /// `now`: their progress, the time on the book under way and the time
    /// left (FR10), and a Cancel button, which Escape presses too, that
    /// stops the ZIP imports under way and queued
    /// (`LibraryViewModel.cancelImports()`, TODO I05). The window's body
    /// shows exactly this overlay, made here so tests can press the very
    /// button the window shows.
    static func importProgressOverlay(for libraryViewModel: LibraryViewModel, at now: Date = Date()) -> ProgressOverlay {
        let state = libraryViewModel.importProgress.state
        return ProgressOverlay(
            title: ImportProgressWording.title,
            current: state.current,
            total: state.total,
            message: state.message,
            itemNoun: ImportProgressWording.itemNoun,
            details: state.details(at: now),
            spokenSummary: state.spokenStatus(at: now),
            onCancel: libraryViewModel.cancelImports
        )
    }
}

/// Shows `content`, drawn from `progress`, and redraws only that content as
/// `progress` publishes (TODO PERF12): the Library window or the Storage
/// settings tab around it, which observe the library model, are not redrawn
/// for each report of the work `progress` follows, and the library model is
/// never republished for it. The text extraction's overlay and Storage rows
/// and the import overlay (FR10) each observe their progress this way.
struct ProgressObserver<Progress: ObservableObject, Content: View>: View {
    /// The progress shown, observed here alone.
    @ObservedObject var progress: Progress
    /// What to show for the progress as it is now.
    @ViewBuilder let content: (Progress) -> Content

    var body: some View {
        content(progress)
    }
}
