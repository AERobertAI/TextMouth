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
class NowPlayingService {
    private var onPlay: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onTogglePlayPause: (() -> Void)?
    private var onSkipForward: (() -> Void)?
    private var onSkipBackward: (() -> Void)?
    /// Returns true when playback is currently running (not paused and not stopped).
    /// Used by the suppress-window logic to decide whether a spurious toggle
    /// should be converted into a pause or ignored entirely.
    private var isCurrentlyPlaying: (() -> Bool)?

    /// Timestamp until which incoming system play/toggle commands should be
    /// treated as spurious (Bluetooth-disconnect artefacts). `distantPast`
    /// means the window is inactive. Compared to `Date()` via `isSuppressed`.
    private var suppressUntil: Date = .distantPast

    /// How long the suppress window stays open after an audio device change.
    /// rcd typically delivers its toggle within a few hundred milliseconds,
    /// so 2s is comfortably long enough to catch the spurious command while
    /// staying short enough that a deliberate media-key press a few seconds
    /// later still works.
    private static let suppressWindow: TimeInterval = 2.0

    /// True while the device-change suppress window is active.
    private var isSuppressed: Bool { Date() < suppressUntil }

    /// Listener for default audio output device changes
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var isListeningForDeviceChanges = false

    /// Whether the previous default output device was a Bluetooth device.
    /// Cached while the device is still queryable (at setup and at the end
    /// of every change notification), because by the time the listener
    /// fires for a disconnect, the outgoing device may already be gone and
    /// its transport type unreadable. Used to skip the suppress window
    /// when the user is simply switching between wired/built-in devices —
    /// rcd only sends its spurious toggle on Bluetooth transitions.
    private var previousDeviceWasBluetooth: Bool = false

    init() {}

    func setup(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        isCurrentlyPlaying: @escaping () -> Bool
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayPause = onTogglePlayPause
        self.onSkipForward = onSkipForward
        self.onSkipBackward = onSkipBackward
        self.isCurrentlyPlaying = isCurrentlyPlaying

        setupRemoteCommands()
        startDeviceChangeListener()
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any previous targets before adding new ones
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

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
            self.onPlay?()
            return .success
        }

        // Pause command: only pause, never toggle. Always safe to forward —
        // even during the suppress window, pausing is the correct behaviour.
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
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
                    self.onPause?()
                }
                return .success
            }
            self.onTogglePlayPause?()
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.onSkipForward?()
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.onSkipBackward?()
            return .success
        }

        // Next/previous track (AirPods double-tap, etc.) maps to skip forward/backward
        // since that's the most common user expectation for a book reader
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.onSkipForward?()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.onSkipBackward?()
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

    // MARK: - Audio Device Change Monitoring

    /// Listen for default audio output device changes via CoreAudio.
    /// When the output device changes (e.g. AirPods disconnect, switching to speakers),
    /// open the suppress window so the spurious toggle/play command that rcd
    /// sends next can be gated. If playback was already running, preemptively
    /// pause so audio doesn't bleed to the new device.
    private func startDeviceChangeListener() {
        guard !isListeningForDeviceChanges else { return }

        // Capture the initial device's transport type so the first change
        // notification has a meaningful baseline to compare against.
        refreshPreviousDeviceInfo()

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }

            // Capture whether the *outgoing* device was Bluetooth BEFORE
            // refreshing the cache to the new device. The spurious rcd
            // toggle only fires on Bluetooth disconnects, so this gate
            // eliminates false positives when the user simply switches
            // between wired/built-in devices.
            let wasBluetooth = self.previousDeviceWasBluetooth

            // Update the cache now so the next change notification has a
            // fresh baseline for the device we just transitioned to.
            self.refreshPreviousDeviceInfo()

            guard wasBluetooth else {
                // Non-Bluetooth departure: rcd will not send a spurious
                // toggle. Leave playback untouched.
                return
            }

            // Arm the suppress window so the incoming spurious system command
            // (usually togglePlayPauseCommand on Bluetooth disconnect) is gated.
            self.suppressUntil = Date().addingTimeInterval(Self.suppressWindow)

            // Preemptively pause only if we were actually playing. Calling
            // onPause when already paused would fire the pause sound effect
            // and needlessly thrash the reading-stats session.
            //
            // No explicit dispatch needed: the listener is registered on
            // DispatchQueue.main below, which is the same queue that
            // MPRemoteCommand handlers are invoked on. This both eliminates
            // the data race on suppressUntil and guarantees deterministic
            // ordering with the command handler if the events land close
            // together.
            if self.isCurrentlyPlaying?() == true {
                self.onPause?()
            }
        }

        // Dispatching on .main ensures we share a serial queue with the
        // MPRemoteCommand handlers. With nil here, CoreAudio's SDK header
        // says the block is "directly invoked" on the framework's internal
        // notification thread — which would introduce an unsynchronised
        // race on suppressUntil against the command handlers.
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock
        )

        if status == noErr {
            deviceChangeListenerBlock = listenerBlock
            isListeningForDeviceChanges = true
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

    /// Refresh the cached `previousDeviceWasBluetooth` flag from the
    /// current default output device. Called at setup and at the end of
    /// every change notification so the next notification has an
    /// up-to-date baseline that's still queryable.
    private func refreshPreviousDeviceInfo() {
        if let deviceID = currentDefaultOutputDeviceID() {
            previousDeviceWasBluetooth = isBluetoothDevice(deviceID)
        } else {
            // No default output — unusual; treat as non-Bluetooth so we
            // don't spuriously arm the suppress window on nothing.
            previousDeviceWasBluetooth = false
        }
    }

    private func stopDeviceChangeListener() {
        guard isListeningForDeviceChanges, let block = deviceChangeListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // The dispatch queue must match the one used in
        // startDeviceChangeListener(), otherwise the unregistration fails.
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )

        deviceChangeListenerBlock = nil
        isListeningForDeviceChanges = false
    }

    deinit {
        stopDeviceChangeListener()

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
    }
}
