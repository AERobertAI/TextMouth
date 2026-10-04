import AppKit
import Combine

/// What the Record window shows and does (FR04): the microphones and the
/// one chosen, the title and folder a recording is saved under, Record,
/// Pause or Resume, and Stop, the time and level once a second, and, once
/// stopped, the saved book.
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
    /// recording. Off until the user turns it on.
    @Published var announcesLevel = false {
        didSet { secondsSinceLevelAnnouncement = 0 }
    }
    /// How many seconds apart the level is announced.
    @Published var levelAnnouncementInterval = RecordingWording.defaultAnnounceInterval
    /// Whether the window offers to open the Microphone privacy settings:
    /// after a no that the user can change there.
    @Published private(set) var offersPrivacySettings = false

    // MARK: Collaborators

    /// Lists the microphones and says when they change.
    private let catalog: RecordingInputCatalog
    /// Where the chosen microphone and the policy are kept.
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
    init(
        service: RecordingService,
        catalog: RecordingInputCatalog,
        store: UserDefaults,
        saver: @escaping Saver,
        folderPaths: @escaping @MainActor () -> [String],
        announce: @escaping @MainActor (String) -> Void,
        openBook: @escaping @MainActor (UUID) -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        announcementLead: Duration = .seconds(1)
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

    /// Reads the microphones again: the remembered one is chosen when it is
    /// connected, otherwise the default, which is never remembered in its
    /// place, so the remembered one is used again once it is back. When the
    /// choice falls back, VoiceOver hears why: when the window opens, if the
    /// remembered one is missing, and later, if `announcingChanges`, when
    /// the microphone in use goes away while nothing is recording.
    private func refreshDevices(announcingChanges: Bool) {
        let previous = selectedDevice
        devices = RecordingInputChoice.distinctlyNamed(catalog.devices())
        let resolution = RecordingInputChoice.resolve(
            remembered: RecordingInputChoice.preference.read(from: store),
            among: devices,
            systemDefault: catalog.systemDefaultDeviceID()
        )
        // While a take is under way the microphone in use stays; the
        // recorder reports a lost one itself.
        guard !service.isRecording, service.state != .starting else { return }
        selectedDeviceID = resolution.device?.id ?? ""
        let fallback = resolution.device?.name
        if announcingChanges {
            if let previous, previous.id != selectedDeviceID {
                tell(RecordingWording.microphoneDisconnected(previous.name, fallback: fallback))
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
    /// there, VoiceOver announces it a moment before capture begins.
    func record() async {
        guard canRecord, let device = selectedDevice else { return }
        phase = .recordingControls
        offersPrivacySettings = false
        let lead = announcementLead
        await service.start(from: device) { [weak self] in
            self?.tell(RecordingWording.recording(device: device.name))
            try? await Task.sleep(for: lead)
        }
        if service.state == .recording {
            startTicking()
        }
    }

    /// Pauses a recording, or resumes a paused one: "Paused" is announced
    /// once capture stops, and "Resuming" a moment before it starts again.
    /// A second press during that moment does nothing more, and a Stop
    /// meanwhile wins: the recorder resumes only a take still paused.
    func togglePause() async {
        switch service.state {
        case .recording:
            await service.pause()
            tell(RecordingWording.paused)
        case .paused where !isResuming:
            isResuming = true
            defer { isResuming = false }
            tell(RecordingWording.resuming)
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
        NSWorkspace.shared.open(url)
    }

    /// Tries again to save the take that could not be saved.
    func saveAgain() async {
        guard case .saveFailed(let take, _) = phase else { return }
        await save(take)
    }

    /// Deletes the take that could not be saved, or the one under way, and
    /// gets ready for another recording.
    func discard() async {
        if service.isRecording {
            await service.stop()
        }
        switch phase {
        case .saveFailed(let take, _):
            RecordingTakeFiles.remove(take.url)
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

    /// Saves `take` as an audiobook with the title and folder chosen, under
    /// the global policy. Announces "Saved Recording as <title>", or, after
    /// a second still saving, that it is saving. A failure keeps the take.
    private func save(_ take: RecordedTake) async {
        phase = .saving
        status = RecordingWording.saving
        let bookTitle = TextImportPolicy.resolvedTitle(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let policy = AudioOriginalPolicy.global(in: store)
        let slowNotice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isSaving else { return }
            self.announce(RecordingWording.saving)
        }
        defer { slowNotice.cancel() }
        do {
            let book = try await saver(take, bookTitle, folderPath, policy)
            phase = .saved(book)
            status = RecordingWording.saved(title: book.title)
            announce(RecordingWording.savedAnnouncement(title: book.title))
            service.reset()
            elapsed = 0
            levels = nil
            title = RecordingWording.defaultTitle(at: now())
            folders = Self.folderChoices(folderPaths())
        } catch {
            phase = .saveFailed(take, error.localizedDescription)
            tell(RecordingWording.saveFailed(reason: error.localizedDescription))
            // The take is the window's now; the recorder can be ready again
            // once it is saved or discarded.
            service.reset()
        }
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
        [""] + paths.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: The App's

    /// The library's save: encodes the take as an M4A beside it, saves both
    /// through the library's import (`LibraryViewModel.saveRecording`), and
    /// removes the take and its encoding from the Recordings folder once
    /// the book is in the library. A failure keeps the take.
    static func librarySaver(_ library: LibraryViewModel) -> Saver {
        { take, title, folderPath, policy in
            let encoded = take.url.deletingPathExtension().appendingPathExtension("m4a")
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
