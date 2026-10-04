import AppKit

// MARK: - A Book's Tracks

/// One audio file of a book of several tracks, as the editor offers it.
struct AudioEditorTrack: Equatable, Hashable, Sendable {
    /// The file's path inside the book's package: "audio/Disc 2/03.mp3".
    let path: String
    /// The track's name: its chapter title from the book's manifest, or
    /// else its file's name without the extension, as the reader names it.
    let title: String
}

/// What a book's audio is, as far as the editor is concerned.
enum AudioEditorTracks: Equatable, Sendable {
    /// One file: the book's own.
    case oneFile
    /// A folder of tracks, in the order the book plays them.
    case tracks([AudioEditorTrack])
    /// A folder whose manifest plays sections that are stretches of its
    /// tracks, which an edit to a track would move: not editable yet.
    case sections

    /// The tracks of `book`, read from its package; for a book kept in one
    /// file, `.oneFile`. Reads the file system: call it off the main thread.
    /// - Throws: the folder's read errors.
    static func of(_ book: Book) throws -> AudioEditorTracks {
        let folder = book.bookFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .oneFile
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(AudioManifest.self, from: $0) }
        if let segments = manifest?.segments, !segments.isEmpty {
            return .sections
        }
        // Each track by its name inside the folder, as the manifest names
        // it, and by its path inside the package, as the edit history does.
        let package = book.tmbDirectory
        let files = try AudioBookParser.audioFiles(in: folder)
        var pathsByName: [String: String] = [:]
        for file in files {
            guard let path = AudioEditPackage.path(of: file, in: package),
                  let name = AudioEditPackage.path(of: file, in: folder) else { continue }
            pathsByName[name] = path
        }
        let ordered = AudioBookParser.orderedFileNames(Array(pathsByName.keys), manifestOrder: manifest?.order)
        return .tracks(ordered.compactMap { name in
            guard let path = pathsByName[name] else { return nil }
            let title = manifest?.chapters?[name] ?? ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            return AudioEditorTrack(path: path, title: title)
        })
    }
}

// MARK: - The Editor's Windows

/// What the launcher needs to know of the editor's windows: which books'
/// are open, and which are being opened. The app's controller
/// (`AudioEditorWindowController`), or a stand-in in tests, which opens no
/// window.
@MainActor
protocol AudioEditorWindowing: AnyObject {
    /// Whether `bookID`'s editor is open.
    func isOpen(_ bookID: UUID) -> Bool
    /// The window of `bookID`'s editor, while it is open.
    func window(for bookID: UUID) -> NSWindow?
    /// Brings `bookID`'s editor forward, if it is open.
    func bringForward(_ bookID: UUID)
    /// Notes that `bookID`'s editor is being opened, unless it is open or
    /// opening already; the result says whether it may open.
    func beginOpening(_ bookID: UUID) -> Bool
    /// Notes that opening `bookID`'s editor has ended, opened or not.
    func endOpening(_ bookID: UUID)
}

extension AudioEditorWindowController: AudioEditorWindowing {}

// MARK: - Opening the Editor

/// Opens the audio editor on a book (FR04), from a library row's Edit
/// Audio… (its context menu or its VoiceOver action) or the reader's Book
/// menu: asks which track for a book of several, closes the book's reader
/// first with a sentence saying why, opens the book's edit session, and
/// opens the window around it. Each refusal is said in a sentence.
@MainActor
enum AudioEditorLauncher {
    /// Whether `book`'s audio can be edited: an audiobook kept in a package
    /// of its own, as the edit history and the originals live there, the
    /// same books a transcript can be saved for.
    static func canEdit(_ book: Book) -> Bool {
        LibraryTranscriptionCommand.isTranscribable(book)
    }

    /// How opening ended.
    enum Outcome: Equatable {
        /// The editor opened on the book (or the track named).
        case opened(track: String?)
        /// The book's editor was open already and came forward.
        case broughtForward
        /// The user cancelled a question.
        case cancelled
        /// Nothing opened, for the reason given, which was said.
        case refused(String)
    }

    /// What opening reaches outside itself: the app's alerts, reader
    /// windows, edit sessions, and windows, or stand-ins in tests.
    struct Services {
        /// Reads a book's tracks (`AudioEditorTracks.of`), off the main
        /// thread.
        var readTracks: @Sendable (Book) throws -> AudioEditorTracks
        /// Asks which of the tracks to edit; nil when cancelled.
        var chooseTrack: @MainActor (_ book: Book, _ tracks: [AudioEditorTrack], _ window: NSWindow?) async -> AudioEditorTrack?
        /// Asks whether to start over when the edit history can't be read.
        var confirmStartOver: @MainActor (_ book: Book, _ window: NSWindow?) async -> Bool
        /// Asks the reader of a book to close.
        var closeReader: @MainActor (UUID) -> Void
        /// Opens a book's edit session (`AudioEditSession.open`).
        var openSession: @MainActor (_ bookID: UUID, _ audioFile: String?, _ library: LibraryViewModel, _ startingOver: Bool) async throws -> AudioEditSession
        /// Makes the window's model for an open session and shows it.
        var present: @MainActor (_ book: Book, _ track: AudioEditorTrack?, _ session: AudioEditSession) -> Void
        /// Says a sentence through VoiceOver, from a window.
        var announce: @MainActor (_ sentence: String, _ window: NSWindow?) -> Void
        /// Shows an alert saying why the editor couldn't open.
        var showFailure: @MainActor (_ message: String, _ window: NSWindow?) -> Void
        /// How long a reader is given to close, in seconds.
        var readerCloseTimeout: TimeInterval = 3
    }

    /// The app's way in: opens the editor on `book`, in `library`, asked
    /// from `window`, as the type describes.
    static func edit(_ book: Book, in library: LibraryViewModel, from window: NSWindow?) {
        Task {
            _ = await open(book, in: library, from: window, controller: AudioEditorWindowController.shared, services: .app)
        }
    }

    /// Opens the editor on `book`, in `library`, asked from `window`, through
    /// `controller`'s windows and `services`, and returns how it ended.
    static func open(
        _ book: Book,
        in library: LibraryViewModel,
        from window: NSWindow?,
        controller: AudioEditorWindowing,
        services: Services
    ) async -> Outcome {
        guard canEdit(book) else {
            return refuse(AudioEditorWording.notAnAudiobook, from: window, services: services)
        }
        if controller.isOpen(book.id) {
            controller.bringForward(book.id)
            services.announce(AudioEditorWording.alreadyOpen(book: book.title), controller.window(for: book.id) ?? window)
            return .broughtForward
        }
        // A second Edit Audio… while the first is still asking or opening
        // does nothing more.
        guard controller.beginOpening(book.id) else { return .cancelled }
        defer { controller.endOpening(book.id) }

        // Which file: the book's own, or the track the user chooses.
        let tracks: AudioEditorTracks
        do {
            let read = services.readTracks
            tracks = try await OffMainWork.runThrowing { try read(book) }
        } catch {
            return refuse(AudioEditorWording.openFailed(book: book.title, reason: error.localizedDescription), from: window, services: services, alert: true)
        }
        var track: AudioEditorTrack?
        switch tracks {
        case .oneFile:
            track = nil
        case .sections:
            return refuse(AudioEditorWording.sectionsNotEditable(book: book.title), from: window, services: services, alert: true)
        case .tracks(let list):
            guard let first = list.first else {
                return refuse(AudioEditorWording.noTracks(book: book.title), from: window, services: services, alert: true)
            }
            if list.count == 1 {
                track = first
            } else {
                guard let chosen = await services.chooseTrack(book, list, window) else { return .cancelled }
                track = chosen
            }
        }

        // The book's reader closes first: a save replaces the file it plays.
        if library.openBookIDs.contains(book.id) {
            services.announce(AudioEditorWording.closingReader(book: book.title), window)
            services.closeReader(book.id)
            let deadline = Date().addingTimeInterval(services.readerCloseTimeout)
            while library.openBookIDs.contains(book.id), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !library.openBookIDs.contains(book.id) else {
                return refuse(AudioEditorWording.readerStillOpen(book: book.title), from: window, services: services)
            }
        }

        // The session; a history that can't be read is started over only
        // when the user says so.
        let session: AudioEditSession
        do {
            session = try await openSession(book, track: track, library: library, window: window, services: services)
        } catch is CancellationError {
            return .cancelled
        } catch {
            DiagnosticLog.event(.storage, "AUDIO_EDITOR: \(book.title) could not be opened for editing (\(Self.describe(error)))")
            return refuse(AudioEditorWording.openFailed(book: book.title, reason: error.localizedDescription), from: window, services: services, alert: true)
        }
        services.present(book, track, session)
        return .opened(track: track?.title)
    }

    // MARK: Helpers

    /// Opens `book`'s session on `track`, asking to start over when its
    /// history can't be read.
    /// - Throws: `CancellationError` when the user declines to start over,
    ///   or the session's own errors.
    private static func openSession(
        _ book: Book,
        track: AudioEditorTrack?,
        library: LibraryViewModel,
        window: NSWindow?,
        services: Services
    ) async throws -> AudioEditSession {
        do {
            return try await services.openSession(book.id, track?.path, library, false)
        } catch AudioEditError.historyUnusable {
            guard await services.confirmStartOver(book, window) else { throw CancellationError() }
            return try await services.openSession(book.id, track?.path, library, true)
        }
    }

    /// Says `sentence`, as an alert too when `alert`, and returns the
    /// refusal.
    private static func refuse(_ sentence: String, from window: NSWindow?, services: Services, alert: Bool = false) -> Outcome {
        if alert {
            services.showFailure(sentence, window)
        } else {
            services.announce(sentence, window)
        }
        return .refused(sentence)
    }

    /// An error as the debug log names it: an edit error by its case alone,
    /// any other by its domain and code, never by words that could hold a
    /// file's name or path.
    static func describe(_ error: Error) -> String {
        if let edit = error as? AudioEditError {
            return String(String(describing: edit).prefix { $0 != "(" })
        }
        let failure = error as NSError
        return "\(failure.domain) \(failure.code)"
    }
}

// MARK: - The App's Services

extension AudioEditorLauncher.Services {
    /// The app's: alerts on the window asked from, the reader closing on
    /// its notification, the real edit session, and a window of the shared
    /// controller playing through AVFoundation.
    static var app: AudioEditorLauncher.Services {
        AudioEditorLauncher.Services(
            readTracks: { try AudioEditorTracks.of($0) },
            chooseTrack: AudioEditorAlerts.chooseTrack,
            confirmStartOver: AudioEditorAlerts.confirmStartOver,
            closeReader: { bookID in
                NotificationCenter.default.post(name: .closeReaderForAudioEditing, object: bookID)
            },
            openSession: { bookID, audioFile, library, startingOver in
                try await AudioEditSession.open(bookID: bookID, audioFile: audioFile, in: library, startingOver: startingOver)
            },
            present: { book, track, session in
                let controller = AudioEditorWindowController.shared
                let model = AudioEditorModel(
                    bookID: book.id,
                    bookTitle: book.title,
                    trackTitle: track?.title,
                    session: session,
                    player: AVAudioEditorPlayer(),
                    store: TextMouthRuntime.current.preferences,
                    recorder: .system(),
                    announce: { [weak controller] sentence in
                        VoiceOverAnnouncer.announce(sentence, from: controller?.window(for: book.id))
                    }
                )
                controller.show(model)
                Task { await model.loadPreview() }
            },
            announce: { sentence, window in
                VoiceOverAnnouncer.announce(sentence, from: window)
            },
            showFailure: AudioEditorAlerts.showFailure
        )
    }
}

// MARK: - The App's Questions

/// The questions the launcher asks in the app, as alerts: sheets on the
/// window asked from, or windows of their own when there is none. An alert
/// is a native dialog VoiceOver reads as it opens, its buttons and its
/// pop-up each labelled.
@MainActor
enum AudioEditorAlerts {
    /// Asks which of `tracks` of `book` to edit, in a pop-up listing them by
    /// their chapter names; nil when cancelled.
    static func chooseTrack(_ book: Book, _ tracks: [AudioEditorTrack], _ window: NSWindow?) async -> AudioEditorTrack? {
        let alert = NSAlert()
        alert.messageText = AudioEditorWording.chooseTrackQuestion(book: book.title)
        alert.informativeText = AudioEditorWording.chooseTrackExplanation
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for (index, track) in tracks.enumerated() {
            // Numbered, so two tracks of one name stay apart.
            popUp.addItem(withTitle: "\(index + 1). \(track.title)")
        }
        popUp.setAccessibilityLabel(AudioEditorWording.trackLabel)
        alert.accessoryView = popUp
        alert.addButton(withTitle: AudioEditorWording.editButton)
        // AppKit gives the button titled Cancel the Escape key.
        alert.addButton(withTitle: AudioEditorWording.cancelButton)
        alert.window.initialFirstResponder = popUp
        guard await run(alert, on: window) == .alertFirstButtonReturn else { return nil }
        let index = popUp.indexOfSelectedItem
        return tracks.indices.contains(index) ? tracks[index] : nil
    }

    /// Asks whether to start `book`'s edit history over.
    static func confirmStartOver(_ book: Book, _ window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AudioEditorWording.historyUnusableQuestion(book: book.title)
        alert.informativeText = AudioEditorWording.historyUnusableExplanation
        alert.addButton(withTitle: AudioEditorWording.startOverButton)
        alert.addButton(withTitle: AudioEditorWording.cancelButton)
        return await run(alert, on: window) == .alertFirstButtonReturn
    }

    /// Shows `message`, why the editor couldn't open, with OK.
    static func showFailure(_ message: String, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AudioEditorWording.openFailedTitle
        alert.informativeText = message
        alert.addButton(withTitle: AudioEditorWording.okButton)
        Task { _ = await run(alert, on: window) }
    }

    /// Shows `alert` as a sheet on `window`, or on its own without one, and
    /// returns the button pressed.
    static func run(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible, window.attachedSheet == nil else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
