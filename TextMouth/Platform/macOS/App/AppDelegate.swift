import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hides context-specific menu bar items (Playback, Navigate, etc.) when
    /// the focused window doesn't support them, so VoiceOver doesn't encounter
    /// empty, non-interactive menus.
    let menuVisibilityManager = MenuVisibilityManager()

    /// The router that takes app-wide actions: the shared one, which the
    /// Library and reader windows register with, unless a test sets its own.
    var router = LibraryWindowRouter.shared

    /// Starts routing app-wide actions (TODO A05) before Finder can hand
    /// over a book at launch. SwiftUI opens the first Library window itself,
    /// so an action that arrives before that window registers waits for it
    /// instead of opening a second. Later, an action no open window can take
    /// opens a Library window through SwiftUI's main scene.
    func applicationWillFinishLaunching(_ notification: Notification) {
        router.openLibraryWindow = Self.openLibraryWindowThroughSwiftUI
        router.expectLibraryWindow()
        router.listen(to: .default)
    }

    /// Opens a new Library window the way AppKit asks SwiftUI for one when
    /// the app is reopened with no window: SwiftUI's own application
    /// delegate, which forwards to this one, answers
    /// `applicationOpenUntitledFile(_:)` by opening a window of the app's
    /// main scene, the Library. In the running app this opens exactly one
    /// Library window, which registers with the router at once, whether a
    /// Library window, only readers, or no window at all is open.
    ///
    /// This delegate must never implement `applicationOpenUntitledFile(_:)`
    /// itself: SwiftUI would hand the call here instead of opening a window.
    ///
    /// Other ways fall short (tried in the running app, TODO A05). No
    /// responder answers `newWindow:`, so sending it does nothing. A reader
    /// window's `openWindow` cannot name the Library scene, which has no
    /// identifier, and exists only while a reader is open. A reopen event
    /// opens a window only while no window at all is visible. File > New >
    /// New Window works, but only by finding the menu item by its title.
    ///
    /// - Returns: Whether SwiftUI opened a Library window.
    static func openLibraryWindowThroughSwiftUI() -> Bool {
        NSApp.delegate?.applicationOpenUntitledFile?(NSApp) ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The default data directory on a first launch, and the data
        // directory's folders, its Logs folder among them, so the line below
        // goes there. While the library isn't available it goes to this
        // Mac's Logs folder instead (TextMouthPaths.logDestination), so it is
        // written whatever state the data directory is in.
        try? TextMouthPaths.ensureDirectoryStructure()
        Self.logBuildIdentity(.current)
        // A quit to protect the Mac at the last launch is told once (B07).
        PlaybackMemoryGuard.tellOfAQuitToProtectTheMac()
        // The memory guard reads TextMouth's footprint from now on, whether
        // or not anything plays, so a runaway that begins while nothing
        // plays, or outlives the playback it began in, still reaches the
        // quit ceiling (REV17a).
        PlaybackMemoryGuard.shared.beginWatching()
        // A shut down or restart says so before it asks TextMouth to quit, so
        // that quit is the system's, not to be cancelled (`QuitReason`).
        QuitReason.startWatchingForPowerOff()
        // Any afconvert that an earlier TextMouth left running, orphaned by
        // a force-quit or a memory quit, is killed now (REV17a); only ones
        // writing TextMouth's own hidden conversion files are touched.
        OrphanedConversionSweep.sweepInBackground()
        // The same for a textutil that a force-quit or a crash orphaned
        // mid-conversion, and for the working folders (with their hidden
        // output) older than an hour that it left in the temporary directory.
        OrphanedConversionSweep.sweepTextutilInBackground()
        // And for an afinfo orphaned mid-read, and the hidden `.watched-output`
        // files older than an hour that it (or a killed app) left behind.
        OrphanedConversionSweep.sweepAfinfoInBackground()
        // This Mac's VoiceOver braille tables are read once, off the main
        // thread, so the Braille tab, Export, and Book Info find them ready.
        BrailleTableCatalog.loadInBackground()
        // The hidden copy a data-directory move staged beside its
        // destination is removed when the move ends; when the destination's
        // volume was unplugged or the app force-quit, it was not. The
        // folders this Mac's journal still lists are removed now, and no
        // other folder is touched.
        MigrationStagingLeftovers.sweepInBackground()
        // A speech export's kept chapters outlive only the session that
        // spoke them: the ones a quit or a crash left in this Mac's Caches
        // folder are removed now, unless an export has already begun.
        SpeechExportStore.sweepInBackground()

        // Disable automatic window tabbing (prevents "New Tab" menu proliferation)
        NSWindow.allowsAutomaticWindowTabbing = false

        Self.disableWindowRestoration()

        // Start hiding/showing context-specific menus based on active window type
        menuVisibilityManager.startObserving()
    }

    /// Records which build is running, as launch does: in the unified log,
    /// which Console shows even for an app opened from Finder, and as the
    /// debug log's `BUILD_IDENTITY` line, an event of the app category
    /// (`DiagnosticLog`), so it is written whether or not tracing is on.
    static func logBuildIdentity(_ identity: BuildIdentity) {
        NSLog("%@", identity.diagnosticLine)
        DiagnosticLog.event(.app, identity.diagnosticLine)
    }

    /// Disables macOS automatic window state restoration
    /// (`NSQuitAlwaysKeepsWindows`), so previous sessions don't spawn extra
    /// library or reader windows on launch. Only one library window should
    /// appear on startup; additional ones require Cmd+N.
    ///
    /// - Parameter preferences: Where the setting is saved: this process's
    ///   preferences. In the app they are the standard store AppKit reads;
    ///   under hosted tests they are the sandbox's, so the test host never
    ///   rewrites the developer's own copy of the setting.
    static func disableWindowRestoration(in preferences: UserDefaults = TextMouthRuntime.current.preferences) {
        preferences.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Allows SwiftUI to create its initial Library window, but suppresses the
    /// extra untitled Library scene AppKit otherwise requests while opening a
    /// document-style URL into an already-windowed application.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Self.shouldOpenUntitledLibrary(
            hasOpenLibraryWindow: router.hasRegisteredWindow
        )
    }

    /// Pure policy core keeps the AppKit delegate decision testable without
    /// driving an application-launch Apple event.
    static func shouldOpenUntitledLibrary(hasOpenLibraryWindow: Bool) -> Bool {
        !hasOpenLibraryWindow
    }

    // MARK: - Termination

    /// Holds a quit while the failure center reports unsaved changes: the
    /// app's, unless a test sets one of its own, whose flush and prompt show
    /// and write nothing.
    var terminationGuard = UnsavedChangesTerminationGuard()

    /// Asks AppKit to quit again, once a library move stopped for a quit,
    /// an editor or the Record window asked first, or an answered question
    /// has ended: always through `QuitRequest.ask()`, which asks from
    /// outside the main queue's drain. Tests replace it, so nothing quits.
    var requestTermination: @MainActor @Sendable () -> Void = { QuitRequest.ask() }

    /// The work a quit must not cut off, as the app has it: feed downloads,
    /// books read again in another encoding, and speech exports under way.
    /// Tests replace it with work of their own.
    var heldWork: @MainActor () -> [QuitHold.Work] = {
        [
            FeedQuitHold.work(FeedCenter.shared.downloads),
            TextRereads.shared.quitWork(),
            SpeechExportsUnderWay.shared.quitWork(),
        ]
    }

    /// Finishes that work for a quit the person asked for, saying what it
    /// is doing in a panel and through VoiceOver (`QuitNotice`), and then
    /// asks to quit again. Tests replace it with a finisher that shows and
    /// says nothing.
    var quitFinisher = QuitFinisher(
        tell: { QuitNotice.shared.show($0) },
        finished: { QuitNotice.shared.dismiss() }
    )

    /// The Record window's controller, which a quit asks about its take
    /// first (FR04): the app's, unless a test sets its own.
    var recordingWindows = RecordingWindowController.shared

    /// The audio editor's windows, whose unsaved edits a quit asks about
    /// first (FR04): the app's controller, unless a test sets its own.
    var audioEditors = AudioEditorWindowController.shared

    /// Whether TextMouth may quit now (TODO S09). The exact sequence:
    ///
    /// 0. While a library move copies (FR02), the move is stopped first, as
    ///    its Cancel stops it, so no partial copy is left behind, or, when
    ///    its copy is complete, let finish; this request is cancelled, and
    ///    TextMouth asks to quit again once the move has ended, which starts
    ///    over here. A move that has not started copying has written
    ///    nothing, and is no reason to wait. Then, while the Record window
    ///    holds a take (FR04), this request is cancelled and the window asks
    ///    whether to stop and save it, discard it, or cancel; TextMouth asks
    ///    to quit again only once the take is saved or discarded, so a save
    ///    finishes before TextMouth ends (`RecordingWindowController.holdQuit`).
    ///    Then each audio editor window with unsaved edits asks Save,
    ///    Discard, or Cancel, one at a time, and an editor still working or
    ///    recording says so instead; this request is cancelled, and once
    ///    every editor is answered for, TextMouth asks to quit again, which
    ///    goes on past the editors (`AudioEditorWindowController.holdQuit`,
    ///    FR04).
    /// 1. Here, everything pending is flushed as the termination path
    ///    flushes it, but nothing is ended: the library index and every
    ///    queued book record (`LibraryPersistenceService.flushPendingSave`),
    ///    then the statistics, whose open listening session is credited so
    ///    far and left open (`ReadingStatsService.flushPendingSaves`).
    ///    Settings and substitution rules are written as they change. Each
    ///    write's failure reaches the failure center before its flush ends.
    /// 2. With nothing unsaved, TextMouth quits: `applicationWillTerminate`
    ///    then shuts down as it always has, in its order: a transcription
    ///    under way is cancelled (FR05), menu observation
    ///    stops, the config watcher stops, pending saves are flushed again,
    ///    the listening session ends, the statistics are flushed, and their
    ///    timer stops.
    /// 3. With changes unsaved, this request is cancelled, once, and an
    ///    alert names what is unsaved, with Retry, Quit Anyway, and Cancel.
    ///    Retry runs every unsaved write again and asks to quit again,
    ///    which starts over at step 1. Quit Anyway asks to quit again, and
    ///    that second request quits at step 2, whatever is unsaved. Cancel
    ///    keeps TextMouth open.
    /// 4. A quit that goes ahead at step 2 while feed downloads wait or run,
    ///    while a book's text is read again in another encoding, or while a
    ///    speech export is under way, waits for that work (`QuitHold`). A
    ///    quit the person asks for is cancelled, TextMouth says in a panel
    ///    and through VoiceOver what it is finishing and that it will quit
    ///    afterwards (`QuitFinisher`, `QuitNotice`), and asks to quit again
    ///    once the work has ended, or has had its longest wait. Each
    ///    download keeps its place for the next launch, the one under way its
    ///    resume data (`FeedQuitHold`, FR03), after three seconds at most;
    ///    then each re-read finishes, its text and its record both written
    ///    (`TextRereads`, encodingchoice), after ten seconds at most; then
    ///    each speech export stops with its chapters kept
    ///    (`SpeechExportsUnderWay`); and then TextMouth quits. It is
    ///    cancelled rather than left pending because AppKit quits at once,
    ///    asking nothing, on a second Command-Q or the Dock's Quit while a
    ///    reply is pending. A request that comes while the work is being
    ///    finished is answered before step 0: it is cancelled too, and the
    ///    same words are said again, so it never cuts the work off. The
    ///    request that asks again when the work has ended skips step 4, once.
    ///    When the system ends the session, a cancel would stop the log out,
    ///    so that quit is answered later instead, with the same words
    ///    (`QuitHold.hold`); one that comes while the work is finished for the
    ///    person's quit is answered later too, and replied to as the work
    ///    ends (`QuitFinisher.answerSessionEnd`). A kind of work already
    ///    waited for is not waited for again by the request that follows; a
    ///    kind that began meanwhile is.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The memory guard quits to protect the Mac, everything saved,
        // asking nothing (B07).
        if PlaybackMemoryGuard.shared.isQuittingToProtectTheMac {
            return .terminateNow
        }
        // The system ending the session is never cancelled, which would stop
        // the log out; while work is finished for the person's quit, it is
        // answered later, with the same words, and replied to as the work ends.
        let endsTheSession = QuitReason.currentRequestEndsTheSession
        if endsTheSession,
           quitFinisher.answerSessionEnd(replyLater: { sender.reply(toApplicationShouldTerminate: $0) }) {
            return .terminateLater
        }
        if quitFinisher.answerRepeatedRequest() {
            return .terminateCancel
        }
        let waitedFor = quitFinisher.takeFinished()
        if holdsBeforeTheGuard() {
            // The request that follows a wait carries the Quit Anyway kept
            // for it; cancelled here, it is forgotten with the quit.
            if !waitedFor.isEmpty {
                terminationGuard.forgetQuitAnyway()
            }
            return .terminateCancel
        }
        // Step 4, for a quit that is sure to go ahead.
        return terminationGuard.reply { [self] in
            quitFinisher.reply(
                forQuitWith: heldWork(),
                waitedFor: waitedFor,
                endsTheSession: endsTheSession,
                replyLater: { sender.reply(toApplicationShouldTerminate: $0) }
            )
        }
    }

    /// Step 0, the questions asked before anything is flushed or waited for:
    /// a library move stopped, the Record window's take, and the audio
    /// editors' unsaved edits. Returns whether one holds this request, which
    /// is then to be cancelled; each asks to quit again once answered.
    private func holdsBeforeTheGuard() -> Bool {
        DataDirectoryMoveProgress.stopForQuit(then: requestTermination)
            || recordingWindows.holdQuit(then: requestTermination)
            || audioEditors.holdQuit(then: requestTermination)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // An Ogg conversion's afconvert ends with the app, at once, rather
        // than running on beside nothing (REV17a); the hidden file it was
        // writing is cleaned up by the next conversion of that book.
        WatchedProcess.terminateAll()
        // A transcription under way stops, asking nothing: it writes
        // nothing until its transcript is saved, so the book is left as it
        // was (FR05).
        TranscriptionJobCenter.shared.cancel()
        menuVisibilityManager.stopObserving()
        ConfigService.shared.shutdown()
        // Another Mac sharing the library no longer sees this one as open.
        LibrarySessionLease.shared.end()
        LibraryPersistenceService.flushPendingSave()
        let statsService = ReadingStatsService.shared
        statsService.endSession()
        statsService.flushPendingSaves()
        statsService.shutdown()
    }

    /// Takes the items opened from Finder, with Open With, a drop on the
    /// Dock icon, or a launch to open them, as one app-wide action: the
    /// Library window the router chooses imports them and opens each book
    /// (TODO A05). With every Library window closed, SwiftUI shows one again
    /// before this is called; on a cold launch, before any Library window
    /// has registered, the items wait for the first one.
    func application(_ application: NSApplication, open urls: [URL]) {
        router.route(.openFiles(urls))
    }
}
