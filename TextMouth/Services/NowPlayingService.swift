import Foundation
import MediaPlayer
import CoreAudio

/// Integrates with macOS Now Playing center for media key and AirPods control.
/// Also monitors audio device changes to prevent phantom playback when
/// Bluetooth devices disconnect.
class NowPlayingService {
    private var onPlay: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onTogglePlayPause: (() -> Void)?
    private var onSkipForward: (() -> Void)?
    private var onSkipBackward: (() -> Void)?

    /// When true, the next playCommand from the system is suppressed.
    /// Set when an audio device disconnects (e.g. AirPods removed) to prevent
    /// macOS from auto-resuming playback on the new output device.
    private var suppressNextPlay = false

    /// Listener for default audio output device changes
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var isListeningForDeviceChanges = false

    init() {}

    func setup(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayPause = onTogglePlayPause
        self.onSkipForward = onSkipForward
        self.onSkipBackward = onSkipBackward

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
            if self.suppressNextPlay {
                self.suppressNextPlay = false
                return .success
            }
            self.onPlay?()
            return .success
        }

        // Pause command: only pause, never toggle.
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }

        // Toggle is used by media keys (play/pause on keyboard) — genuine user intent.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.suppressNextPlay = false
            self?.onTogglePlayPause?()
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
    /// suppress the next system-issued playCommand so playback doesn't auto-resume.
    private func startDeviceChangeListener() {
        guard !isListeningForDeviceChanges else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            // Device changed — suppress the next play command to prevent phantom resume.
            // Also pause immediately so audio doesn't bleed to the new device.
            self.suppressNextPlay = true
            DispatchQueue.main.async {
                self.onPause?()
            }
            // Clear the suppress flag after a short window so that a deliberate
            // user play action (e.g. pressing play a few seconds later) isn't blocked.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.suppressNextPlay = false
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            listenerBlock
        )

        if status == noErr {
            deviceChangeListenerBlock = listenerBlock
            isListeningForDeviceChanges = true
        }
    }

    private func stopDeviceChangeListener() {
        guard isListeningForDeviceChanges, let block = deviceChangeListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
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
