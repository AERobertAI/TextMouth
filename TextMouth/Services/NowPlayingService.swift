import Foundation
import MediaPlayer
import CoreAudio

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
class NowPlayingService {
    private var onPlay: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onAudioRouteChangePause: (() -> Void)?
    private var onTogglePlayPause: (() -> Void)?
    private var onSkipForward: (() -> Void)?
    private var onSkipBackward: (() -> Void)?
    /// Returns true when playback is currently running (not paused and not stopped).
    /// Used by the suppress-window logic to decide whether a spurious toggle
    /// should be converted into a pause or ignored entirely.
    private var isCurrentlyPlaying: (() -> Bool)?

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
    private var isSuppressed: Bool { Date() < suppressUntil }

    /// Listener for default audio output device changes
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listener for system audio devices list changes (used to catch the
    /// AirPods-battery-drain case where the default output stays put but
    /// the device disappears from the list — see class doc comment).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var isListeningForDeviceChanges = false
    private(set) var remoteCommandsActive = false

    /// Whether the previous default output device was a Bluetooth device.
    /// Cached while the device is still queryable (at setup and at the end
    /// of every change notification), because by the time the listener
    /// fires for a disconnect, the outgoing device may already be gone and
    /// its transport type unreadable. Used to skip the suppress window
    /// when the user is simply switching between wired/built-in devices —
    /// rcd only sends its spurious toggle on Bluetooth transitions.
    private var previousDeviceWasBluetooth: Bool = false

    /// AudioDeviceID of the previously-known default output device. Cached
    /// alongside `previousDeviceWasBluetooth` so the devices-list listener
    /// can detect when this specific device is removed from the system —
    /// the signal that an AirPods battery has drained out (or the device
    /// has otherwise been ripped out from under us). Zero means "no cached
    /// device yet" (e.g. service just started with no audio output present).
    private var previousDeviceID: AudioDeviceID = 0

    init() {}

    func setup(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onAudioRouteChangePause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        isCurrentlyPlaying: @escaping () -> Bool,
        bluetoothMonitoring: Bool = true,
        bluetoothDelay: TimeInterval = 2.0
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onAudioRouteChangePause = onAudioRouteChangePause
        self.onTogglePlayPause = onTogglePlayPause
        self.onSkipForward = onSkipForward
        self.onSkipBackward = onSkipBackward
        self.isCurrentlyPlaying = isCurrentlyPlaying
        self.bluetoothMonitoringEnabled = bluetoothMonitoring
        self.suppressWindow = bluetoothDelay

        activateRemoteCommandsIfNeeded()
        if bluetoothMonitoringEnabled {
            startDeviceChangeListener()
        }
    }

    func activateRemoteCommandsIfNeeded() {
        guard !remoteCommandsActive else { return }
        setupRemoteCommands()
        remoteCommandsActive = true
    }

    func releaseMediaControls() {
        clearNowPlaying()
        removeRemoteCommandTargets()
        remoteCommandsActive = false
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
    private func consumeForGesture(_ event: MediaGestureDetector.EventType) -> Bool {
        guard gestureDetector.recordEvent(event) else { return false }
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
        suppressWindow = delay

        if enabled != bluetoothMonitoringEnabled {
            bluetoothMonitoringEnabled = enabled
            if enabled {
                startDeviceChangeListener()
            } else {
                stopDeviceChangeListener()
                // Clear any active suppress window when disabling
                suppressUntil = .distantPast
            }
        }
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any previous targets before adding new ones.
        removeRemoteCommandTargets()

        // Each handler funnels its event type through the gesture
        // detector first via `consumeForGesture`. When that returns
        // true, the event was the final piece of a matching pattern
        // — we skip the usual callback so the user doesn't get an
        // unwanted side effect (e.g. a "play" gesture would otherwise
        // start playback in addition to restarting the timer).

        // Play command: only resume, never toggle. Suppressed after device changes
        // to prevent macOS from auto-starting playback when Bluetooth disconnects.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSuppressed {
                // Consume the window — a single spurious command per disconnect.
                self.suppressUntil = .distantPast
                return .success
            }
            if self.consumeForGesture(.play) { return .success }
            self.onPlay?()
            return .success
        }

        // Pause command: only pause, never toggle. Always safe to forward —
        // even during the suppress window, pausing is the correct behaviour.
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.consumeForGesture(.pause) { return .success }
            if self.isSuppressed, self.isCurrentlyPlaying?() == true {
                self.onAudioRouteChangePause?()
                return .success
            }
            self.onPause?()
            return .success
        }

        // Toggle command: in normal operation, reflects genuine user intent
        // (media keys, AirPods single-tap). During the suppress window, though,
        // it is almost certainly the spurious Bluetooth-disconnect toggle that
        // `rcd` forwards. We gate it so the bug cannot flip a paused book into
        // playback on the wrong output device.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSuppressed {
                // Consume the window and only allow the pause direction.
                // - Playing → pause: matches "headphones unplugged, stop audio".
                // - Paused  → ignore: blocks macOS's spurious auto-resume.
                self.suppressUntil = .distantPast
                if self.isCurrentlyPlaying?() == true {
                    self.onAudioRouteChangePause?()
                }
                return .success
            }
            if self.consumeForGesture(.togglePlayPause) { return .success }
            self.onTogglePlayPause?()
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.consumeForGesture(.skipForward) { return .success }
            self.onSkipForward?()
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.consumeForGesture(.skipBackward) { return .success }
            self.onSkipBackward?()
            return .success
        }

        // Next/previous track (AirPods double-tap, etc.) maps to skip forward/backward
        // since that's the most common user expectation for a book reader
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.consumeForGesture(.nextTrack) { return .success }
            self.onSkipForward?()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.consumeForGesture(.previousTrack) { return .success }
            self.onSkipBackward?()
            return .success
        }
    }

    func updateNowPlayingInfo(title: String, author: String, isPlaying: Bool) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = author
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func removeRemoteCommandTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
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
        guard !isListeningForDeviceChanges else { return }

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
    private func handleDefaultOutputChange() {
        // Capture whether the *outgoing* device was Bluetooth BEFORE
        // refreshing the cache to the new device. The spurious rcd
        // toggle only fires on Bluetooth disconnects, so this gate
        // eliminates false positives when the user simply switches
        // between wired/built-in devices.
        let wasBluetooth = previousDeviceWasBluetooth

        // Update the cache now so the next change notification has a
        // fresh baseline for the device we just transitioned to.
        refreshPreviousDeviceInfo()

        guard wasBluetooth else {
            // Non-Bluetooth departure: rcd will not send a spurious
            // toggle. Leave playback untouched.
            return
        }

        armSuppressAndPauseIfPlaying()
    }

    /// Handler for the system-wide audio devices list change.
    /// Catches the AirPods-battery-drain case where the default output
    /// often stays put (macOS keeps the dead device as "default") but the
    /// device disappears from the device list.
    private func handleDeviceListChange() {
        // Battery-drain detection: previously had a Bluetooth default,
        // and that specific device is no longer in the active list.
        if previousDeviceWasBluetooth, previousDeviceID != 0 {
            let currentDevices = allAudioDeviceIDs()
            if !currentDevices.contains(previousDeviceID) {
                // The Bluetooth device we'd been using has vanished from
                // the system. Arm the suppress window and pre-pause
                // exactly as the default-output handler would, then
                // clear cached state so the same vanished device doesn't
                // re-trigger detection on every subsequent unrelated
                // devices-list event (macOS may keep the dead device as
                // the "default" indefinitely).
                armSuppressAndPauseIfPlaying()
                previousDeviceWasBluetooth = false
                previousDeviceID = 0
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
    }

    /// Arm the suppress window for the configured duration, and call
    /// `onPause` if playback is currently running. Shared by the two
    /// disconnect handlers so the response to either trigger is identical.
    /// onPause is only fired when actually playing — calling it on a paused
    /// session would needlessly fire the pause sound effect and reset the
    /// reading-stats session.
    private func armSuppressAndPauseIfPlaying() {
        suppressUntil = Date().addingTimeInterval(suppressWindow)
        if isCurrentlyPlaying?() == true {
            onAudioRouteChangePause?()
        }
    }

    /// Read the current default output device ID from CoreAudio.
    /// Returns nil on query failure (e.g. no output device available).
    private func currentDefaultOutputDeviceID() -> AudioDeviceID? {
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
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
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
    private func refreshPreviousDeviceInfo() {
        guard let deviceID = currentDefaultOutputDeviceID() else {
            // No default output — unusual; treat as non-Bluetooth so we
            // don't spuriously arm the suppress window on nothing.
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
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
        } else {
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
        }
    }

    /// Read the full list of audio device IDs known to the system.
    /// Used by the devices-list listener to detect when the device we
    /// last cached as the default output has been removed (e.g. AirPods
    /// battery drained, taking them out of the active device list even
    /// though macOS may still report them as the "default" output).
    /// Returns an empty array on query failure.
    private func allAudioDeviceIDs() -> [AudioDeviceID] {
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
        guard isListeningForDeviceChanges else { return }

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
    }

    deinit {
        stopDeviceChangeListener()
        removeRemoteCommandTargets()
    }
}
