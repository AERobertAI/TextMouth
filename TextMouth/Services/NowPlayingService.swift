import Foundation
import MediaPlayer
import CoreAudio

enum RemoteMediaCommandPolicy {
    enum Action: Equatable {
        case consume
        case play
        case pause
        case routeChangePause
        case toggle
    }

    static func play(isSuppressed: Bool) -> Action {
        isSuppressed ? .consume : .play
    }

    static func pause(isSuppressed: Bool, isPlaying: Bool) -> Action {
        isSuppressed && isPlaying ? .routeChangePause : .pause
    }

    static func toggle(isSuppressed: Bool, isPlaying: Bool) -> Action {
        guard isSuppressed else { return .toggle }
        return isPlaying ? .routeChangePause : .consume
    }

    static func isSuppressed(now: Date, until: Date) -> Bool {
        now < until
    }

    static func suppressDeadline(now: Date, delay: TimeInterval) -> Date {
        now.addingTimeInterval(max(0, delay))
    }

    static func isBluetoothTransport(_ transportType: UInt32) -> Bool {
        #if os(macOS)
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
        #else
        // iOS has no Core Audio transport types, and needs none: the audio
        // session reports a lost output as a route change, which
        // `PhoneAudioSession` hands to `perform(_:)`. Nothing counts as
        // Bluetooth here.
        false
        #endif
    }
}

/// Testable result of routing a system media command to a reader session.
/// MediaPlayer's result type is bridged only at the system integration edge.
enum RemoteCommandDispatchResult: Equatable {
    case success
    case commandFailed
    #if os(iOS)
    /// No reader is open and no book can be opened for the command: on the
    /// iPhone, MediaPlayer hears there is nothing to act on
    /// (`MPRemoteCommandHandlerStatusNoActionableNowPlayingItem`,
    /// `MPRemoteCommand.h:24-28`).
    case noActionableNowPlayingItem
    #endif
}

/// A command accepted from MediaPlayer for deferred delivery to the active
/// reader. Keeping this representation independent of MediaPlayer makes the
/// acknowledgement boundary directly testable without process-wide targets.
enum RemoteMediaCommandRequest: String, Equatable {
    case play
    case pause
    case togglePlayPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
}

/// What TextMouth shows the system as its Now Playing item: the book, and
/// whether it plays or is paused. macOS sends the AirPods and the media keys
/// to the app its Now Playing center names, and chooses Play or Pause for a
/// press by whether that app plays.
struct NowPlayingItem: Equatable, Sendable {
    /// The book's title.
    let title: String
    /// The book's author.
    let author: String
    /// Whether the book plays; false while it is paused.
    let isPlaying: Bool
    #if os(iOS)
    /// What the iPhone's lock screen shows beside the title and author: the
    /// speed, and an audiobook chapter's clock (`PhoneNowPlayingInfo`). Set as
    /// the item is shown (`showSystemNowPlaying(_:of:)`); the Mac's item has no
    /// such field, so `NowPlayingOwnershipTests` compares it as before.
    var phoneDetails = PhoneNowPlayingDetails.none
    #endif
}

/// What VoiceOver hears as Release Media Controls is chosen in a book's
/// window (`ReaderViewModel.releaseMediaControls()`).
enum MediaControlsWording {
    /// Said as the window's book, which held TextMouth's media controls,
    /// hands them back to the system, and so the AirPods and the media keys
    /// to other apps.
    static let released = "Media controls released"

    /// Said when Release Media Controls is chosen, by a key mapped to it, in
    /// a window whose book does not hold the media controls: one that never
    /// played, stopped, or released them already, or whose book another
    /// book has replaced in Now Playing. Nothing is released and nothing
    /// changes; the sentence begins as `released` does, so the two are told
    /// apart from their first words, on a braille display too.
    static let notHeld = "Media controls not released: this book does not hold them."
}

/// Reader-scoped facade over the one process-wide Now Playing coordinator.
/// Keeping the existing call-site API local to a reader prevents an inactive
/// window from clearing or replacing another window's media session.
@MainActor
final class NowPlayingSession {
    let ownerID: UUID
    private let diagnosticLabel: String?
    private let coordinator: NowPlayingService

    /// A session for the reader `ownerID` in `coordinator`: the app's shared
    /// one (`NowPlayingService.shared`) for a reader window, or a test's own.
    init(
        ownerID: UUID,
        diagnosticLabel: String? = nil,
        coordinator: NowPlayingService
    ) {
        self.ownerID = ownerID
        self.diagnosticLabel = diagnosticLabel
        self.coordinator = coordinator
    }

    func setup(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onAudioRouteInvalidated: @escaping () -> Void,
        onAudioRouteChangePause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        isCurrentlyPlaying: @escaping () -> Bool,
        bluetoothMonitoring: Bool = true,
        bluetoothDelay: TimeInterval = 2.0
    ) {
        coordinator.setup(
            ownerID: ownerID,
            diagnosticLabel: diagnosticLabel,
            onPlay: onPlay,
            onPause: onPause,
            onAudioRouteInvalidated: onAudioRouteInvalidated,
            onAudioRouteChangePause: onAudioRouteChangePause,
            onTogglePlayPause: onTogglePlayPause,
            onSkipForward: onSkipForward,
            onSkipBackward: onSkipBackward,
            isCurrentlyPlaying: isCurrentlyPlaying,
            bluetoothMonitoring: bluetoothMonitoring,
            bluetoothDelay: bluetoothDelay
        )
    }

    func activateRemoteCommandsIfNeeded() {
        coordinator.prepareForPlayback(ownerID: ownerID)
    }

    /// Marks this reader as the preferred media-command target without
    /// interrupting a different reader that is already playing.
    func focus() {
        coordinator.focus(ownerID: ownerID)
    }

    func releaseMediaControls() {
        coordinator.clearNowPlaying(ownerID: ownerID)
        #if os(iOS)
        // Released, the controls go to other apps, and so does the audio: the
        // session is let go with word to others that they may resume.
        coordinator.deactivatePhoneSessionIfIdle()
        #endif
    }

    #if os(iOS)
    /// Hands the coordinator what the iPhone's audio session asks of this
    /// reader (`PhoneAudioSession.attach(_:)`).
    func installPhoneHandlers(_ handlers: NowPlayingService.PhoneHandlers) {
        coordinator.installPhoneHandlers(handlers, ownerID: ownerID)
    }

    /// This reader's navigation unit may have changed: the lock screen's skip
    /// commands are set again from it (`PhoneRemoteCommandPolicy`).
    func phoneRemoteCommandsMayHaveChanged() {
        coordinator.phoneRemoteCommandsMayHaveChanged(ownerID: ownerID)
    }

    /// Lets the iPhone's audio session go when no book plays, as a book that
    /// ends with nothing to follow does; the item shown stays.
    func deactivatePhoneSessionIfIdle() {
        coordinator.deactivatePhoneSessionIfIdle()
    }
    #endif

    /// The reader that owns TextMouth's media controls right now: the
    /// coordinator's active owner (`NowPlayingService.activeOwnerID`), the
    /// playing reader or, while none plays, the most recently focused one.
    /// Nil while no reader has either. A wait that must tell whether
    /// another reader has taken the controls notes it and compares later.
    var activeOwnerID: UUID? {
        coordinator.activeOwnerID
    }

    /// Whether this reader is the active owner: the playing reader, or,
    /// while none plays, the most recently focused one
    /// (`NowPlayingService.activeOwnerID`), which the system's skip, track,
    /// and Pause commands reach.
    var isActiveOwner: Bool {
        coordinator.activeOwnerID == ownerID
    }

    /// Whether this reader holds TextMouth's media controls, which Release
    /// Media Controls hands back to other apps: it is the active owner and
    /// the system shows its book (`NowPlayingService.holdsMediaControls(ownerID:)`).
    var holdsMediaControls: Bool {
        coordinator.holdsMediaControls(ownerID: ownerID)
    }

    func updateNowPlayingInfo(title: String, author: String, isPlaying: Bool) {
        coordinator.updateNowPlayingInfo(
            ownerID: ownerID,
            title: title,
            author: author,
            isPlaying: isPlaying
        )
    }

    func clearNowPlaying() {
        coordinator.clearNowPlaying(ownerID: ownerID)
    }

    func updateGestureSettings(enabled: Bool, pattern: String, window: TimeInterval) {
        coordinator.updateGestureSettings(enabled: enabled, pattern: pattern, window: window)
    }

    func updateBluetoothSettings(enabled: Bool, delay: TimeInterval) {
        coordinator.updateBluetoothSettings(enabled: enabled, delay: delay)
    }

    func close() {
        coordinator.unregister(ownerID: ownerID)
    }
}

/// Integrates with macOS Now Playing center for media key and AirPods control.
/// Also monitors audio device changes to prevent phantom playback when
/// Bluetooth devices disconnect.
///
/// ## macOS Bluetooth-disconnect bug
/// When Bluetooth headphones disconnect, macOS's `rcd` daemon forwards the
/// event through `MediaRemote.framework` as `togglePlayPauseCommand` — not
/// a directed play/pause. The app's current state determines the direction:
/// paused → plays (the bug), playing → pauses (matches the user expectation).
/// This service intercepts that spurious toggle by opening a short suppress
/// window whenever the default audio output device changes, during which
/// incoming `play` and `togglePlayPause` commands from the system are gated.
///
/// ## Two listeners for two disconnect modes
/// 1. **Default-output listener** (`kAudioHardwarePropertyDefaultOutputDevice`)
///    catches the common case: AirPods placed in case, or switched to a
///    different host (phone/iPad) — macOS immediately switches the system
///    default output to built-in speakers, firing this notification.
/// 2. **Devices-list listener** (`kAudioHardwarePropertyDevices`) catches
///    the battery-drain case. When AirPods run out of battery, macOS often
///    does NOT change the system default output (the AirPods stay listed
///    as "default" even though they've gone silent), but it DOES remove
///    them from the active device list. Without this second listener, the
///    suppress window would never arm and `rcd`'s spurious toggle would
///    flip a paused book into playback through the speakers.
@MainActor
final class NowPlayingService {
    /// The app's one coordinator. In a process hosting the tests it takes no
    /// part in the system's media session (`installsSystemIntegrations(in:)`).
    static let shared = NowPlayingService(
        installsSystemIntegrations: installsSystemIntegrations(in: .current)
    )

    /// Whether a coordinator made for a process with `runtime` takes part in
    /// the system's media session: MediaPlayer's command targets, which the
    /// AirPods and the media keys reach, the system's Now Playing center,
    /// and CoreAudio's device listeners. The app does; a process hosting the
    /// tests never does.
    ///
    /// The test host is TextMouth.app itself, with the bundle identifier of
    /// the developer's own copy. Taking part, its readers playing silent test
    /// audio told the system that TextMouth was playing, so macOS sent the
    /// developer's AirPods presses to the test host, where they paused and
    /// skipped test readers, instead of to the copy the developer was
    /// listening to, which then heard nothing until it next told the system
    /// it played (board #958).
    nonisolated static func installsSystemIntegrations(in runtime: TextMouthRuntime) -> Bool {
        !runtime.isHostedTest
    }

    struct Handlers {
        let onPlay: () -> Void
        let onPause: () -> Void
        /// Invalidates any backend graph prepared for the former output route.
        let onAudioRouteInvalidated: () -> Void
        let onAudioRouteChangePause: () -> Void
        let onTogglePlayPause: () -> Void
        let onSkipForward: () -> Void
        let onSkipBackward: () -> Void
        let isCurrentlyPlaying: () -> Bool
    }

    private var handlersByOwner: [UUID: Handlers] = [:]
    private var ownerRegistrationOrder: [UUID] = []
    /// The item each reader last asked to show, kept for a reader that is
    /// not the active one until it becomes so (`publishCachedNowPlayingInfoForActiveOwner()`).
    private var nowPlayingInfoByOwner: [UUID: NowPlayingItem] = [:]
    /// The reader whose item the system's Now Playing center shows, or nil
    /// while it shows none of TextMouth's. Focus moves without changing
    /// what is shown, so this can differ from the active reader; only this
    /// reader takes the item down as it stops, releases media controls, or
    /// closes (`clearNowPlaying(ownerID:)`, `unregister(ownerID:)`).
    private var shownOwnerID: UUID?
    /// The reader TextMouth's media commands go to while no reader plays,
    /// and the one a Play from the AirPods starts: whichever came last of
    /// the reader whose window became key (`focus(ownerID:)`), the reader
    /// about to play (`prepareForPlayback(ownerID:)`), and the playing
    /// reader that paused, wherever its window is (`playingOwnerPaused(_:)`).
    private(set) var focusedOwnerID: UUID?
    private(set) var playingOwnerID: UUID?

    /// The active owner is the playing reader when one exists, otherwise the
    /// focused reader (`focusedOwnerID`): the most recently focused one, or
    /// the book that paused since, which the system then shows paused. Kept
    /// as a compatibility view for callers and tests that only need the
    /// current command target.
    ///
    /// A reader whose book has finished is still the focused owner, so it
    /// is the active one while nothing plays: it keeps its media session
    /// and shows its book paused at the end, never stopped
    /// (`ReaderViewModel.finishListening`), so that macOS goes on sending
    /// the AirPods and the media keys here, and the skip and track commands
    /// sent after the end reach it and play the book again from where the
    /// skip lands. A reader gives the controls up by releasing them
    /// (`clearNowPlaying(ownerID:)`) or closing (`unregister(ownerID:)`),
    /// and another reader that plays becomes the active one: a backward
    /// skip in the finished book's window then moves its cursor only
    /// (`ReaderViewModel.performSkip`).
    var activeOwnerID: UUID? {
        playingOwnerID ?? focusedOwnerID
    }

    /// Whether the reader `ownerID` holds TextMouth's media controls: it is
    /// the active owner, and the system's Now Playing center shows its
    /// item, playing or paused, so that macOS sends the AirPods and the
    /// media keys to TextMouth for its book. Only such a reader has the
    /// controls to hand back to other apps, since releasing them takes its
    /// item down (`clearNowPlaying(ownerID:)`). A reader whose item another
    /// reader's has replaced holds nothing, as a finished book holds nothing
    /// once another book plays; nor does a reader whose window is focused
    /// while the system shows another reader's paused book, nor one that
    /// never played, stopped, or released them.
    func holdsMediaControls(ownerID: UUID) -> Bool {
        activeOwnerID == ownerID && shownOwnerID == ownerID
    }

    private var activeHandlers: Handlers? {
        activeOwnerID.flatMap { handlersByOwner[$0] }
    }
    /// Whether this coordinator takes part in the system's media session
    /// (see `installsSystemIntegrations(in:)`). Without it, it still routes
    /// the commands handed to `acceptRemoteCommand(_:)` among its readers.
    let installsSystemIntegrations: Bool
    /// Receives each routing diagnostic: by default the debug log, as a
    /// `MEDIA_ROUTE` playback trace line, since every focus change, command,
    /// and device change writes one. Tests pass a sink of their own.
    private let diagnosticSink: (String) -> Void
    private let nowProvider: () -> Date
    private let defaultOutputDeviceProvider: (() -> AudioDeviceID?)?
    private let audioDeviceIDsProvider: (() -> [AudioDeviceID])?
    private let bluetoothDeviceProvider: ((AudioDeviceID) -> Bool)?
    /// Runs an accepted remote command's action later, on the main actor.
    /// The action is @Sendable because the default scheduler hands it to the
    /// main dispatch queue; tests capture it to run when they choose.
    private let scheduleRemoteCommandAction: (@escaping @MainActor @Sendable () -> Void) -> Void
    /// Writes the system's Now Playing center: shows an item, or, given
    /// nil, clears the center and reports playback stopped. The center
    /// decides where macOS sends the AirPods and the media keys. MediaPlayer's
    /// own center with system integrations, nothing without them, unless a
    /// test passes a writer of its own to see what the system is told.
    private let writeSystemNowPlaying: (NowPlayingItem?) -> Void

    /// The block-based registration API returns the exact target token that
    /// must later be passed to `removeTarget(_:)`. Retaining those pairs avoids
    /// the broad `removeTarget(nil)` operation, which can disturb targets that
    /// TextMouth does not own while MediaPlayer is dispatching an event.
    private struct RemoteCommandRegistration {
        let command: MPRemoteCommand
        let target: Any
    }

    private var remoteCommandRegistrations: [RemoteCommandRegistration] = []

    #if os(iOS)
    /// What the iPhone's audio session asks of each reader, by owner
    /// (`installPhoneHandlers(_:ownerID:)`).
    private var phoneHandlersByOwner: [UUID: PhoneHandlers] = [:]
    /// The media commands last set on the system's command center, so that
    /// the same set is not written again.
    private var appliedPhoneRemoteCommands: PhoneRemoteCommandPolicy?
    /// What a Play does with no reader open: opens the book last open and plays
    /// it (`PhoneSession.togglePlayPauseFromAnywhere()`), set at launch by
    /// `PhoneAudioSession.install(session:)`. Nil answers
    /// `.noActionableNowPlayingItem`.
    var noOwnerPlayHandler: (@MainActor () -> Void)?
    #endif

    /// Detector for the experimental "restart sleep timer via media
    /// gesture" feature. Each command handler routes its event type
    /// here before invoking the user-facing callback; if the detector
    /// returns true, this command was the final piece of a matching
    /// pattern and we suppress the original action and post the
    /// restart-timer notification instead. The detector is configured
    /// (or disabled) via `updateGestureSettings` from SettingsViewModel.
    let gestureDetector = MediaGestureDetector()

    /// Timestamp until which incoming system play/toggle commands should be
    /// treated as spurious (Bluetooth-disconnect artefacts). `distantPast`
    /// means the window is inactive. Compared to `Date()` via `isSuppressed`.
    private var suppressUntil: Date = .distantPast

    /// Advances only for routing changes initiated outside a deferred remote
    /// command. Queued commands from one MediaPlayer burst therefore see the
    /// results of earlier commands, while a newer user focus/playback action
    /// invalidates the older work before it can steal control back.
    private var externalRoutingRevision: UInt = 0
    private var isPerformingRemoteCommand = false

    /// How long the suppress window stays open after an audio device change.
    /// rcd typically delivers its toggle within a few hundred milliseconds,
    /// so 2s is comfortably long enough to catch the spurious command while
    /// staying short enough that a deliberate media-key press a few seconds
    /// later still works. Configurable via Miscellaneous settings.
    private var suppressWindow: TimeInterval = 2.0

    /// Whether Bluetooth disconnect monitoring is active. When disabled,
    /// the device-change listener is not registered and no suppress
    /// windows are opened. Configurable via Miscellaneous settings.
    private var bluetoothMonitoringEnabled: Bool = true

    /// True while the device-change suppress window is active.
    private var isSuppressed: Bool {
        RemoteMediaCommandPolicy.isSuppressed(now: nowProvider(), until: suppressUntil)
    }

    /// Listener for default audio output device changes
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listener for system audio devices list changes (used to catch the
    /// AirPods-battery-drain case where the default output stays put but
    /// the device disappears from the list — see class doc comment).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private(set) var isListeningForDeviceChanges = false
    private(set) var remoteCommandsActive = false

    /// Whether the previous default output device was a Bluetooth device.
    /// Cached while the device is still queryable (at setup and at the end
    /// of every change notification), because by the time the listener
    /// fires for a disconnect, the outgoing device may already be gone and
    /// its transport type unreadable. Used to skip the suppress window
    /// when the user is simply switching between wired/built-in devices —
    /// rcd only sends its spurious toggle on Bluetooth transitions.
    private(set) var previousDeviceWasBluetooth: Bool = false

    /// AudioDeviceID of the previously-known default output device. Cached
    /// alongside `previousDeviceWasBluetooth` so the devices-list listener
    /// can detect when this specific device is removed from the system —
    /// the signal that an AirPods battery has drained out (or the device
    /// has otherwise been ripped out from under us). Zero means "no cached
    /// device yet" (e.g. service just started with no audio output present).
    private(set) var previousDeviceID: AudioDeviceID = 0

    /// - Parameter systemNowPlaying: Writes the system's Now Playing center
    ///   in place of MediaPlayer's own (`writeSystemNowPlaying`); nil writes
    ///   MediaPlayer's center with system integrations and nothing without.
    init(
        installsSystemIntegrations: Bool = true,
        diagnosticSink: @escaping (String) -> Void = { DiagnosticLog.trace(.playback, "MEDIA_ROUTE: \($0)") },
        now: @escaping () -> Date = Date.init,
        defaultOutputDevice: (() -> AudioDeviceID?)? = nil,
        audioDeviceIDs: (() -> [AudioDeviceID])? = nil,
        isBluetoothDevice: ((AudioDeviceID) -> Bool)? = nil,
        scheduleRemoteCommandAction: @escaping (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void = { action in
            DispatchQueue.main.async {
                action()
            }
        },
        systemNowPlaying: ((NowPlayingItem?) -> Void)? = nil
    ) {
        self.installsSystemIntegrations = installsSystemIntegrations
        self.diagnosticSink = diagnosticSink
        self.nowProvider = now
        self.defaultOutputDeviceProvider = defaultOutputDevice
        self.audioDeviceIDsProvider = audioDeviceIDs
        self.bluetoothDeviceProvider = isBluetoothDevice
        self.scheduleRemoteCommandAction = scheduleRemoteCommandAction
        if let systemNowPlaying {
            self.writeSystemNowPlaying = systemNowPlaying
        } else if installsSystemIntegrations {
            self.writeSystemNowPlaying = { Self.writeMediaPlayerNowPlaying($0) }
        } else {
            self.writeSystemNowPlaying = { _ in }
        }
    }

    func setup(
        ownerID: UUID,
        diagnosticLabel: String? = nil,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onAudioRouteInvalidated: @escaping () -> Void,
        onAudioRouteChangePause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        isCurrentlyPlaying: @escaping () -> Bool,
        bluetoothMonitoring: Bool = true,
        bluetoothDelay: TimeInterval = 2.0
    ) {
        // Replacing callbacks can change how a queued command behaves. A new
        // inactive reader does not affect current routing, but the first reader
        // establishes the initial focus and must invalidate older empty state.
        if handlersByOwner[ownerID] != nil || focusedOwnerID == nil {
            noteExternalRoutingChange()
        }
        handlersByOwner[ownerID] = Handlers(
            onPlay: onPlay,
            onPause: onPause,
            onAudioRouteInvalidated: onAudioRouteInvalidated,
            onAudioRouteChangePause: onAudioRouteChangePause,
            onTogglePlayPause: onTogglePlayPause,
            onSkipForward: onSkipForward,
            onSkipBackward: onSkipBackward,
            isCurrentlyPlaying: isCurrentlyPlaying
        )
        if !ownerRegistrationOrder.contains(ownerID) {
            ownerRegistrationOrder.append(ownerID)
        }
        // The first reader must be ready for an immediate AirPods Play even
        // before AppKit finishes reporting its key-window transition.
        if focusedOwnerID == nil {
            focusedOwnerID = ownerID
        }
        self.bluetoothMonitoringEnabled = bluetoothMonitoring
        self.suppressWindow = bluetoothDelay

        diagnostic(
            "setup owner=\(shortOwnerID(ownerID)) label=\(diagnosticLabel ?? "none") "
                + "monitoring=\(bluetoothMonitoring) "
                + "delay=\(formatted(bluetoothDelay)) integrations=\(installsSystemIntegrations)"
        )

        activateRemoteCommandsIfNeeded()
        if bluetoothMonitoringEnabled, installsSystemIntegrations {
            startDeviceChangeListener()
        }
    }

    /// Records AppKit focus without changing the reader that is currently
    /// playing. Media Pause and Toggle continue to control audible playback;
    /// a subsequent explicit Play targets the focused reader.
    func focus(ownerID: UUID) {
        guard handlersByOwner[ownerID] != nil else {
            diagnostic("owner focus ignored owner=\(shortOwnerID(ownerID)) reason=unregistered")
            return
        }
        if focusedOwnerID != ownerID {
            noteExternalRoutingChange()
            focusedOwnerID = ownerID
        }
        ownerRegistrationOrder.removeAll { $0 == ownerID }
        ownerRegistrationOrder.append(ownerID)
        diagnostic(
            "owner focused owner=\(shortOwnerID(ownerID)) "
                + "playing=\(shortOptionalOwnerID(playingOwnerID))"
        )
        activateRemoteCommandsIfNeeded()
    }

    /// Prepares an owner to start playback. This is the single exclusivity
    /// boundary for UI and remote starts: any other audible reader is paused
    /// before the requested reader begins.
    ///
    /// The requested reader takes the media focus before the other reader
    /// pauses, and that reader is no longer the playing one as it pauses,
    /// so that its report of the pause neither takes the focus back
    /// (`playingOwnerPaused(_:)`) nor shows its book paused in the system
    /// for the moment before the requested reader's book is shown playing.
    ///
    /// Any other reader that says it plays is paused too, though it is not
    /// the playing owner: a book a Where Am I? announcement holds paused,
    /// which plays again as the announcement ends, says it plays, and its
    /// pause ends the announcement and keeps the book paused. Only the
    /// playing owner was paused before, so such a book played on beside
    /// the one that started.
    func prepareForPlayback(ownerID: UUID) {
        guard let handlers = handlersByOwner[ownerID] else {
            diagnostic("playback preparation ignored owner=\(shortOwnerID(ownerID)) reason=unregistered")
            return
        }

        noteExternalRoutingChange()

        focusedOwnerID = ownerID
        let previousOwnerID = playingOwnerID
        if let previousOwnerID,
           previousOwnerID != ownerID,
           let previousHandlers = handlersByOwner[previousOwnerID] {
            diagnostic(
                "exclusive pause previous=\(shortOwnerID(previousOwnerID)) "
                    + "next=\(shortOwnerID(ownerID))"
            )
            playingOwnerID = nil
            previousHandlers.onPause()
        }
        // Every other reader that says it plays, as a book a Where Am I?
        // announcement holds paused does, is paused too; the playing owner,
        // paused above, is left out, so it is never paused twice. They are
        // listed before any is paused, so a handler that changes the owners
        // cannot change the list.
        let otherPlaying = handlersByOwner.filter { otherOwnerID, otherHandlers in
            otherOwnerID != ownerID && otherOwnerID != previousOwnerID && otherHandlers.isCurrentlyPlaying()
        }
        for (otherOwnerID, otherHandlers) in otherPlaying {
            diagnostic(
                "exclusive pause other=\(shortOwnerID(otherOwnerID)) "
                    + "next=\(shortOwnerID(ownerID))"
            )
            otherHandlers.onPause()
        }

        if handlers.isCurrentlyPlaying() {
            playingOwnerID = ownerID
        }
        diagnostic("owner prepared owner=\(shortOwnerID(ownerID))")
        activateRemoteCommandsIfNeeded()
    }

    /// Compatibility entry point for existing service-level route tests.
    /// Production reader sessions use the more explicit focus/preparation API.
    func activate(ownerID: UUID) {
        prepareForPlayback(ownerID: ownerID)
    }

    /// The reader `ownerID` closes: it takes no more commands, and the item
    /// it shows, if the system shows its item, goes with it, whether or not
    /// it is the active reader, so the system never goes on showing a book
    /// whose window is closed, nor sends the AirPods to TextMouth for it.
    /// The active reader's own item, if it has one, is then shown in its
    /// place. A reader whose item is not shown takes nothing down: a window
    /// that never played closes without telling the system that TextMouth
    /// stopped while another book waits paused.
    ///
    /// Before, only the active reader's item was taken down, so a book shown
    /// paused while another reader's window was focused stayed shown after
    /// its own window closed.
    func unregister(ownerID: UUID) {
        let wasActive = activeOwnerID == ownerID
        let wasShown = shownOwnerID == ownerID
        let affectedRouting = focusedOwnerID == ownerID || playingOwnerID == ownerID
        if affectedRouting {
            noteExternalRoutingChange()
        }
        handlersByOwner.removeValue(forKey: ownerID)
        ownerRegistrationOrder.removeAll { $0 == ownerID }
        nowPlayingInfoByOwner.removeValue(forKey: ownerID)
        if playingOwnerID == ownerID {
            playingOwnerID = nil
        }
        if focusedOwnerID == ownerID {
            focusedOwnerID = ownerRegistrationOrder.last
        }
        #if os(iOS)
        phoneHandlersByOwner.removeValue(forKey: ownerID)
        if handlersByOwner.isEmpty {
            // No book is open: no unit promises anything.
            applyPhoneRemoteCommands(.noBook)
        }
        #endif
        diagnostic(
            "owner unregistered owner=\(shortOwnerID(ownerID)) wasActive=\(wasActive) "
                + "wasShown=\(wasShown) fallback=\(shortOptionalOwnerID(activeOwnerID))"
        )
        // As in `clearNowPlaying(ownerID:)`, only this reader's own item is
        // taken down; the reader now active is shown unless it is.
        if wasShown {
            clearSystemNowPlaying()
        }
        if wasActive || wasShown, shownOwnerID != activeOwnerID {
            publishCachedNowPlayingInfoForActiveOwner()
        }
    }

    /// Pauses every reader that is playing, each as its own Pause would,
    /// and returns how many it paused: what starting or resuming a recording
    /// asks (FR04), so the microphone does not pick up a book. A reader that
    /// is paused already is left alone, as pausing it again would play the
    /// pause sound for nothing. Nothing resumes them afterwards: that is the
    /// listener's to do.
    @discardableResult
    func pauseEveryPlayingReader() -> Int {
        // Taken before any handler runs, so a handler that closes a reader
        // cannot change the owners while they are gone through.
        let playing = handlersByOwner.filter { $0.value.isCurrentlyPlaying() }
        guard !playing.isEmpty else { return 0 }
        // A Play accepted before this and still queued must not restart a
        // book after it.
        noteExternalRoutingChange()
        for (ownerID, handlers) in playing {
            handlers.onPause()
            if !handlers.isCurrentlyPlaying() {
                playingOwnerPaused(ownerID)
            }
        }
        diagnostic("readers paused count=\(playing.count) trigger=recording")
        return playing.count
    }

    func activateRemoteCommandsIfNeeded() {
        guard installsSystemIntegrations else { return }
        guard !remoteCommandsActive else { return }
        setupRemoteCommands()
        remoteCommandsActive = true
    }

    /// Apply the latest gesture-detector settings. Called once at
    /// `setup` and again whenever the user toggles or reconfigures
    /// the experimental feature in Miscellaneous settings.
    func updateGestureSettings(enabled: Bool, pattern: String, window: TimeInterval) {
        gestureDetector.isEnabled = enabled
        gestureDetector.pattern = MediaGestureDetector.patternFromString(pattern)
        gestureDetector.window = window
        // Drop any in-flight partial sequence — half-built gestures
        // from the old config would be confusing if they completed
        // under the new one.
        gestureDetector.reset()
    }

    /// Pass an incoming media event through the gesture detector.
    /// Returns true exactly when the event completed a configured
    /// pattern; the caller then suppresses the original action and
    /// posts the restart-sleep-timer notification. False means the
    /// event should fire its usual callback.
    /// Lives here (not inline at each call site) so the suppression
    /// rule and the notification post stay in one place — easy to
    /// tweak later if we add more gesture-driven actions.
    private func consumeForGesture(
        _ event: MediaGestureDetector.EventType,
        receivedAt: Date
    ) -> Bool {
        guard gestureDetector.recordEvent(event, at: receivedAt) else { return false }
        // The reader whose book the media commands reach as the gesture ends
        // is the one whose timer it restarts (November 13, 2026: each reader
        // window has a timer of its own), noted now, before another reader
        // could play.
        let owner = activeOwnerID
        // Posting on main keeps SwiftUI views and other main-bound
        // observers safe regardless of which queue the command center
        // dispatched the original handler on.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .restartSleepTimer,
                object: nil,
                userInfo: Self.restartGestureUserInfo(owner: owner)
            )
        }
        return true
    }

    /// The key under which a Restart Sleep Timer the media gesture posts
    /// names the reader that owned TextMouth's media controls as the gesture
    /// ended (`activeOwnerID`): the reader whose window's timer it restarts.
    nonisolated static let restartGestureOwnerKey = "restartGestureOwner"

    /// What a Restart Sleep Timer the media gesture posts carries: the reader
    /// that owns the media controls, or nothing while no reader does.
    nonisolated static func restartGestureUserInfo(owner: UUID?) -> [String: Any]? {
        owner.map { [restartGestureOwnerKey: $0] }
    }

    /// Update Bluetooth monitoring settings at runtime (from Miscellaneous prefs).
    /// Starts or stops the device-change listener as needed.
    func updateBluetoothSettings(enabled: Bool, delay: TimeInterval) {
        let oldEnabled = bluetoothMonitoringEnabled
        let oldDelay = suppressWindow
        suppressWindow = delay

        diagnostic(
            "settings enabled=\(enabled) delay=\(formatted(delay)) "
                + "previousEnabled=\(oldEnabled) previousDelay=\(formatted(oldDelay))"
        )

        if enabled != bluetoothMonitoringEnabled {
            bluetoothMonitoringEnabled = enabled
            if enabled {
                if installsSystemIntegrations {
                    startDeviceChangeListener()
                }
            } else {
                stopDeviceChangeListener()
                // Clear any active suppress window when disabling
                suppressUntil = .distantPast
                diagnostic("suppression cleared reason=monitoring-disabled")
            }
        }
    }

    /// Registers each process-wide MediaPlayer command exactly once. The
    /// callbacks acknowledge the framework immediately and defer TextMouth's
    /// playback work, preventing reentrant Now Playing updates while
    /// MediaPlayer still owns its internal event-dispatch continuation.
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Defensive cleanup is selective: only tokens returned to TextMouth by
        // addTarget(handler:) are eligible for removal.
        removeOwnedRemoteCommandTargets()

        // Each deferred request ultimately funnels its event type through the
        // gesture detector. When the detector consumes a completed pattern,
        // the usual callback is skipped so a restart-timer gesture does not
        // also trigger an unwanted playback or navigation side effect.

        // Play command: only resume, never toggle. Suppressed after device changes
        // to prevent macOS from auto-starting playback when Bluetooth disconnects.
        commandCenter.playCommand.isEnabled = true
        registerRemoteCommand(commandCenter.playCommand, for: .play)

        // Pause command: only pause, never toggle. Always safe to forward —
        // even during the suppress window, pausing is the correct behaviour.
        commandCenter.pauseCommand.isEnabled = true
        registerRemoteCommand(commandCenter.pauseCommand, for: .pause)

        // Toggle command: in normal operation, reflects genuine user intent
        // (media keys, AirPods single-tap). During the suppress window, though,
        // it is almost certainly the spurious Bluetooth-disconnect toggle that
        // `rcd` forwards. We gate it so the bug cannot flip a paused book into
        // playback on the wrong output device.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        registerRemoteCommand(commandCenter.togglePlayPauseCommand, for: .togglePlayPause)

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        registerRemoteCommand(commandCenter.skipForwardCommand, for: .skipForward)

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        registerRemoteCommand(commandCenter.skipBackwardCommand, for: .skipBackward)

        // Next/previous track (AirPods double-tap, etc.) maps to skip forward/backward
        // since that's the most common user expectation for a book reader
        commandCenter.nextTrackCommand.isEnabled = true
        registerRemoteCommand(commandCenter.nextTrackCommand, for: .nextTrack)

        commandCenter.previousTrackCommand.isEnabled = true
        registerRemoteCommand(commandCenter.previousTrackCommand, for: .previousTrack)

        #if os(iOS)
        // The Mac's fixed 30 and 15 seconds above stay the Mac's: on the
        // iPhone the skip commands follow the book's unit, and every command
        // the app doesn't answer is disabled (`PhoneRemoteCommandPolicy`).
        // Targets are installed at launch, so this runs before any reader.
        appliedPhoneRemoteCommands = nil
        applyPhoneRemoteCommands(activeOwnerID.flatMap { phoneHandlersByOwner[$0]?.remoteCommandPolicy() } ?? .noBook)
        #endif
    }

    /// The handler MediaPlayer calls when the system sends `request`'s
    /// command, from the AirPods, the media keys, or Control Center.
    ///
    /// It is made here, outside the main actor, so that it is not isolated
    /// to it. MediaPlayer does not say which thread it calls a handler on,
    /// and in the Swift 6 language mode a handler made in main-actor code
    /// checks, as it begins, that it runs on the main thread, stopping the
    /// app anywhere else; the Swift 5 builds before a0bad26 checked nothing.
    /// The command itself goes to `receiveRemoteCommand(_:by:)`. The service
    /// is held weakly, as the registration outlives no one but the app.
    nonisolated private static func remoteCommandHandler(
        for request: RemoteMediaCommandRequest,
        of service: NowPlayingService
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak service] _ in
            Self.receiveRemoteCommand(request, by: service)
        }
    }

    /// Takes `request`, a command MediaPlayer delivered on whichever thread
    /// it chose, into `service` without ever stopping the app.
    ///
    /// On the main thread, where MediaPlayer has delivered every command so
    /// far, the command is accepted at once (`acceptRemoteCommand(_:)`), and
    /// MediaPlayer hears whether a reader owns media controls. On any other
    /// thread the command is accepted on the main queue, in the order it
    /// arrived, and MediaPlayer hears success, since main-actor state cannot
    /// be read there and waiting for the main thread could deadlock with it.
    ///
    /// - Returns: What MediaPlayer hears; failure when the service is gone.
    nonisolated static func receiveRemoteCommand(
        _ request: RemoteMediaCommandRequest,
        by service: NowPlayingService?
    ) -> MPRemoteCommandHandlerStatus {
        #if os(iOS)
        // Which commands the AirPods and the lock screen send, in what order
        // and on which thread, is known only from a first run.
        DiagnosticLog.event(.playback, "REMOTE_COMMAND: \(request.rawValue) mainThread=\(Thread.isMainThread)")
        #endif
        guard let service else { return .commandFailed }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                _ = service.acceptRemoteCommand(request)
            }
            return .success
        }
        return MainActor.assumeIsolated {
            service.mediaPlayerStatus(for: service.acceptRemoteCommand(request))
        }
    }

    /// Event-time inputs and the surrounding external routing revision are
    /// captured at receipt. Owner selection remains deferred so rapid command
    /// bursts resolve sequentially against state produced by earlier commands.
    private struct AcceptedRemoteMediaCommand {
        let request: RemoteMediaCommandRequest
        let routingRevision: UInt
        let wasSuppressed: Bool
        let suppressionDeadline: Date
        let receivedAt: Date
    }

    /// Accepts a framework command only when a reader owns media controls,
    /// snapshots its routing state, then schedules the real action after the
    /// MediaPlayer handler returns. Production uses the FIFO main dispatch
    /// queue; tests capture the action to verify the acknowledgement boundary.
    func acceptRemoteCommand(_ request: RemoteMediaCommandRequest) -> RemoteCommandDispatchResult {
        #if os(iOS)
        // A killed app the system wakes for a Play has no reader yet: the
        // Play opens the book last open (the engineer's review, F9).
        if activeOwnerID == nil { return acceptCommandWithNoReader(request) }
        #endif
        guard activeOwnerID != nil else { return .commandFailed }

        let receivedAt = nowProvider()
        let accepted = AcceptedRemoteMediaCommand(
            request: request,
            routingRevision: externalRoutingRevision,
            wasSuppressed: RemoteMediaCommandPolicy.isSuppressed(
                now: receivedAt,
                until: suppressUntil
            ),
            suppressionDeadline: suppressUntil,
            receivedAt: receivedAt
        )
        scheduleRemoteCommandAction { [weak self] in
            self?.performRemoteCommand(accepted)
        }
        return .success
    }

    /// Executes a previously acknowledged command on the main actor. Any
    /// playback or Now Playing mutations occur here, outside MediaPlayer's
    /// synchronous event callback and its internal continuation lifetime.
    private func performRemoteCommand(_ command: AcceptedRemoteMediaCommand) {
        guard command.routingRevision == externalRoutingRevision else {
            diagnostic(
                "command deferred request=\(command.request.rawValue) "
                    + "result=commandFailed reason=stale-routing "
                    + "acceptedRevision=\(command.routingRevision) "
                    + "currentRevision=\(externalRoutingRevision)"
            )
            return
        }

        // Public routing APIs called from command handlers must not advance the
        // external revision: later commands already accepted in the same burst
        // are expected to observe this command's resulting state.
        isPerformingRemoteCommand = true
        defer { isPerformingRemoteCommand = false }

        let result: RemoteCommandDispatchResult
        switch command.request {
        case .play:
            if let targetOwnerID = focusedOwnerID ?? playingOwnerID {
                result = dispatchPlayCommand(
                    targetOwnerID: targetOwnerID,
                    isSuppressed: command.wasSuppressed,
                    suppressionDeadline: command.suppressionDeadline,
                    receivedAt: command.receivedAt
                )
            } else {
                result = .commandFailed
            }
        case .pause:
            if let targetOwnerID = activeOwnerID {
                result = dispatchPauseCommand(
                    targetOwnerID: targetOwnerID,
                    isSuppressed: command.wasSuppressed,
                    receivedAt: command.receivedAt
                )
            } else {
                result = .commandFailed
            }
        case .togglePlayPause:
            if let targetOwnerID = playingOwnerID ?? focusedOwnerID {
                result = dispatchToggleCommand(
                    targetOwnerID: targetOwnerID,
                    isSuppressed: command.wasSuppressed,
                    suppressionDeadline: command.suppressionDeadline,
                    receivedAt: command.receivedAt
                )
            } else {
                result = .commandFailed
            }
        case .skipForward:
            result = dispatchSkipCommandToActiveOwner(
                gesture: .skipForward,
                direction: .forward,
                receivedAt: command.receivedAt
            )
        case .skipBackward:
            result = dispatchSkipCommandToActiveOwner(
                gesture: .skipBackward,
                direction: .backward,
                receivedAt: command.receivedAt
            )
        case .nextTrack:
            result = dispatchSkipCommandToActiveOwner(
                gesture: .nextTrack,
                direction: .forward,
                receivedAt: command.receivedAt
            )
        case .previousTrack:
            result = dispatchSkipCommandToActiveOwner(
                gesture: .previousTrack,
                direction: .backward,
                receivedAt: command.receivedAt
            )
        }
        diagnostic("command deferred request=\(command.request.rawValue) result=\(result)")
    }

    /// Resolves navigation ownership at execution so an earlier Play or Toggle
    /// in the same FIFO batch can transfer playback before the Skip runs. A
    /// finished book's reader is still the active owner (`activeOwnerID`),
    /// so the AirPods' Previous Track after the end reaches it, where the
    /// reader's own skip plays the book again (`ReaderViewModel.performSkip`).
    private func dispatchSkipCommandToActiveOwner(
        gesture: MediaGestureDetector.EventType,
        direction: SkipDirection,
        receivedAt: Date
    ) -> RemoteCommandDispatchResult {
        guard let targetOwnerID = activeOwnerID else { return .commandFailed }
        return dispatchSkipCommand(
            targetOwnerID: targetOwnerID,
            gesture: gesture,
            direction: direction,
            receivedAt: receivedAt
        )
    }

    /// Direction is separate from the gesture event because headset next and
    /// previous commands share TextMouth's forward/backward navigation actions
    /// while remaining distinct inputs for configurable gesture sequences.
    private enum SkipDirection {
        case forward
        case backward
    }

    /// Delivers skip and track commands through their original gesture gate,
    /// preserving both navigation semantics and sleep-timer restart gestures.
    private func dispatchSkipCommand(
        targetOwnerID: UUID,
        gesture: MediaGestureDetector.EventType,
        direction: SkipDirection,
        receivedAt: Date
    ) -> RemoteCommandDispatchResult {
        guard let handlers = handlersByOwner[targetOwnerID] else { return .commandFailed }
        if consumeForGesture(gesture, receivedAt: receivedAt) { return .success }
        switch direction {
        case .forward:
            handlers.onSkipForward()
        case .backward:
            handlers.onSkipBackward()
        }
        return .success
    }

    /// Routes a directed Play command to the focused reader, pausing any
    /// different audible reader first. The override makes suppression
    /// behavior deterministic in unit tests.
    func dispatchPlayCommand(isSuppressed suppressionOverride: Bool? = nil) -> RemoteCommandDispatchResult {
        let receivedAt = nowProvider()
        let suppressed = suppressionOverride ?? RemoteMediaCommandPolicy.isSuppressed(
            now: receivedAt,
            until: suppressUntil
        )
        guard let targetOwnerID = focusedOwnerID ?? playingOwnerID else {
            diagnostic("command play failed reason=no-owner")
            return .commandFailed
        }
        return dispatchPlayCommand(
            targetOwnerID: targetOwnerID,
            isSuppressed: suppressed,
            suppressionDeadline: suppressUntil,
            receivedAt: receivedAt
        )
    }

    /// Executes Play for the owner selected when the remote event arrived.
    private func dispatchPlayCommand(
        targetOwnerID: UUID,
        isSuppressed suppressed: Bool,
        suppressionDeadline: Date,
        receivedAt: Date
    ) -> RemoteCommandDispatchResult {
        let action = RemoteMediaCommandPolicy.play(isSuppressed: suppressed)
        logCommand(
            "play",
            suppressed: suppressed,
            action: action,
            targetOwnerID: targetOwnerID
        )
        if action == .consume {
            consumeSuppressionWindow(ifUnchangedFrom: suppressionDeadline)
            return .success
        }
        guard action == .play else { return .commandFailed }
        if consumeForGesture(.play, receivedAt: receivedAt) { return .success }

        guard let handlers = handlersByOwner[targetOwnerID] else {
            diagnostic("command play failed reason=no-owner")
            return .commandFailed
        }
        prepareForPlayback(ownerID: targetOwnerID)
        handlers.onPlay()
        if handlers.isCurrentlyPlaying() {
            playingOwnerID = targetOwnerID
        }
        return .success
    }

    /// Routes Pause to the audible reader when present, falling back to the
    /// focused reader so a newly opened paused book still accepts the command.
    func dispatchPauseCommand(isSuppressed suppressionOverride: Bool? = nil) -> RemoteCommandDispatchResult {
        let receivedAt = nowProvider()
        guard let targetOwnerID = activeOwnerID else {
            diagnostic("command pause failed reason=no-owner")
            return .commandFailed
        }
        let suppressed = suppressionOverride ?? RemoteMediaCommandPolicy.isSuppressed(
            now: receivedAt,
            until: suppressUntil
        )
        return dispatchPauseCommand(
            targetOwnerID: targetOwnerID,
            isSuppressed: suppressed,
            receivedAt: receivedAt
        )
    }

    /// Executes Pause for the owner selected when the remote event arrived.
    private func dispatchPauseCommand(
        targetOwnerID: UUID,
        isSuppressed suppressed: Bool,
        receivedAt: Date
    ) -> RemoteCommandDispatchResult {
        guard let handlers = handlersByOwner[targetOwnerID] else {
            diagnostic("command pause failed reason=no-owner")
            return .commandFailed
        }
        if consumeForGesture(.pause, receivedAt: receivedAt) { return .success }
        #if os(iOS)
        // Siri's Pause during an interruption: Apple's guide says to honor it,
        // so the interruption's end does not play the book on.
        PhoneAudioSession.shared.listenerPaused()
        #endif
        let action = RemoteMediaCommandPolicy.pause(
            isSuppressed: suppressed,
            isPlaying: handlers.isCurrentlyPlaying()
        )
        logCommand("pause", suppressed: suppressed, action: action)
        if action == .routeChangePause {
            handlers.onAudioRouteChangePause()
        } else {
            handlers.onPause()
        }
        if !handlers.isCurrentlyPlaying() {
            playingOwnerPaused(targetOwnerID)
        }
        return .success
    }

    /// Routes Toggle to audible playback first. With no playing reader, the
    /// focused reader receives the request and becomes the exclusive owner.
    func dispatchToggleCommand(isSuppressed suppressionOverride: Bool? = nil) -> RemoteCommandDispatchResult {
        let receivedAt = nowProvider()
        guard let targetOwnerID = playingOwnerID ?? focusedOwnerID else {
            diagnostic("command toggle failed reason=no-owner")
            return .commandFailed
        }
        let suppressed = suppressionOverride ?? RemoteMediaCommandPolicy.isSuppressed(
            now: receivedAt,
            until: suppressUntil
        )
        return dispatchToggleCommand(
            targetOwnerID: targetOwnerID,
            isSuppressed: suppressed,
            suppressionDeadline: suppressUntil,
            receivedAt: receivedAt
        )
    }

    /// Executes Toggle for the owner selected when the remote event arrived.
    private func dispatchToggleCommand(
        targetOwnerID: UUID,
        isSuppressed suppressed: Bool,
        suppressionDeadline: Date,
        receivedAt: Date
    ) -> RemoteCommandDispatchResult {
        guard let handlers = handlersByOwner[targetOwnerID] else {
            diagnostic("command toggle failed reason=no-owner")
            return .commandFailed
        }
        let action = RemoteMediaCommandPolicy.toggle(
            isSuppressed: suppressed,
            isPlaying: handlers.isCurrentlyPlaying()
        )
        logCommand("toggle", suppressed: suppressed, action: action)
        if suppressed {
            consumeSuppressionWindow(ifUnchangedFrom: suppressionDeadline)
            if action == .routeChangePause {
                handlers.onAudioRouteChangePause()
                playingOwnerPaused(targetOwnerID)
            }
            return .success
        }
        if consumeForGesture(.togglePlayPause, receivedAt: receivedAt) { return .success }
        if !handlers.isCurrentlyPlaying() {
            prepareForPlayback(ownerID: targetOwnerID)
        }
        handlers.onTogglePlayPause()
        if handlers.isCurrentlyPlaying() {
            playingOwnerID = targetOwnerID
        } else {
            playingOwnerPaused(targetOwnerID)
        }
        return .success
    }

    /// Consumes only the suppression window that existed when the command was
    /// accepted. A newer audio-route transition must retain its own window.
    private func consumeSuppressionWindow(ifUnchangedFrom acceptedDeadline: Date) {
        guard suppressUntil == acceptedDeadline else { return }
        suppressUntil = .distantPast
    }

    /// Keeps the item the reader `ownerID` shows, playing or paused, and
    /// shows it in the system's Now Playing center while that reader is the
    /// active one. A reader that plays becomes the playing reader; the
    /// playing reader that reports it no longer plays has paused, wherever
    /// its window is, and keeps the media focus (`playingOwnerPaused(_:)`),
    /// so its book is shown paused and the next Play reaches it.
    func updateNowPlayingInfo(ownerID: UUID, title: String, author: String, isPlaying: Bool) {
        guard handlersByOwner[ownerID] != nil else { return }
        let item = NowPlayingItem(title: title, author: author, isPlaying: isPlaying)
        nowPlayingInfoByOwner[ownerID] = item
        let previousPlayingOwnerID = playingOwnerID
        if isPlaying {
            playingOwnerID = ownerID
        } else {
            playingOwnerPaused(ownerID)
        }
        if playingOwnerID != previousPlayingOwnerID {
            noteExternalRoutingChange()
        }
        // An inactive reader can update its own paused state, but it must not
        // replace the visible Now Playing item or steal AirPods commands.
        guard activeOwnerID == ownerID else { return }
        showSystemNowPlaying(item, of: ownerID)
    }

    /// The playing reader `ownerID` has paused, wherever its window is: by
    /// its own Pause, a Pause or Play/Pause from the AirPods or a media key,
    /// its sleep timer running out, the AirPods leaving, a recording
    /// starting, or its book ending. It plays no more, and it keeps the
    /// media focus (`focusedOwnerID`), as if its window had become key, so
    /// that it stays the active reader: its book is shown paused, since
    /// only the active reader's item is shown, and the next Play from the
    /// AirPods, which macOS sends because the system shows TextMouth paused,
    /// reaches the book that paused. Any reader's window that becomes key
    /// afterwards takes the focus again (`focus(ownerID:)`).
    ///
    /// Before, the focus stayed with whichever reader's window was key, so
    /// a book that paused while another reader's window was focused was
    /// never shown paused: the system went on showing it playing, the next
    /// press was a Pause, which reached the focused reader, and the press
    /// after that played the focused reader's book.
    ///
    /// A reader that is not the playing one changes nothing: it paused
    /// nothing that played, or it was paused for another reader that is
    /// about to play (`prepareForPlayback(ownerID:)`).
    private func playingOwnerPaused(_ ownerID: UUID) {
        guard playingOwnerID == ownerID else { return }
        playingOwnerID = nil
        focusedOwnerID = ownerID
    }

    /// Shows `item`, the reader `ownerID`'s, in the system's Now Playing
    /// center, and remembers whose it is (`shownOwnerID`).
    private func showSystemNowPlaying(_ item: NowPlayingItem, of ownerID: UUID) {
        shownOwnerID = ownerID
        #if os(iOS)
        var item = item
        if let phone = phoneHandlersByOwner[ownerID] {
            item.phoneDetails = phone.nowPlayingDetails()
            applyPhoneRemoteCommands(phone.remoteCommandPolicy())
        }
        #endif
        writeSystemNowPlaying(item)
    }

    /// Shows `item` in MediaPlayer's Now Playing center, playing or paused,
    /// or, given nil, clears the center and reports playback stopped. It
    /// touches nothing of the coordinator's, so it needs no isolation; the
    /// coordinator calls it only from the main actor, as before.
    nonisolated private static func writeMediaPlayerNowPlaying(_ item: NowPlayingItem?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.author
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = item.isPlaying ? 1.0 : 0.0
        #if os(iOS)
        // The iPhone's words and numbers: the speed as the rate, the default
        // rate, and an audiobook chapter's clock (`PhoneNowPlayingInfo`).
        info = PhoneNowPlayingInfo(
            title: item.title, author: item.author, isPlaying: item.isPlaying, details: item.phoneDetails
        ).systemDictionary
        #endif

        center.nowPlayingInfo = info
        center.playbackState = item.isPlaying ? .playing : .paused
    }

    /// The reader `ownerID` stopped, or released the media controls: it has
    /// nothing left to show, so its item is forgotten, and, if the system
    /// shows its item, taken down, whether or not it is the active reader,
    /// as closing takes it down (`unregister(ownerID:)`); the active
    /// reader's own item, if it has one, is then shown in its place. The
    /// active reader that stops gives up the media session too, which a
    /// Play accepted before must not take back.
    ///
    /// Before, a reader that was not the active one took nothing down, so
    /// a book shown paused stayed shown after it stopped from behind
    /// another reader's window, as when its chapter could not be got from
    /// the cloud or its text was replaced, and the AirPods stayed with a
    /// book that had stopped.
    func clearNowPlaying(ownerID: UUID) {
        let wasActive = activeOwnerID == ownerID
        let wasShown = shownOwnerID == ownerID
        // A stopped reader has nothing to show, now or once it is the active
        // one again.
        nowPlayingInfoByOwner.removeValue(forKey: ownerID)
        guard wasActive || wasShown else { return }
        if wasActive {
            // Releasing media controls is an ownership decision even when
            // paused; an older queued Play must not immediately reclaim them.
            noteExternalRoutingChange()
        }
        if playingOwnerID == ownerID {
            playingOwnerID = nil
        }
        // Only the item this reader shows is taken down. A reader that shows
        // none, such as a window that never played closing while another
        // book waits paused, must not tell the system TextMouth stopped: the
        // paused book stays shown, so macOS keeps sending the AirPods here.
        // A reader that stops and then releases media controls clears once.
        guard wasShown else { return }
        clearSystemNowPlaying()
        publishCachedNowPlayingInfoForActiveOwner()
    }

    /// Republishes metadata after an owner closes so system controls and the
    /// menu bar immediately describe the surviving focused reader.
    private func publishCachedNowPlayingInfoForActiveOwner() {
        guard let ownerID = activeOwnerID,
              let cached = nowPlayingInfoByOwner[ownerID] else { return }
        showSystemNowPlaying(cached, of: ownerID)
    }

    private func mediaPlayerStatus(for result: RemoteCommandDispatchResult) -> MPRemoteCommandHandlerStatus {
        #if os(iOS)
        switch result {
        case .success: return .success
        case .commandFailed: return .commandFailed
        case .noActionableNowPlayingItem: return .noActionableNowPlayingItem
        }
        #else
        result == .success ? .success : .commandFailed
        #endif
    }

    private func clearSystemNowPlaying() {
        shownOwnerID = nil
        writeSystemNowPlaying(nil)
    }

    private func shortOptionalOwnerID(_ ownerID: UUID?) -> String {
        ownerID.map(shortOwnerID) ?? "none"
    }

    /// Gives `command` the handler that delivers `request`
    /// (`remoteCommandHandler(for:of:)`), and retains the opaque token
    /// returned by MediaPlayer so removal can target precisely the block
    /// TextMouth installed.
    private func registerRemoteCommand(_ command: MPRemoteCommand, for request: RemoteMediaCommandRequest) {
        let target = command.addTarget(handler: Self.remoteCommandHandler(for: request, of: self))
        remoteCommandRegistrations.append(
            RemoteCommandRegistration(command: command, target: target)
        )
    }

    /// Removes only TextMouth's block targets. Command availability belongs to
    /// the process-wide command object, so cleanup must not disable a command
    /// that another in-process integration could still own.
    private func removeOwnedRemoteCommandTargets() {
        for registration in remoteCommandRegistrations {
            registration.command.removeTarget(registration.target)
        }
        remoteCommandRegistrations.removeAll()
    }

    // MARK: - Audio Device Change Monitoring

    /// Listen for audio device changes via CoreAudio. Two complementary
    /// listeners run side-by-side; see the class doc comment for the
    /// reasoning behind each.
    ///
    /// 1. **Default output changed** — fires on the common manual disconnect:
    ///    AirPods placed in case, switched to phone/iPad, headphones unplugged.
    ///    The default switches to built-in speakers immediately.
    /// 2. **Devices list changed** — fires when audio devices are added or
    ///    removed system-wide. Catches the AirPods-battery-drain case where
    ///    the default output may not change (macOS keeps the dead device as
    ///    "default") but the device IS removed from the active list.
    private func startDeviceChangeListener() {
        guard installsSystemIntegrations else {
            diagnostic("listener start ignored reason=system-integrations-disabled")
            return
        }
        guard !isListeningForDeviceChanges else {
            diagnostic("listener start ignored reason=already-listening")
            return
        }

        // Capture the initial device's transport type and ID so the first
        // change notification has a meaningful baseline to compare against.
        refreshPreviousDeviceInfo()

        #if os(macOS)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultOutputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChange()
        }

        // Dispatching on .main ensures we share a serial queue with the
        // MPRemoteCommand handlers. With nil here, CoreAudio's SDK header
        // says the block is "directly invoked" on the framework's internal
        // notification thread — which would introduce an unsynchronised
        // race on suppressUntil against the command handlers. Sharing a
        // queue across both listeners also serialises them with each
        // other so they cannot interleave.
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultOutputBlock
        )
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        )

        // Each listener is registered independently so a failure on one
        // does not orphan the other. We mark the service as "listening"
        // if at least one succeeded — partial coverage is still better
        // than none.
        if defaultStatus == noErr {
            deviceChangeListenerBlock = defaultOutputBlock
        }
        if devicesStatus == noErr {
            deviceListListenerBlock = devicesBlock
        }
        if defaultStatus == noErr || devicesStatus == noErr {
            isListeningForDeviceChanges = true
        }
        diagnostic(
            "listeners registered defaultStatus=\(defaultStatus) devicesStatus=\(devicesStatus) "
                + "defaultActive=\(deviceChangeListenerBlock != nil) "
                + "devicesActive=\(deviceListListenerBlock != nil)"
        )
        #else
        // iOS watches no devices: `PhoneAudioSession` hears the audio session's
        // route changes instead, so there is nothing to register.
        diagnostic("listener start ignored reason=device-watching-not-built-on-ios")
        #endif
    }

    /// Handler for the default-output-device-changed notification.
    /// Common manual-disconnect path: AirPods → speakers, headphones → built-in,
    /// switch external speaker, etc.
    ///
    /// ## A noted omission: no debounce
    /// A flaky Bluetooth connection that drops for a fraction of a second and
    /// reconnects will still fire this handler, which arms the suppress window
    /// and pre-pauses if playing. There is no "wait N ms to see if the device
    /// comes back" grace period. Adding one would require careful design to
    /// avoid re-introducing the very bug commit aeac7c1 fixed (the spurious
    /// auto-resume on Bluetooth disconnect): if we delay our pause but `rcd`'s
    /// togglePlayPauseCommand fires inside the delay window, we'd miss arming
    /// the suppress window and a paused book would auto-play. Any future
    /// debounce needs to:
    ///   1. Arm the suppress window IMMEDIATELY (cheap, idempotent),
    ///   2. Delay only the pre-emptive `onPause`, and
    ///   3. Cancel that pending pause if the device returns within the window.
    ///   4. Keep the suppress window's duration (`suppressWindow`) at least
    ///      as long as the debounce delay — otherwise the suppress could
    ///      expire before the debounce decides whether to fire `onPause`,
    ///      and a late spurious toggle would slip through.
    /// The combination keeps rcd's toggle blocked while letting transient
    /// drops slide past without an audible pause, but the existing code is
    /// correct without it — so leaving as-is until field reports show the
    /// flicker is actually a problem.
    func handleDefaultOutputChange() {
        guard bluetoothMonitoringEnabled else {
            diagnostic("default-output event ignored reason=monitoring-disabled")
            return
        }
        // Capture whether the *outgoing* device was Bluetooth BEFORE
        // refreshing the cache to the new device. The spurious rcd
        // toggle only fires on Bluetooth disconnects, so this gate
        // eliminates false positives when the user simply switches
        // between wired/built-in devices.
        let wasBluetooth = previousDeviceWasBluetooth
        let outgoingID = previousDeviceID

        // Update the cache now so the next change notification has a
        // fresh baseline for the device we just transitioned to.
        refreshPreviousDeviceInfo()

        diagnostic(
            "default-output changed outgoingID=\(outgoingID) outgoingBluetooth=\(wasBluetooth) "
                + "currentID=\(previousDeviceID) currentBluetooth=\(previousDeviceWasBluetooth)"
        )

        // Even a transition *to* Bluetooth can leave a paused AVAudioEngine
        // graph attached to the former output. Notify every registered reader
        // so any later Play performs a cold start on the current route.
        // This is deliberately separate from the Bluetooth-only pause below:
        // switching between built-in/wired outputs should repair the backend
        // without changing the user's current play/pause state.
        invalidateRegisteredAudioBackends(trigger: "default-output-changed")

        guard wasBluetooth else {
            // Non-Bluetooth departure: rcd will not send a spurious
            // toggle. Leave playback untouched.
            diagnostic("default-output action=ignore reason=outgoing-not-bluetooth")
            return
        }

        armSuppressAndPauseIfPlaying(trigger: "default-output-changed")
    }

    /// Handler for the system-wide audio devices list change.
    /// Catches the AirPods-battery-drain case where the default output
    /// often stays put (macOS keeps the dead device as "default") but the
    /// device disappears from the device list.
    func handleDeviceListChange() {
        guard bluetoothMonitoringEnabled else {
            diagnostic("device-list event ignored reason=monitoring-disabled")
            return
        }
        let currentDevices = allAudioDeviceIDs()
        diagnostic(
            "device-list changed count=\(currentDevices.count) cachedID=\(previousDeviceID) "
                + "cachedBluetooth=\(previousDeviceWasBluetooth)"
        )
        // Battery-drain detection: previously had a Bluetooth default,
        // and that specific device is no longer in the active list.
        if previousDeviceWasBluetooth, previousDeviceID != 0 {
            if !currentDevices.contains(previousDeviceID) {
                // The Bluetooth device we'd been using has vanished from
                // the system. Arm the suppress window and pre-pause
                // exactly as the default-output handler would, then
                // clear cached state so the same vanished device doesn't
                // re-trigger detection on every subsequent unrelated
                // devices-list event (macOS may keep the dead device as
                // the "default" indefinitely).
                let removedID = previousDeviceID
                invalidateRegisteredAudioBackends(
                    trigger: "cached-bluetooth-device-removed"
                )
                armSuppressAndPauseIfPlaying(trigger: "cached-bluetooth-device-removed")
                previousDeviceWasBluetooth = false
                previousDeviceID = 0
                diagnostic("device-list action=clear-removed-cache removedID=\(removedID)")
                return
            }
        }

        // Not a Bluetooth-disconnect signal — but a devices-list change
        // is still a useful trigger to keep our cache fresh. If the
        // cache was zeroed by an earlier drain detection, this gives us
        // a chance to re-establish a baseline (e.g. when a new audio
        // device comes online, or when the user reconnects AirPods that
        // become the default). Without this, a SECOND drain after a
        // first drain would be missed when the default-output listener
        // never fires for the reconnect.
        refreshPreviousDeviceInfo()
        diagnostic(
            "device-list action=refresh-baseline currentID=\(previousDeviceID) "
                + "currentBluetooth=\(previousDeviceWasBluetooth)"
        )
    }

    /// Arm the suppress window for the configured duration, and call
    /// `onPause` if playback is currently running. Shared by the two
    /// disconnect handlers so the response to either trigger is identical.
    /// onPause is only fired when actually playing — calling it on a paused
    /// session would needlessly fire the pause sound effect and reset the
    /// reading-stats session.
    private func armSuppressAndPauseIfPlaying(trigger: String) {
        // Route state changed after any command accepted against the previous
        // device. Invalidate that work before arming suppression so an older
        // Play cannot start through newly selected speakers.
        noteExternalRoutingChange()
        let now = nowProvider()
        suppressUntil = RemoteMediaCommandPolicy.suppressDeadline(
            now: now, delay: suppressWindow
        )
        let isPlaying = activeHandlers?.isCurrentlyPlaying() == true
        let action = isPlaying ? "pause" : "remain-paused"
        diagnostic(
            "suppression armed trigger=\(trigger) delay=\(formatted(suppressWindow)) "
                + "deadline=\(suppressUntil.timeIntervalSince1970) playing=\(isPlaying) "
                + "owner=\(activeOwnerID.map(shortOwnerID) ?? "none") action=\(action)"
        )
        if isPlaying {
            activeHandlers?.onAudioRouteChangePause()
        }
    }

    /// Invalidate every open reader's retained audio graph without changing
    /// media focus or play/pause ownership. A route is process-wide: a paused,
    /// background reader can be resumed later and must not retain the device
    /// that disappeared while another window was active.
    private func invalidateRegisteredAudioBackends(trigger: String) {
        // Snapshot before invoking callbacks so a callback that closes a reader
        // cannot mutate the dictionary while it is being traversed.
        let handlers = Array(handlersByOwner.values)
        handlers.forEach { $0.onAudioRouteInvalidated() }
        diagnostic(
            "audio backends invalidated trigger=\(trigger) count=\(handlers.count) "
                + "activeOwner=\(activeOwnerID.map(shortOwnerID) ?? "none")"
        )
    }

    /// Read the current default output device ID from CoreAudio.
    /// Returns nil on query failure (e.g. no output device available).
    private func currentDefaultOutputDeviceID() -> AudioDeviceID? {
        if let defaultOutputDeviceProvider {
            return defaultOutputDeviceProvider()
        }
        #if os(macOS)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
        #else
        // No device query on iOS yet: report no default output device.
        return nil
        #endif
    }

    /// Whether the given device reports itself as Bluetooth (classic or LE).
    /// On query failure — typically because the device has already been
    /// removed from the system — returns true as a defensive fallback:
    /// arming the suppress window is the safer default than missing the
    /// actual Bluetooth disconnect case.
    private func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        if let bluetoothDeviceProvider {
            return bluetoothDeviceProvider(deviceID)
        }
        #if os(macOS)
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        )
        guard status == noErr else { return true }
        return RemoteMediaCommandPolicy.isBluetoothTransport(transportType)
        #else
        // No transport query on iOS yet: no device is known to be Bluetooth.
        return false
        #endif
    }

    /// Refresh the cached `previousDeviceWasBluetooth` flag and
    /// `previousDeviceID` from the current default output device. Called
    /// at setup and at the end of every change notification so the next
    /// notification has an up-to-date baseline that's still queryable.
    ///
    /// Includes a liveness check: if the system reports a default
    /// output that is no longer in the active devices list — a state
    /// macOS sometimes leaves us in after AirPods battery drain — we
    /// cache zeros instead. Caching a vanished device would cause every
    /// subsequent unrelated devices-list event to re-detect it as
    /// "gone" and spuriously re-arm the suppress window.
    func refreshPreviousDeviceInfo() {
        guard let deviceID = currentDefaultOutputDeviceID() else {
            // No default output — unusual; treat as non-Bluetooth so we
            // don't spuriously arm the suppress window on nothing.
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
            diagnostic("baseline refreshed defaultID=none result=no-device")
            return
        }

        // If allAudioDeviceIDs() returns empty (query failed), skip the
        // liveness check rather than treat it as "device gone" — losing
        // the cache on transient query failures is worse than caching a
        // device that's still likely valid.
        let currentDevices = allAudioDeviceIDs()
        let deviceIsLive = currentDevices.isEmpty || currentDevices.contains(deviceID)
        if deviceIsLive {
            previousDeviceID = deviceID
            previousDeviceWasBluetooth = isBluetoothDevice(deviceID)
            diagnostic(
                "baseline refreshed defaultID=\(deviceID) live=true "
                    + "bluetooth=\(previousDeviceWasBluetooth) deviceCount=\(currentDevices.count)"
            )
        } else {
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
            diagnostic(
                "baseline refreshed defaultID=\(deviceID) live=false bluetooth=false "
                    + "deviceCount=\(currentDevices.count)"
            )
        }
    }

    /// Read the full list of audio device IDs known to the system.
    /// Used by the devices-list listener to detect when the device we
    /// last cached as the default output has been removed (e.g. AirPods
    /// battery drained, taking them out of the active device list even
    /// though macOS may still report them as the "default" output).
    /// Returns an empty array on query failure.
    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        if let audioDeviceIDsProvider {
            return audioDeviceIDsProvider()
        }
        #if os(macOS)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        // Allocate based on the size reported by the size query, then
        // truncate the result to the byte count the data query actually
        // wrote back (CoreAudio updates `size` in place — if the device
        // list shrank between the two calls, trailing slots would
        // otherwise be zero-filled and read as bogus device IDs).
        let allocatedCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: allocatedCount)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        let actualCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        return Array(deviceIDs.prefix(actualCount))
        #else
        // No device list on iOS yet: report none, as a failed query does.
        return []
        #endif
    }

    private func stopDeviceChangeListener() {
        guard isListeningForDeviceChanges else {
            diagnostic("listener stop ignored reason=not-listening")
            return
        }

        #if os(macOS)
        // The dispatch queue must match the one used in
        // startDeviceChangeListener(), otherwise the unregistration fails.
        if let block = deviceChangeListenerBlock {
            var defaultOutputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                block
            )
            deviceChangeListenerBlock = nil
        }

        if let block = deviceListListenerBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                block
            )
            deviceListListenerBlock = nil
        }
        #endif
        // On iOS no listener is ever installed, so there is none to remove.

        isListeningForDeviceChanges = false
        diagnostic("listeners stopped")
    }

    var isRouteCommandSuppressed: Bool { isSuppressed }

    /// Marks a focus or playback-ownership change initiated by UI, lifecycle,
    /// or audio callbacks. Command-internal changes intentionally do not bump
    /// the revision so an already accepted FIFO burst remains ordered.
    private func noteExternalRoutingChange() {
        guard !isPerformingRemoteCommand else { return }
        externalRoutingRevision &+= 1
    }

    private func diagnostic(_ message: String) {
        diagnosticSink(message)
    }

    private func logCommand(
        _ command: String,
        suppressed: Bool,
        action: RemoteMediaCommandPolicy.Action,
        targetOwnerID: UUID? = nil
    ) {
        diagnostic(
            "command=\(command) suppressed=\(suppressed) "
                + "playing=\(activeHandlers?.isCurrentlyPlaying() == true) "
                + "target=\((targetOwnerID ?? activeOwnerID).map(shortOwnerID) ?? "none") "
                + "focused=\(focusedOwnerID.map(shortOwnerID) ?? "none") "
                + "playingOwner=\(playingOwnerID.map(shortOwnerID) ?? "none") action=\(action)"
        )
    }

    private func shortOwnerID(_ ownerID: UUID) -> String {
        String(ownerID.uuidString.prefix(8))
    }

    private func formatted(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval)
    }

}

#if os(iOS)
// MARK: - The iPhone's Audio Session

/// What the iPhone's audio session does through the coordinator: its events'
/// responses reach the readers here, since `armSuppressAndPauseIfPlaying`'s
/// neighbours, `invalidateRegisteredAudioBackends` and the owners, are private
/// to this file. `PhoneAudioSession` observes; `PhoneAudioEventPolicy` decides.
extension NowPlayingService {
    /// What the iPhone's audio session asks of one reader, which
    /// `PhoneAudioSession.attach(_:)` fills with the reader's own iOS methods.
    struct PhoneHandlers {
        /// Pauses the book for an interruption, saving its place, with no
        /// pause sound: a sound would ask for the audio the interruption took.
        let onInterruptionPause: @MainActor () -> Void
        /// What the lock screen shows beside the title and author.
        let nowPlayingDetails: @MainActor () -> PhoneNowPlayingDetails
        /// The media commands the reader's unit allows.
        let remoteCommandPolicy: @MainActor () -> PhoneRemoteCommandPolicy
        /// Readies a reader that isn't playing for the session's deactivation:
        /// its next Play starts cold, and its speech engine stops running (the
        /// engineer's review, F8).
        let prepareForDeactivation: @MainActor () -> Void
    }

    /// Keeps `handlers` for the reader `ownerID`, and sets the media commands
    /// from its unit when it is the active reader.
    func installPhoneHandlers(_ handlers: PhoneHandlers, ownerID: UUID) {
        guard handlersByOwner[ownerID] != nil else {
            diagnostic("phone handlers ignored owner=\(shortOwnerID(ownerID)) reason=unregistered")
            return
        }
        phoneHandlersByOwner[ownerID] = handlers
        phoneRemoteCommandsMayHaveChanged(ownerID: ownerID)
    }

    /// Sets the media commands again from the unit of the reader `ownerID`,
    /// when it is the active reader, whose book the commands reach.
    func phoneRemoteCommandsMayHaveChanged(ownerID: UUID) {
        guard activeOwnerID == ownerID, let handlers = phoneHandlersByOwner[ownerID] else { return }
        applyPhoneRemoteCommands(handlers.remoteCommandPolicy())
    }

    /// Whether any reader's book counts as playing, as each reader counts it
    /// for the system's commands: playing, about to, or held by Where Am I?.
    var anyReaderCountsAsPlaying: Bool {
        handlersByOwner.values.contains { $0.isCurrentlyPlaying() }
    }

    /// Carries out what `PhoneAudioEventPolicy` decided for an event.
    func perform(_ response: PhoneAudioResponse) {
        switch response {
        case .nothing, .restartFromPlace, .rebuildAudioObjects:
            // The speech engine restarts from its place itself
            // (`SpeechService`), and a reset reopens the book
            // (`PhoneAudioSession`): nothing of the owners changes here.
            return
        case .pauseAndSave:
            pausePlayingReadersForInterruption()
        case .resume:
            resumeReaderAfterInterruption()
        case .pauseForLostRoute:
            // The engineer's review, F25: no suppress window on the phone. It
            // gates Play and Toggle for macOS's spurious press, and would eat
            // the Play of AirPods put back in. A Play accepted for the old
            // output must not start the book on the speaker, though.
            noteExternalRoutingChange()
            if activeHandlers?.isCurrentlyPlaying() == true {
                // The Mac's own route pause, so its rewind on resume applies.
                activeHandlers?.onAudioRouteChangePause()
            }
            invalidateRegisteredAudioBackends(trigger: "phone-route-lost")
        case .noteLostRoute:
            noteExternalRoutingChange()
            invalidateRegisteredAudioBackends(trigger: "phone-route-lost-while-paused")
        case .invalidateBackend:
            invalidateRegisteredAudioBackends(trigger: "phone-route-changed")
        }
    }

    /// Readies every reader that isn't playing for the session's
    /// deactivation (`PhoneHandlers.prepareForDeactivation`).
    func prepareReadersForSessionDeactivation() {
        // Taken before any handler runs, so a handler that changes the owners
        // cannot change the list.
        let resting = handlersByOwner.filter { !$0.value.isCurrentlyPlaying() }.map(\.key)
        for ownerID in resting {
            phoneHandlersByOwner[ownerID]?.prepareForDeactivation()
        }
    }

    /// Lets the iPhone's audio session go when no reader plays, as Release
    /// Media Controls does. A process hosting the tests has no session.
    func deactivatePhoneSessionIfIdle() {
        guard installsSystemIntegrations else { return }
        PhoneAudioSession.shared.deactivateIfIdle()
    }

    /// Pauses every reader that plays for an interruption, each saving its
    /// place, and keeps the focus with the book that paused, so the
    /// interruption's end and the next Play reach it.
    private func pausePlayingReadersForInterruption() {
        // A Play accepted before the interruption and still queued must not
        // start a book into it.
        noteExternalRoutingChange()
        // Taken before any handler runs, as `pauseEveryPlayingReader()` takes
        // its list.
        let playing = handlersByOwner.filter { $0.value.isCurrentlyPlaying() }
        for (ownerID, handlers) in playing {
            if let phone = phoneHandlersByOwner[ownerID] {
                phone.onInterruptionPause()
            } else {
                handlers.onPause()
            }
            if !handlers.isCurrentlyPlaying() {
                playingOwnerPaused(ownerID)
            }
        }
        diagnostic("readers paused count=\(playing.count) trigger=interruption")
    }

    /// Plays on the book an interruption paused, once it ends with
    /// `shouldResume`, through the reader's own Play, so Rewind on Resume
    /// applies, as after a route change (the user's review, with F24).
    private func resumeReaderAfterInterruption() {
        guard let ownerID = focusedOwnerID ?? playingOwnerID, let handlers = handlersByOwner[ownerID] else {
            diagnostic("interruption resume ignored reason=no-owner")
            return
        }
        prepareForPlayback(ownerID: ownerID)
        handlers.onPlay()
        if handlers.isCurrentlyPlaying() {
            playingOwnerID = ownerID
        }
        diagnostic("interruption resume owner=\(shortOwnerID(ownerID)) playing=\(handlers.isCurrentlyPlaying())")
    }

    /// Accepts a command that arrived with no reader open: a Play, or the
    /// AirPods' press, opens the book last open and plays it, on the main
    /// queue's next turn, after MediaPlayer's handler has returned, as every
    /// command's work is (`scheduleRemoteCommandAction`). Anything else has
    /// nothing to act on.
    private func acceptCommandWithNoReader(_ request: RemoteMediaCommandRequest) -> RemoteCommandDispatchResult {
        let outcome = PhoneRemoteCommandPolicy.noReaderOutcome(
            for: request,
            canOpenLastBook: noOwnerPlayHandler != nil
        )
        diagnostic("command with no reader request=\(request.rawValue) outcome=\(outcome)")
        guard outcome == .opensLastBook else { return .noActionableNowPlayingItem }
        scheduleRemoteCommandAction { [weak self] in
            self?.noOwnerPlayHandler?()
        }
        return .success
    }

    /// Sets each of the system's media commands as `policy` says: enabled or
    /// not, and a skip command's interval. A set already written is not
    /// written again. A process hosting the tests touches no system command.
    func applyPhoneRemoteCommands(_ policy: PhoneRemoteCommandPolicy) {
        guard installsSystemIntegrations, appliedPhoneRemoteCommands != policy else { return }
        appliedPhoneRemoteCommands = policy
        let center = MPRemoteCommandCenter.shared()
        for command in PhoneRemoteCommandPolicy.Command.allCases {
            let remoteCommand = mediaPlayerCommand(command, in: center)
            remoteCommand.isEnabled = policy.isEnabled(command)
            let intervals = policy.preferredIntervals(for: command)
            // A disabled skip keeps whatever interval it had: nothing shows it.
            if let skipCommand = remoteCommand as? MPSkipIntervalCommand, !intervals.isEmpty {
                skipCommand.preferredIntervals = intervals.map { NSNumber(value: $0) }
            }
        }
        diagnostic(
            "phone commands skipForward=\(policy.skipForwardSeconds.map { "\(Int($0))s" } ?? "off") "
                + "skipBackward=\(policy.skipBackwardSeconds.map { "\(Int($0))s" } ?? "off")"
        )
    }

    /// The system's command for `command`: every one `MPRemoteCommandCenter.h`
    /// declares, so none is left as the system set it.
    private func mediaPlayerCommand(
        _ command: PhoneRemoteCommandPolicy.Command,
        in center: MPRemoteCommandCenter
    ) -> MPRemoteCommand {
        switch command {
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .togglePlayPause: center.togglePlayPauseCommand
        case .nextTrack: center.nextTrackCommand
        case .previousTrack: center.previousTrackCommand
        case .skipForward: center.skipForwardCommand
        case .skipBackward: center.skipBackwardCommand
        case .changePlaybackPosition: center.changePlaybackPositionCommand
        case .stop: center.stopCommand
        case .seekForward: center.seekForwardCommand
        case .seekBackward: center.seekBackwardCommand
        case .changePlaybackRate: center.changePlaybackRateCommand
        case .changeRepeatMode: center.changeRepeatModeCommand
        case .changeShuffleMode: center.changeShuffleModeCommand
        case .rating: center.ratingCommand
        case .like: center.likeCommand
        case .dislike: center.dislikeCommand
        case .bookmark: center.bookmarkCommand
        case .enableLanguageOption: center.enableLanguageOptionCommand
        case .disableLanguageOption: center.disableLanguageOptionCommand
        }
    }
}
#endif
