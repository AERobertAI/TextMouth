import AVFAudio
import Combine
import UIKit

/// The iPhone's audio session: its category, its activation at Play, its
/// deactivation, and the system's interruptions, route changes, and media
/// resets, each handed to `PhoneAudioEventPolicy`, whose answer the Now
/// Playing coordinator carries out (the iPhone interface spec, "Listening with
/// the screen locked", as the engineer's review revised it).
///
/// Nothing here has run on an iPhone: every call is written from the iOS 26
/// SDK's headers and Apple's documentation, cited where it matters.
@MainActor
final class PhoneAudioSession {
    /// The app's one session, as `AVAudioSession.sharedInstance()` is.
    static let shared = PhoneAudioSession()

    /// What an earlier event means for a later one.
    private var policy = PhoneAudioEventPolicy()
    /// Whether the category was set: at launch, and again after a media reset.
    private var isConfigured = false
    /// The notification observers, kept for as long as the app runs. Apple
    /// (QA1749): after a media reset, "Don't re-register notifications".
    private var observers: [NSObjectProtocol] = []
    /// Follows the phone session's two readers, the one on screen and the one
    /// going on behind it, to attach each reader it opens.
    private var readerSubscriptions: Set<AnyCancellable> = []
    /// The readers attached, each held weakly with what follows its units.
    private var attachedReaders: [AttachedReader] = []

    /// Opens the book again, paused at its place, after a media reset: what the
    /// engineer's review (F26) makes the reset's whole rebuild, since a
    /// reader's `close()` and `init` let go of every audio object and make it
    /// afresh. `install(session:)` fills it from the phone's session; the
    /// session may fill it otherwise.
    var reopenBookAfterMediaServicesReset: (@MainActor () -> Void)?

    /// Carries out what `PhoneAudioEventPolicy` decided for an event: the app
    /// sets it at launch (`install(session:)`) to the Now Playing coordinator,
    /// which reaches the readers (`NowPlayingService.perform(_:)`). Nil, before
    /// launch, carries out nothing.
    var carryOut: (@MainActor (PhoneAudioResponse) -> Void)?

    /// Whether the system has taken the audio away and not given it back
    /// (`PhoneAudioEventPolicy.isInterrupted`): a speech synthesizer's cancel
    /// then is no refusal of the text (`SpeechService`).
    var isInterrupted: Bool { policy.isInterrupted }

    private init() {}

    // MARK: - Launch

    /// Everything the session needs at launch, in one call, which the app
    /// delegate makes as the app finishes launching, before any scene, since a
    /// launch in the background for a Play from the lock screen may connect
    /// none: the category, the observers, the remote commands' targets (the
    /// engineer's review, F9), what a Play with no reader does, the media
    /// reset's reopening, and a watch on the session's reader, so that each
    /// reader it opens is attached (`attach(_:)`).
    static func install(session: PhoneSession) {
        let audio = PhoneAudioSession.shared
        audio.configure()
        audio.startObserving()

        let nowPlaying = NowPlayingService.shared
        audio.carryOut = { nowPlaying.perform($0) }
        // A killed app the system wakes for a Play opens the book last open
        // and plays it, as the magic tap does with no book open.
        nowPlaying.noOwnerPlayHandler = { [weak session] in
            guard let session, session.togglePlayPauseFromAnywhere() else {
                DiagnosticLog.event(.playback, "REMOTE_PLAY_WITH_NO_BOOK: no book was open, and none could be opened")
                return
            }
        }
        // Installed now, not at the first reader, so that a Play can wake the
        // app: MediaPlayer sends a command only to an app with a target.
        nowPlaying.activateRemoteCommandsIfNeeded()

        audio.reopenBookAfterMediaServicesReset = { [weak session] in
            // The book going on behind is the one heard, when there is one.
            guard let session, let book = (session.listeningReader ?? session.reader)?.book else { return }
            session.closeReader()
            guard let reopened = session.open(book) else { return }
            // Shown paused at once, so the app stays the Now Playing app, as
            // the engineer's review (F1) asks of every pause.
            reopened.nowPlayingService.updateNowPlayingInfo(title: book.title, author: book.author, isPlaying: false)
        }

        // Each reader is attached once as the session makes it, whichever slot
        // it takes; the slots' publishers below only watch for readers leaving.
        session.readerMade.sink { reader in
            PhoneAudioSession.shared.attach(reader)
        }
        .store(in: &audio.readerSubscriptions)
        // Each publisher tells of a reader as it is about to be set, a new one
        // or nil, while the session still holds the one before it.
        session.$reader.sink { [weak session] reader in
            PhoneAudioSession.shared.readerChanges(to: reader, from: session?.reader, in: session)
        }
        .store(in: &audio.readerSubscriptions)
        session.$listeningReader.sink { [weak session] reader in
            PhoneAudioSession.shared.readerChanges(to: reader, from: session?.listeningReader, in: session)
        }
        .store(in: &audio.readerSubscriptions)
    }

    /// One of the session's readers changes from `old` to `new`: a reader that
    /// has closed by the end of this turn may
    /// let the session go (`deactivateAfterAReaderCloses(in:)`). One that only
    /// moved behind the book on screen, or came forward, keeps it: the
    /// engineer's review (F1) has only a close deactivate.
    private func readerChanges(to new: ReaderViewModel?, from old: ReaderViewModel?, in session: PhoneSession?) {
        guard let session, let old, old !== new else { return }
        DispatchQueue.main.async { [weak old] in
            guard old == nil || old?.hasClosed == true else { return }
            PhoneAudioSession.shared.deactivateAfterAReaderCloses(in: session)
        }
    }

    /// Gives `reader` what the session asks of it: whether its audio may
    /// start (`ReaderPhoneHooks.audioMayStart`), and the handlers the Now
    /// Playing coordinator calls for this session's events. Its navigation
    /// unit, which may change from its control, from Settings, or from the
    /// book's own choice, is followed for the lock screen's skip commands.
    func attach(_ reader: ReaderViewModel) {
        // A reader moves between the screen and behind it: it is attached once.
        attachedReaders.removeAll { $0.reader == nil || $0.reader?.hasClosed == true }
        guard !attachedReaders.contains(where: { $0.reader === reader }) else { return }
        // Composed with whatever the hook asked before, which another part of
        // the phone may have wrapped (the life cycle's background hold), so
        // neither replaces the other.
        let askedBefore = reader.phoneHooks.audioMayStart
        reader.phoneHooks.audioMayStart = {
            guard askedBefore() else { return false }
            return PhoneAudioSession.shared.audioMayStart()
        }
        reader.nowPlayingService.installPhoneHandlers(NowPlayingService.PhoneHandlers(
            onInterruptionPause: { [weak reader] in reader?.pauseForAudioInterruption() },
            nowPlayingDetails: { [weak reader] in reader?.phoneNowPlayingDetails ?? .none },
            remoteCommandPolicy: { [weak reader] in reader?.phoneRemoteCommandPolicy ?? .noBook },
            prepareForDeactivation: { [weak reader] in reader?.prepareForAudioSessionDeactivation() }
        ))
        // Each publisher tells as its value is about to change, so the commands
        // are read a turn later, on the main queue, when the change is in.
        let units = Publishers.Merge(
            reader.$book.map { _ in () },
            reader.settingsViewModel.objectWillChange.map { _ in () },
            // Settings keeps each kind's unit in the preferences, not in the
            // settings model, so a change there is heard here.
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification, object: TextMouthRuntime.current.preferences)
                .map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak reader] in
            reader?.nowPlayingService.phoneRemoteCommandsMayHaveChanged()
        }
        attachedReaders.append(AttachedReader(reader: reader, unitSubscription: units))
    }

    // MARK: - The Session

    /// Sets the category: `.playback`, which plays with the silent switch on
    /// and with the screen locked (with the `audio` background mode), in the
    /// `.spokenAudio` mode, which "wishes to be paused ... rather than ducked
    /// if another app (such as a navigation app) plays a spoken audio prompt"
    /// (`AVAudioSessionTypes.h:176-179`), with no options: each of
    /// `.mixWithOthers`, `.duckOthers`, and
    /// `.interruptSpokenAudioAndMixWithOthers` makes the session mixable, and a
    /// mixable session can't be the Now Playing app (WWDC22, session 110338).
    /// AirPods need no option: A2DP is "always implicitly true" in output-only
    /// categories (`AVAudioSessionTypes.h:513-515`).
    ///
    /// Safe at launch: setting a category activates nothing and interrupts no
    /// other app's audio.
    func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            isConfigured = true
            DiagnosticLog.event(.playback, "AUDIO_SESSION_CONFIGURED: category=playback mode=spokenAudio options=none")
        } catch {
            DiagnosticLog.event(.playback, "AUDIO_SESSION_CONFIGURE_FAILED: \(Self.describe(error))")
        }
    }

    /// Makes the session active, as Play needs before any audio starts, and
    /// logs how long that took, or why it failed, with the error's code.
    ///
    /// On the main actor in this first version, since `play()` is synchronous
    /// in shared code. Apple's header warns that "activating an audio session
    /// is a synchronous (blocking) operation" and recommends "that applications
    /// not activate their session from a thread where a long blocking
    /// operation will be problematic" (`AVAudioSession.h:239-241`). The log
    /// says whether it ever takes long enough to hear. **Unverified.**
    ///
    /// - Returns: Whether the session is active. It never throws at its caller.
    @discardableResult
    func activateForPlayback() -> Bool {
        if !isConfigured { configure() }
        let started = Date()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            policy.activationSucceeded()
            DiagnosticLog.event(.playback, "AUDIO_SESSION_ACTIVATED: \(Self.milliseconds(since: started)) ms")
            return true
        } catch {
            DiagnosticLog.event(
                .playback,
                "AUDIO_SESSION_ACTIVATION_FAILED: \(Self.milliseconds(since: started)) ms \(Self.describe(error))"
            )
            return false
        }
    }

    /// Whether a reader's audio may start: the session made active, or the
    /// listener told why not (the engineer's review, F7). Refused, as during a
    /// call ("!int", `AudioSessionTypes.h:50-52`), the book stays as it was and
    /// Play tries again.
    func audioMayStart() -> Bool {
        guard activateForPlayback() else {
            PhoneAnnouncer.important(PhoneAudioWording.cannotPlayNow)
            return false
        }
        return true
    }

    /// Lets the session go, with word to other apps that they may resume
    /// (`.notifyOthersOnDeactivation`, `AVAudioSessionTypes.h:627-629`), when no
    /// book plays: entering the background while paused, a sleep timer's
    /// expiry there, a book ending with nothing to follow, a reader closing in
    /// the foreground, and Release Media Controls. It stops nothing itself.
    /// Each reader not playing is readied first (F8): its next Play starts
    /// cold, and its speech engine stops running, since Apple's header says
    /// "the caller is required to first stop or pause all running I/Os"
    /// (`AVAudioSession.h:247-249`). The Now Playing item stays (F1).
    ///
    /// A failure is a log line: `!act`, I/O still running, still deactivates
    /// the session (`AVAudioSession.h:249-254`), and a speech synthesizer that
    /// activated the session itself is reported to refuse this (thread 759553).
    func deactivateIfIdle() {
        let nowPlaying = NowPlayingService.shared
        guard !nowPlaying.anyReaderCountsAsPlaying else {
            DiagnosticLog.trace(.playback, "audio session kept: a book plays")
            return
        }
        nowPlaying.prepareReadersForSessionDeactivation()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DiagnosticLog.event(.playback, "AUDIO_SESSION_DEACTIVATED: other apps were told they may resume")
        } catch {
            DiagnosticLog.event(.playback, "AUDIO_SESSION_DEACTIVATION_FAILED: \(Self.describe(error))")
        }
    }

    /// A reader closed or was replaced, a turn ago. The session goes only
    /// when the app is in front and no book plays or waits to: a book that
    /// finished hands its autoplay request to the next one's reader, which
    /// claims it as it loads, and a non-mixable session can be made active in
    /// the background "only when the app is the NowPlaying app"
    /// (`AudioSessionTypes.h:50-52`; the engineer's review, F1).
    private func deactivateAfterAReaderCloses(in session: PhoneSession) {
        guard UIApplication.shared.applicationState == .active else { return }
        let open = [session.reader, session.listeningReader].compactMap { $0 }
        let bookPlaysOrWaits = open.contains { reader in
            reader.isPlaybackUnderWay || reader.autoplayRequests.waitingRequest(for: reader.book.id) != nil
        }
        guard !bookPlaysOrWaits else { return }
        deactivateIfIdle()
    }

    /// A Pause from the listener while the session is interrupted: the
    /// interruption's end leaves the book paused.
    func listenerPaused() {
        policy.listenerPaused()
    }

    // MARK: - The System's Events

    /// Observes the interruptions, the route changes, and the media resets.
    ///
    /// Each observer is given the main queue (the engineer's review, F5): the
    /// route change is posted "on a secondary thread" (Apple's page for
    /// `routeChangeNotification`), and in the Swift 6 language mode main-actor
    /// code run there stops the app. The interruption and the reset are posted
    /// on the main thread already. Each notification's `userInfo` is read
    /// inside its block, and only then is the main actor assumed.
    /// `wasSuspended` isn't read: the header says it is "not present from iOS
    /// 16 onwards" (`AVAudioSessionTypes.h:595-597`).
    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            Self.observe(AVAudioSession.interruptionNotification, in: center, reading: Self.interruptionEvent(in:)),
            Self.observe(AVAudioSession.routeChangeNotification, in: center, reading: Self.routeChangeEvent(in:)),
            Self.observe(AVAudioSession.mediaServicesWereResetNotification, in: center) { _ in
                (.mediaServicesReset, "media services were reset")
            },
        ]
    }

    /// An observer of `name` that reads each notification into an event with
    /// `read`, and hands it to the session. Made here, outside the main actor,
    /// as `NowPlayingService` makes its command handlers
    /// (`NowPlayingService.swift:798-805`), so that the block belongs to no
    /// actor.
    nonisolated private static func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        reading read: @escaping @Sendable (Notification) -> (PhoneAudioEvent, String)?
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { notification in
            guard let parsed = read(notification) else { return }
            let (event, detail) = parsed
            // On the main queue, as `queue: .main` asks.
            MainActor.assumeIsolated {
                PhoneAudioSession.shared.handle(event, detail: detail)
            }
        }
    }

    /// Hands `event` to the policy, logs what it decided, and carries it out.
    private func handle(_ event: PhoneAudioEvent, detail: String) {
        if event == .mediaServicesReset {
            // QA1749: reset the category, options, and mode after a reset.
            isConfigured = false
            configure()
        }
        let nowPlaying = NowPlayingService.shared
        let response = policy.respond(to: event, bookCountsAsPlaying: nowPlaying.anyReaderCountsAsPlaying)
        DiagnosticLog.event(.playback, "AUDIO_SESSION_EVENT: \(detail) response=\(response)")
        if response == .rebuildAudioObjects {
            // Every voice the system had loaded went with its services.
            SpeechRenderCoordinator.shared.forgetWarmedVoices()
            reopenBookAfterMediaServicesReset?()
        }
        carryOut?(response)
    }

    /// An interruption's notification as an event, or nil when it says
    /// nothing usable. The reason is read only at a beginning, where the
    /// header puts it (`AVAudioSessionTypes.h:305-306`), and the options only
    /// at an end (`:302-303`).
    nonisolated private static func interruptionEvent(in notification: Notification) -> (PhoneAudioEvent, String)? {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return nil }
        switch type {
        case .began:
            let reasonValue = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = reasonValue.flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            return (
                .interruptionBegan(becauseRouteDisconnected: reason == .routeDisconnected),
                "interruption began reason=\(reasonValue.map(String.init) ?? "none")"
            )
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            return (.interruptionEnded(shouldResume: shouldResume), "interruption ended shouldResume=\(shouldResume)")
        @unknown default:
            return nil
        }
    }

    /// A route change's notification as an event, with the outputs before and
    /// after it for the log, or nil when it gives no reason.
    nonisolated private static func routeChangeEvent(in notification: Notification) -> (PhoneAudioEvent, String)? {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return nil }
        let previous = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map(outputs(of:)) ?? "unknown"
        let current = outputs(of: AVAudioSession.sharedInstance().currentRoute)
        return (
            .routeChanged(routeChangeReason(reason)),
            "route changed reason=\(reasonValue) from=\(previous) to=\(current)"
        )
    }

    /// The kinds of a route's outputs, such as `BluetoothA2DPOutput`, for the
    /// log; never a device's name.
    nonisolated private static func outputs(of route: AVAudioSessionRouteDescription) -> String {
        let kinds = route.outputs.map(\.portType.rawValue)
        return kinds.isEmpty ? "none" : kinds.joined(separator: "+")
    }

    /// The policy's name for `reason` (`AVAudioSessionTypes.h:375-404`).
    nonisolated private static func routeChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> PhoneAudioRouteChangeReason {
        switch reason {
        case .unknown: return .unknown
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        case .wakeFromSleep: return .wakeFromSleep
        case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
        case .routeConfigurationChange: return .routeConfigurationChange
        @unknown default: return .unknown
        }
    }

    // MARK: - The Log's Words

    /// An error's domain and code, the code as its four characters where it
    /// has them (`PhoneAudioErrorCode`).
    nonisolated private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(PhoneAudioErrorCode.description(of: error.code))"
    }

    /// Whole milliseconds since `start`.
    nonisolated private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}

/// A reader `PhoneAudioSession` has attached, held weakly, so that a closed
/// reader is let go, with what follows its units.
@MainActor
private final class AttachedReader {
    /// The reader, or nil once it has gone.
    weak var reader: ReaderViewModel?
    /// Follows the reader's units for the lock screen's commands.
    let unitSubscription: AnyCancellable

    init(reader: ReaderViewModel, unitSubscription: AnyCancellable) {
        self.reader = reader
        self.unitSubscription = unitSubscription
    }
}
