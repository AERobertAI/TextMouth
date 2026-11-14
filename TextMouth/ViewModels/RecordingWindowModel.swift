#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine

/// What the Record window shows and does (FR04): the microphones and the
/// one chosen, the title and folder a recording is saved under, Record,
/// Pause or Resume, and Stop, the time and level once a second, once
/// stopped, the saved book, and the takes recordings left behind, as a
/// crash leaves one, to save as audiobooks or discard (`RecoveredTake`).
///
/// Stop asks nothing: it ends capture, saves the take as an audiobook
/// (`Saver`), and announces "Saved Recording as <title>". A take that ends
/// on its own, as a lost microphone ends one, is saved the same way, after
/// the reason is announced. A take that cannot be saved is kept until Save
/// Again or Discard Recording. VoiceOver hears each change of state once,
/// and the time and level only on demand, unless the user turns on the
/// level announcements; announcements before capture starts or resumes come
/// a moment ahead of it, so they are not recorded.
@MainActor
final class RecordingWindowModel: ObservableObject {
    /// What the window is doing, apart from the recorder's own state.
    enum Phase: Equatable {
        /// Ready to record, recording, or paused: the recorder's state says
        /// which.
        case recordingControls
        /// Saving a take as an audiobook.
        case saving
        /// A recording was saved as this book.
        case saved(Book)
        /// A take could not be saved; it is kept until saved or discarded.
        case saveFailed(RecordedTake, String)
    }

    /// Saves a take as an audiobook titled `title` in the library folder
    /// `folderPath`, under `policy`, and returns the book: the library's
    /// save in the app (`librarySaver`), a fake in tests.
    typealias Saver = @MainActor (
        _ take: RecordedTake,
        _ title: String,
        _ folderPath: String,
        _ policy: AudioOriginalPolicy
    ) async throws -> Book

    // MARK: Published State

    /// The recorder, whose state, time, and levels the window shows.
    let service: RecordingService
    /// The microphones connected, distinctly named.
    @Published private(set) var devices: [AudioInputDevice] = []
    /// The microphone a recording uses: the remembered one, or the default.
    @Published private(set) var selectedDeviceID = ""
    /// The title the recording is saved under.
    @Published var title: String
    /// The library folder the recording is saved in; empty for the top.
    @Published var folderPath = ""
    /// The library folders a recording can be saved in, the top first.
    @Published private(set) var folders: [String] = [""]
    /// What the window is doing.
    @Published private(set) var phase: Phase = .recordingControls
    /// The sentence under the controls saying what is happening.
    @Published private(set) var status: String = ""
    /// The time recorded, read once a second while recording.
    @Published private(set) var elapsed: TimeInterval = 0
    /// The levels, read once a second while recording or paused.
    @Published private(set) var levels: RecordingLevels?
    /// Whether VoiceOver announces the level every few seconds while
    /// recording: off until the user turns it on, and remembered from one
    /// window to the next (`RecordingLevelAnnouncements`).
    @Published var announcesLevel: Bool {
        didSet {
            secondsSinceLevelAnnouncement = 0
            RecordingLevelAnnouncements.enabled.write(announcesLevel, to: store)
        }
    }
    /// How many seconds apart the level is announced, remembered too.
    @Published var levelAnnouncementInterval: Int {
        didSet { RecordingLevelAnnouncements.interval.write(levelAnnouncementInterval, to: store) }
    }
    /// Whether the window offers to open the Microphone privacy settings:
    /// after a no that the user can change there.
    @Published private(set) var offersPrivacySettings = false
    /// The takes recordings left behind that this window does not hold,
    /// oldest first, listed under "Recovered recordings" (`RecoveredTake`).
    @Published private(set) var recoveredTakes: [RecoveredTake] = []

    /// The take left behind VoiceOver starts on, when the window opened on
    /// such takes, as launch opens it: the first of them, rather than the
    /// Microphone pop-up. Set once, as the window opens, so saving that take
    /// never moves VoiceOver to the next.
    let recoveredTakeFocusedAtOpen: URL?

    // MARK: Collaborators

    /// Lists the microphones and says when they change.
    private let catalog: RecordingInputCatalog
    /// Where the chosen microphone, the level announcements, and the
    /// policy are kept.
    private let store: UserDefaults
    /// Saves a take as an audiobook.
    private let saver: Saver
    /// Makes VoiceOver speak a sentence.
    private let announce: @MainActor (String) -> Void
    /// Opens a book's reader window.
    private let openBook: @MainActor (UUID) -> Void
    /// The library folders, read when the window opens and after a save.
    private let folderPaths: @MainActor () -> [String]
    /// The clock that names default titles.
    private let now: @MainActor () -> Date
    /// How long an announcement is given before capture starts or resumes.
    private let announcementLead: Duration
    /// Pauses every reader that is playing and says how many it paused:
    /// the app's readers in the app (`NowPlayingService`), stand-ins in
    /// tests.
    private let pauseReaders: @MainActor () -> Int

    /// Reads the time and level once a second while a take is under way.
    private var ticker: Task<Void, Never>?
    /// Seconds since the level was last announced.
    private var secondsSinceLevelAnnouncement = 0
    /// Whether Resume was pressed and capture resumes after its
    /// announcement, so a second press does nothing.
    private var isResuming = false
    /// Seconds in a row the take has held nothing but digital silence.
    private var silentSeconds = 0
    /// Whether this take's silence was already announced.
    private var warnedOfSilence = false
    /// The take being saved, while it is, so the takes left behind read
    /// meanwhile leave it out.
    private var takeBeingSaved: URL?
    /// The titles of takes left behind whose save failed, by file, so Save
    /// Again saves each under its own title rather than the Title field's.
    private var recoveredTitles: [URL: String] = [:]
    /// Whether the takes left behind were announced, which happens once.
    private var hasAnnouncedRecoveredTakes = false
    /// Those waiting for the work under way to end (`settle()`).
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many seconds of digital silence, in a row, make the window say
    /// that no sound is reaching it: once per take.
    static let silenceWarningSeconds = 5
    /// Follows the recorder's state.
    private var stateSubscription: AnyCancellable?

    /// A model for the Record window.
    /// - Parameters:
    ///   - service: The recorder.
    ///   - catalog: The microphones.
    ///   - store: Where the chosen microphone and the policy are kept.
    ///   - saver: Saves a take as an audiobook.
    ///   - folderPaths: The library's folders, by path.
    ///   - announce: Makes VoiceOver speak.
    ///   - openBook: Opens a book's reader window.
    ///   - now: The clock that names default titles.
    ///   - announcementLead: How long an announcement made before capture
    ///     starts or resumes is given to finish: a second in the app, none
    ///     in tests.
    ///   - pauseReaders: Pauses every reader that is playing, returning how
    ///     many it paused, as a recording starts or resumes.
    ///   - recovered: The takes left behind that launch found, which the
    ///     window opens on; it reads the folder again itself either way.
    init(
        service: RecordingService,
        catalog: RecordingInputCatalog,
        store: UserDefaults,
        saver: @escaping Saver,
        folderPaths: @escaping @MainActor () -> [String],
        announce: @escaping @MainActor (String) -> Void,
        openBook: @escaping @MainActor (UUID) -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        announcementLead: Duration = .seconds(1),
        pauseReaders: @escaping @MainActor () -> Int = { NowPlayingService.shared.pauseEveryPlayingReader() },
        recovered: [RecoveredTake] = []
    ) {
        self.service = service
        self.catalog = catalog
        self.store = store
        self.saver = saver
        self.folderPaths = folderPaths
        self.announce = announce
        self.openBook = openBook
        self.now = now
        self.announcementLead = announcementLead
        self.pauseReaders = pauseReaders
        announcesLevel = RecordingLevelAnnouncements.enabled.read(from: store)
        levelAnnouncementInterval = RecordingLevelAnnouncements.interval.read(from: store)
        recoveredTakes = recovered
        recoveredTakeFocusedAtOpen = recovered.first?.id
        title = RecordingWording.defaultTitle(at: now())
        folders = Self.folderChoices(folderPaths())
        refreshDevices(announcingChanges: false)
        catalog.onChange = { [weak self] in
            self?.refreshDevices(announcingChanges: true)
        }
        stateSubscription = service.$state
            .dropFirst()
            .sink { [weak self] state in
                // Published before the change: let it land, then respond.
                Task { @MainActor in self?.recorderChanged(to: state) }
            }
        // Takes a crash or a forced quit left behind are found as the
        // window opens, off the main thread.
        Task { [weak self] in await self?.refreshRecoveredTakes() }
    }

    // MARK: Microphones

    /// The microphone a recording uses, if any is connected.
    var selectedDevice: AudioInputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    /// The user chose the microphone `id` in the pop-up: it is used and
    /// remembered, apart from macOS's own input.
    func chooseDevice(_ id: String) {
        guard devices.contains(where: { $0.id == id }), id != selectedDeviceID else { return }
        selectedDeviceID = id
        RecordingInputChoice.preference.write(id, to: store)
        status = RecordingWording.ready(device: selectedDevice?.name)
    }

    /// Reads the microphones again, so the Microphone pop-up lists those
    /// connected now: the remembered one is chosen when it is connected,
    /// otherwise the default, which is never remembered in its place, so
    /// the remembered one is used again once it is back. When the window
    /// opens, VoiceOver hears if the remembered one is missing; later, if
    /// `announcingChanges`, as the catalog reports microphones connecting
    /// and disconnecting while nothing is recording, it hears that the one
    /// in use went away and what is used instead, that one connected is
    /// used now, or that others connected and are in the pop-up.
    private func refreshDevices(announcingChanges: Bool) {
        let previous = selectedDevice
        let listedBefore = Set(devices.map(\.id))
        devices = RecordingInputChoice.distinctlyNamed(catalog.devices())
        let resolution = RecordingInputChoice.resolve(
            remembered: RecordingInputChoice.preference.read(from: store),
            among: devices,
            systemDefault: catalog.systemDefaultDeviceID()
        )
        // While a take is under way the microphone in use stays, and nothing
        // is said that the microphone could record; the recorder reports a
        // lost one itself.
        guard !service.isRecording, service.state != .starting else { return }
        selectedDeviceID = resolution.device?.id ?? ""
        let fallback = resolution.device?.name
        if announcingChanges {
            let connected = devices.filter { !listedBefore.contains($0.id) }
            if let previous, !devices.contains(where: { $0.id == previous.id }) {
                tell(RecordingWording.microphoneDisconnected(previous.name, fallback: fallback))
            } else if let chosen = resolution.device, chosen.id != previous?.id {
                tell(RecordingWording.microphoneConnectedAndChosen(chosen.name))
            } else if !connected.isEmpty {
                tell(RecordingWording.microphonesConnected(connected.map(\.name)))
            } else if phase == .recordingControls, service.canStart {
                status = RecordingWording.ready(device: fallback)
            }
        } else if resolution.rememberedIsMissing, let fallback {
            tell(RecordingWording.rememberedMicrophoneMissing(fallback: fallback))
        } else {
            status = RecordingWording.ready(device: fallback)
        }
    }

    // MARK: Recording

    /// Whether Record can be pressed: a microphone is there, nothing is
    /// recording, and no take waits to be saved.
    var canRecord: Bool {
        selectedDevice != nil && service.canStart && !isSaving && !hasUnsavedTake
    }

    /// Whether Pause or Resume can be pressed.
    var canPause: Bool {
        service.isRecording
    }

    /// Whether Stop can be pressed.
    var canStop: Bool {
        service.isRecording
    }

    /// Whether a take is being saved.
    var isSaving: Bool {
        phase == .saving
    }

    /// Whether a take that could not be saved is kept, waiting.
    var hasUnsavedTake: Bool {
        if case .saveFailed = phase { return true }
        return false
    }

    /// Starts recording from the chosen microphone. Once permission is
    /// there, every reader that is playing is paused, so the microphone does
    /// not pick up a book, and VoiceOver announces both a moment before
    /// capture begins. Resuming the books is the listener's to do.
    func record() async {
        guard canRecord, let device = selectedDevice else { return }
        phase = .recordingControls
        offersPrivacySettings = false
        let lead = announcementLead
        await service.start(from: device) { [weak self] in
            guard let self else { return }
            let paused = self.pauseReaders()
            self.tell(RecordingWording.afterPausingReaders(paused, RecordingWording.recording(device: device.name)))
            try? await Task.sleep(for: lead)
        }
        if service.state == .recording {
            startTicking()
        }
    }

    /// Pauses a recording, or resumes a paused one: "Paused" is announced
    /// once capture stops, and "Resuming" a moment before it starts again,
    /// after pausing any reader started meanwhile, as a recording's start
    /// does. A second press during that moment does nothing more, and a Stop
    /// meanwhile wins: the recorder resumes only a take still paused.
    func togglePause() async {
        switch service.state {
        case .recording:
            await service.pause()
            tell(RecordingWording.paused)
        case .paused where !isResuming:
            isResuming = true
            defer { isResuming = false }
            tell(RecordingWording.afterPausingReaders(pauseReaders(), RecordingWording.resuming))
            try? await Task.sleep(for: announcementLead)
            // `recorderChanged(to:)` shows the recording status once it has
            // resumed.
            await service.resume()
        default:
            break
        }
    }

    /// Stops recording and saves the take, returning once it is saved or
    /// could not be; asks nothing. A take that ended with an error while
    /// stopping is announced and saved by `recorderChanged(to:)`.
    func stop() async {
        guard service.isRecording else { return }
        stopTicking()
        await service.stop()
        if case .finished(let take) = service.state {
            await save(take)
        }
    }

    /// Opens the saved recording in a reader window.
    func openInReader() {
        guard case .saved(let book) = phase else { return }
        openBook(book.id)
    }

    /// Opens System Settings at the Microphone privacy list.
    func openPrivacySettings() {
        guard let url = AudioInputPermission.privacySettingsURL else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        // Phase 1 opens this app's page in iOS Settings; until then there
        // is nothing to open.
        _ = url
        #endif
    }

    /// Tries again to save the take that could not be saved, under the
    /// title it was to have: its own, for a take left behind.
    func saveAgain() async {
        guard case .saveFailed(let take, _) = phase else { return }
        await save(take, recoveredTitle: recoveredTitles[take.url])
    }

    /// What Stop and Save, or Save, does as the Record window closes or
    /// TextMouth quits: lets a take that is starting begin and a save under
    /// way end, then stops and saves the take under way, or saves again the
    /// one that could not be saved. Returns once it is saved, or could not
    /// be, a take that ended with an error while stopping included.
    func stopAndSave() async {
        await settle()
        if service.isRecording {
            await stop()
        } else {
            await saveAgain()
        }
        await settle()
    }

    // MARK: Waiting Out Work Under Way

    /// Whether a take is starting, is stopping or ended and waits for its
    /// save, or is being saved: work that closing and quitting wait out.
    var isSettling: Bool {
        service.state == .starting || isSaving || (!service.isRecording && service.takeInUse != nil)
    }

    /// Returns once no take is starting, ending, or being saved: at once,
    /// or when the work under way is over, however it ended.
    func settle() async {
        while isSettling {
            await withCheckedContinuation { settleWaiters.append($0) }
        }
    }

    /// Wakes everyone waiting in `settle()`, each of whom looks again: as
    /// the recorder changes and as a save ends.
    private func resumeSettleWaiters() {
        let waiters = settleWaiters
        settleWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Deletes the take that could not be saved, or the one under way, and
    /// gets ready for another recording. A take that is starting is let
    /// begin first, and a save under way is let end: a take it saved is
    /// kept, and nothing is said to be discarded.
    func discard() async {
        await settle()
        guard service.isRecording || hasUnsavedTake else { return }
        if service.isRecording {
            await service.stop()
        }
        switch phase {
        case .saveFailed(let take, _):
            RecordingTakeFiles.remove(take.url)
            recoveredTitles[take.url] = nil
        default:
            break
        }
        service.discard()
        stopTicking()
        phase = .recordingControls
        tell(RecordingWording.discarded)
    }

    // MARK: Saving

    /// Responds to the recorder: a take that ended on its own, or failed to
    /// finish, is announced with its reason, then saved; a start that
    /// failed is announced, and the recorder made ready again. A finished
    /// take is saved by `stop()`, which waits for it.
    private func recorderChanged(to state: RecordingService.State) {
        // Whoever waits for work under way to end looks again.
        defer { resumeSettleWaiters() }
        // A state already left, as one Discard ended, needs nothing more.
        guard service.state == state else { return }
        switch state {
        case .failed(let failure, let take?):
            stopTicking()
            tell(failure.errorDescription ?? "")
            Task { await save(take) }
        case .failed(let failure, nil):
            stopTicking()
            if case .permission(let refusal) = failure {
                offersPrivacySettings = refusal.canBeChangedInSystemSettings
            }
            tell(failure.errorDescription ?? "")
            service.reset()
        case .paused:
            status = RecordingWording.paused
        case .recording:
            status = RecordingWording.recording(device: selectedDevice?.name ?? "")
        case .idle, .starting, .stopping, .finished:
            break
        }
    }

    /// Saves `take` as an audiobook in the folder chosen, under the global
    /// policy: titled `recoveredTitle` when it is a take left behind,
    /// otherwise with the Title field's title, which then starts over for
    /// the next recording. Announces "Saved Recording as <title>", or, after
    /// a second still saving, that it is saving. A failure keeps the take,
    /// for Save Again or Discard Recording.
    private func save(_ take: RecordedTake, recoveredTitle: String? = nil) async {
        phase = .saving
        status = RecordingWording.saving
        takeBeingSaved = take.url
        let bookTitle = recoveredTitle ?? TextImportPolicy.resolvedTitle(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let policy = AudioOriginalPolicy.global(in: store)
        let slowNotice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isSaving else { return }
            self.announce(RecordingWording.saving)
        }
        defer {
            slowNotice.cancel()
            takeBeingSaved = nil
            resumeSettleWaiters()
        }
        do {
            let book = try await saver(take, bookTitle, folderPath, policy)
            recoveredTitles[take.url] = nil
            phase = .saved(book)
            status = RecordingWording.saved(title: book.title)
            announce(RecordingWording.savedAnnouncement(title: book.title))
            service.reset()
            elapsed = 0
            levels = nil
            if recoveredTitle == nil {
                title = RecordingWording.defaultTitle(at: now())
            }
            folders = Self.folderChoices(folderPaths())
        } catch {
            if let recoveredTitle {
                recoveredTitles[take.url] = recoveredTitle
            }
            phase = .saveFailed(take, error.localizedDescription)
            tell(RecordingWording.saveFailed(reason: error.localizedDescription))
            // The take is the window's now; the recorder can be ready again
            // once it is saved or discarded.
            service.reset()
        }
    }

    // MARK: Takes Left Behind

    /// The take files this window holds: the recorder's, the one being
    /// saved, and the one that could not be saved. Any other take in the
    /// Recordings folder was left behind.
    var ownedTakes: Set<URL> {
        var owned = Set<URL>()
        if let url = service.takeInUse {
            owned.insert(url.standardizedFileURL)
        }
        if let takeBeingSaved {
            owned.insert(takeBeingSaved.standardizedFileURL)
        }
        if case .saveFailed(let take, _) = phase {
            owned.insert(take.url.standardizedFileURL)
        }
        return owned
    }

    /// Whether a take left behind can be saved or discarded now: nothing is
    /// recording, starting, or being saved, and no take of the window's
    /// waits to be saved again, as the window handles one take at a time.
    var canHandleRecoveredTakes: Bool {
        service.canStart && !isSaving && !hasUnsavedTake
    }

    /// Reads again, off the main thread, the takes recordings left in the
    /// Recordings folder, and lists those no window holds: neither this one
    /// (`ownedTakes`) nor any other recorder, as an audio editor recording a
    /// punch-in (`RecordingService.takesInUse`). What they hold is asked
    /// after the files are read, so a take that started or ended meanwhile
    /// is never taken for one left behind; while this window's take is
    /// starting, the list stays as it was. The first takes found are
    /// announced, once.
    func refreshRecoveredTakes() async {
        let found = await RecordingTakeFiles.readLeftovers(in: service.takesFolder)
        guard service.state != .starting else { return }
        let owned = ownedTakes.union(RecordingService.takesInUse)
        recoveredTakes = found.filter {
            !owned.contains($0.url.standardizedFileURL) && FileManager.default.fileExists(atPath: $0.url.path)
        }
        if !recoveredTakes.isEmpty, !hasAnnouncedRecoveredTakes {
            hasAnnouncedRecoveredTakes = true
            tell(RecordingWording.recoveredAnnouncement(count: recoveredTakes.count))
        }
    }

    /// Saves the take left behind, `recovered`, as an audiobook titled for
    /// when it was recorded, "Recording 2026-10-04 06:30", in the folder
    /// chosen: the save Stop makes. It leaves the list at once; one that
    /// cannot be saved stays the window's, for Save Again or Discard
    /// Recording. The Title field stays as it is, for the next recording.
    func saveRecovered(_ recovered: RecoveredTake) async {
        guard canHandleRecoveredTakes, recoveredTakes.contains(recovered), let take = recovered.take else { return }
        recoveredTakes.removeAll { $0.id == recovered.id }
        await save(take, recoveredTitle: RecordingWording.defaultTitle(at: take.startedAt))
    }

    /// Deletes the take left behind, `recovered`, with the encoding a save
    /// cut off may have left beside it, and says so.
    func discardRecovered(_ recovered: RecoveredTake) {
        guard canHandleRecoveredTakes, recoveredTakes.contains(recovered) else { return }
        RecordingTakeFiles.remove(recovered.url)
        RecordingTakeFiles.remove(RecordingTakeFiles.encodingURL(for: recovered.url))
        recoveredTakes.removeAll { $0.id == recovered.id }
        tell(RecordingWording.recoveredDiscarded(
            RecordingWording.recoveredTake(startedAt: recovered.startedAt, duration: recovered.duration)
        ))
    }

    // MARK: Once a Second

    /// Reads the time and level once a second while a take is under way,
    /// and announces the level when asked to.
    private func startTicking() {
        ticker?.cancel()
        secondsSinceLevelAnnouncement = 0
        silentSeconds = 0
        warnedOfSilence = false
        tick()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Stops reading the time and level.
    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// One second's reading: the time and level from the recorder, a
    /// warning once when the take has held only silence for
    /// `silenceWarningSeconds`, as a muted microphone gives, and the level
    /// announced when it is time.
    func tick() {
        elapsed = service.elapsed
        levels = service.isRecording ? service.levels : nil
        guard service.state == .recording else { return }
        // Only a measured silence counts; a level not read yet counts as
        // neither.
        if let levels {
            silentSeconds = RecordingWording.isDigitalSilence(peak: levels.peak) ? silentSeconds + 1 : 0
        }
        if silentSeconds >= Self.silenceWarningSeconds, !warnedOfSilence {
            warnedOfSilence = true
            tell(RecordingWording.noSound(device: selectedDevice?.name ?? RecordingWording.microphoneLabel.lowercased()))
        }
        guard announcesLevel else { return }
        secondsSinceLevelAnnouncement += 1
        if secondsSinceLevelAnnouncement >= levelAnnouncementInterval {
            secondsSinceLevelAnnouncement = 0
            announce(RecordingWording.levelAnnouncement(levels))
        }
    }

    // MARK: Closing

    /// What closing the window needs first.
    enum CloseNeed: Equatable {
        /// Nothing: it can close.
        case nothing
        /// A take is under way: ask to stop and save, or discard.
        case stopOrDiscard
        /// A take could not be saved: ask to save, or discard.
        case saveOrDiscard
    }

    /// What closing the window needs first, now.
    var closeNeed: CloseNeed {
        if service.isRecording || service.state == .starting { return .stopOrDiscard }
        if hasUnsavedTake { return .saveOrDiscard }
        return .nothing
    }

    /// Lets go of what the window holds as it closes: the ticker, and the
    /// recorder's subscription. A save under way finishes.
    func windowClosed() {
        stopTicking()
        catalog.onChange = nil
    }

    // MARK: Helpers

    /// Shows `sentence` as the status and announces it.
    private func tell(_ sentence: String) {
        status = sentence
        announce(sentence)
    }

    /// The folder choices: the top of the library, then each folder's path
    /// in order.
    private static func folderChoices(_ paths: [String]) -> [String] {
        [""] + paths.filter { !$0.isEmpty }.sortedStably { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: The App's

    /// The library's save: encodes the take as an M4A beside it, saves both
    /// through the library's import (`LibraryViewModel.saveRecording`), and
    /// removes the take and its encoding from the Recordings folder once
    /// the book is in the library. A failure keeps the take.
    static func librarySaver(_ library: LibraryViewModel) -> Saver {
        { take, title, folderPath, policy in
            let encoded = RecordingTakeFiles.encodingURL(for: take.url)
            defer { RecordingTakeFiles.remove(encoded) }
            try await RecordingEncoder.encode(take: take.url, to: encoded, title: title)
            let book = try await library.saveRecording(
                take,
                encodedAudio: encoded,
                title: title,
                toFolder: folderPath,
                policy: policy
            )
            RecordingTakeFiles.remove(take.url)
            return book
        }
    }

    /// The library's folders, by path.
    static func libraryFolderPaths(_ library: LibraryViewModel) -> [String] {
        library.library.folders.map { folder in
            folder.parentPath.isEmpty ? folder.name : folder.parentPath + "/" + folder.name
        }
    }
}
