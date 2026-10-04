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
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Testable result of routing a system media command to a reader session.
/// MediaPlayer's result type is bridged only at the system integration edge.
enum RemoteCommandDispatchResult: Equatable {
    case success
    case commandFailed
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
    private(set) var focusedOwnerID: UUID?
    private(set) var playingOwnerID: UUID?

    /// The active owner is the playing reader when one exists, otherwise the
    /// most recently focused reader. Kept as a compatibility view for callers
    /// and tests that only need the current command target.
    var activeOwnerID: UUID? {
        playingOwnerID ?? focusedOwnerID
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
    func prepareForPlayback(ownerID: UUID) {
        guard let handlers = handlersByOwner[ownerID] else {
            diagnostic("playback preparation ignored owner=\(shortOwnerID(ownerID)) reason=unregistered")
            return
        }

        noteExternalRoutingChange()

        if let previousOwnerID = playingOwnerID,
           previousOwnerID != ownerID,
           let previousHandlers = handlersByOwner[previousOwnerID] {
            diagnostic(
                "exclusive pause previous=\(shortOwnerID(previousOwnerID)) "
                    + "next=\(shortOwnerID(ownerID))"
            )
            previousHandlers.onPause()
            playingOwnerID = nil
        }

        focusedOwnerID = ownerID
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

    func unregister(ownerID: UUID) {
        let wasActive = activeOwnerID == ownerID
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
        diagnostic(
            "owner unregistered owner=\(shortOwnerID(ownerID)) wasActive=\(wasActive) "
                + "fallback=\(shortOptionalOwnerID(activeOwnerID))"
        )
        if wasActive {
            // As in `clearNowPlaying(ownerID:)`, only this reader's own item
            // is taken down; the reader now active is shown unless it is.
            if shownOwnerID == ownerID {
                clearSystemNowPlaying()
            }
            if shownOwnerID != activeOwnerID {
                publishCachedNowPlayingInfoForActiveOwner()
            }
        }
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
        // Posting on main keeps SwiftUI views and other main-bound
        // observers safe regardless of which queue the command center
        // dispatched the original handler on.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .restartSleepTimer, object: nil)
        }
        return true
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
    /// in the same FIFO batch can transfer playback before the Skip runs.
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
        if playingOwnerID == targetOwnerID, !handlers.isCurrentlyPlaying() {
            playingOwnerID = nil
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
                if playingOwnerID == targetOwnerID {
                    playingOwnerID = nil
                }
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
        } else if playingOwnerID == targetOwnerID {
            playingOwnerID = nil
        }
        return .success
    }

    /// Consumes only the suppression window that existed when the command was
    /// accepted. A newer audio-route transition must retain its own window.
    private func consumeSuppressionWindow(ifUnchangedFrom acceptedDeadline: Date) {
        guard suppressUntil == acceptedDeadline else { return }
        suppressUntil = .distantPast
    }

    func updateNowPlayingInfo(ownerID: UUID, title: String, author: String, isPlaying: Bool) {
        guard handlersByOwner[ownerID] != nil else { return }
        let item = NowPlayingItem(title: title, author: author, isPlaying: isPlaying)
        nowPlayingInfoByOwner[ownerID] = item
        let previousPlayingOwnerID = playingOwnerID
        if isPlaying {
            playingOwnerID = ownerID
        } else if playingOwnerID == ownerID {
            playingOwnerID = nil
        }
        if playingOwnerID != previousPlayingOwnerID {
            noteExternalRoutingChange()
        }
        // An inactive reader can update its own paused state, but it must not
        // replace the visible Now Playing item or steal AirPods commands.
        guard activeOwnerID == ownerID else { return }
        showSystemNowPlaying(item, of: ownerID)
    }

    /// Shows `item`, the reader `ownerID`'s, in the system's Now Playing
    /// center, and remembers whose it is (`shownOwnerID`).
    private func showSystemNowPlaying(_ item: NowPlayingItem, of ownerID: UUID) {
        shownOwnerID = ownerID
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

        center.nowPlayingInfo = info
        center.playbackState = item.isPlaying ? .playing : .paused
    }

    func clearNowPlaying(ownerID: UUID) {
        guard activeOwnerID == ownerID else { return }
        // Releasing media controls is an ownership decision even when paused;
        // an older queued Play must not immediately reclaim them.
        noteExternalRoutingChange()
        if playingOwnerID == ownerID {
            playingOwnerID = nil
        }
        nowPlayingInfoByOwner.removeValue(forKey: ownerID)
        // Only the item this reader shows is taken down. A reader that shows
        // none, such as a window that never played closing while another
        // book waits paused, must not tell the system TextMouth stopped: the
        // paused book stays shown, so macOS keeps sending the AirPods here.
        // A reader that stops and then releases media controls clears once.
        guard shownOwnerID == ownerID else { return }
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
        result == .success ? .success : .commandFailed
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
    }

    private func stopDeviceChangeListener() {
        guard isListeningForDeviceChanges else {
            diagnostic("listener stop ignored reason=not-listening")
            return
        }

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
