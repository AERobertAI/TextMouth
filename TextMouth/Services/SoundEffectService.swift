#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import os

/// Events that can have associated sound effects
enum SoundEvent: String, CaseIterable, Codable, Identifiable {
    case play = "Play"
    case pause = "Pause"
    case skipForward = "Skip Forward"
    case skipBackward = "Skip Backward"
    case whereAmIStart = "Where Am I (Start)"
    case whereAmIEnd = "Where Am I (End)"

    var id: String { rawValue }
}

// MARK: - Playing a Sound, Off the Main Thread

/// Plays a sound effect's file, on the sound effects' own serial queue
/// (`SoundEffectService`), never on the main thread. A play may take as long
/// as the system's audio takes to start it, or never return: only that queue
/// waits for it.
protocol SoundEffectPlaying: Actor {
    /// Play the sound in the file at `url` at `volume`, from 0 to 1.
    func play(contentsOf url: URL, volume: Float)
}

/// Plays sound effects through AVFoundation's `AVAudioPlayer`, on a serial
/// queue of its own: the actor's executor (B07).
///
/// `AVAudioPlayer` is used because nothing ties it to the main thread.
/// AppKit's `NSSound`, which played the sounds before, is built on it
/// (`-[NSSound play]` calls `-[AVAudioPlayer play]`), and AppKit's thread
/// safety summary names no sound class as safe off the main thread. On
/// October 14, 2026, with Apple's Vorbis decoder stuck in AudioToolbox, the
/// pause sound's play waited for good on a lock in `AudioQueuePrime`, on the
/// main thread, and froze TextMouth's window.
actor SystemSoundEffectPlayer: SoundEffectPlaying {
    /// The serial queue every sound effect plays on.
    private let queue = DispatchSerialQueue(label: "TextMouth.soundEffects", qos: .userInitiated)

    /// Runs the actor's work, every play, on `queue`.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The players still sounding. A player released while it plays falls
    /// silent at once, so each is kept until a later play finds it done.
    private var sounding: [AVAudioPlayer] = []

    func play(contentsOf url: URL, volume: Float) {
        sounding.removeAll { !$0.isPlaying }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        player.play()
        sounding.append(player)
    }
}

/// Whether a sound effect's play is under way: handed to the sound queue,
/// and not yet returned from there. While one is, later sounds are dropped
/// rather than queued behind it, so a play that never returns holds back
/// nothing but sounds (B07).
struct SoundEffectGate: Equatable, Sendable {
    /// What becomes of a sound asked for.
    enum Decision: Equatable, Sendable {
        /// Nothing is under way: the sound plays, and is under way until it
        /// returns.
        case play
        /// A play under way for `seconds` has not returned, so the sound is
        /// dropped. `isFirstDrop` is true for the first sound dropped behind
        /// that play, the one the log reports.
        case drop(seconds: TimeInterval, isFirstDrop: Bool)
    }

    /// When the play under way was handed over, in seconds of system uptime,
    /// or nil while none is.
    private(set) var playHandedOverAt: TimeInterval?
    /// Whether a sound has been dropped behind the play under way.
    private(set) var hasDroppedASound = false

    /// Decide what becomes of a sound asked for at `now`, taking it as the
    /// play under way when it plays.
    mutating func ask(at now: TimeInterval) -> Decision {
        guard let handedOverAt = playHandedOverAt else {
            playHandedOverAt = now
            hasDroppedASound = false
            return .play
        }
        let isFirstDrop = !hasDroppedASound
        hasDroppedASound = true
        return .drop(seconds: max(0, now - handedOverAt), isFirstDrop: isFirstDrop)
    }

    /// The play under way has returned: the next sound plays.
    mutating func playReturned() {
        playHandedOverAt = nil
        hasDroppedASound = false
    }
}

/// Manages playback of short sound effects for UI events.
/// Uses macOS system sounds from /System/Library/Sounds/ by default.
///
/// A sound is handed to a serial queue of its own and played there
/// (`SoundEffectPlaying`), so the main thread never waits for the system's
/// audio. While a sound's play has not returned, later sounds are dropped,
/// never queued behind it, and the first one dropped is logged as
/// `SOUND_EFFECT_STUCK` (B07).
///
/// The three sound preferences live in the preferences store. The service
/// saves each change made through it there, and takes up every change made
/// there by anyone else: the settings model applying an edit of config.json,
/// which mirrors these preferences, or another copy of this service. Such a
/// change takes effect at once, because each sound reads the preferences as
/// it plays.
class SoundEffectService: ObservableObject {
    // MARK: - The Stored Preferences
    //
    // Every release has used these keys, so saved choices keep loading. The
    // settings model mirrors the preferences in config.json through these
    // same definitions.

    /// Whether sound effects play: on until the user turns them off.
    static let enabledPreference = StoredPreference.flag("soundEffectsEnabled", default: true)

    /// How loud sound effects play, saved as a Float and read like every
    /// numeric preference: any stored number, clamped to the slider's range
    /// (`SettingsPolicy.soundEffectsVolume`), or half volume when none is
    /// stored.
    static let volumePreference = StoredPreference<Float>(
        key: SettingsPolicy.soundEffectsVolume.key,
        read: { store, _ in Float(SettingsPolicy.soundEffectsVolume.storedValue(in: store)) },
        write: { volume, store, key in store.set(volume, forKey: key) }
    )

    /// The sound for each event, saved as JSON keyed by the events' names:
    /// the default assignments until any are saved. An event the saved
    /// assignments leave out plays no sound.
    static let assignmentsPreference = StoredPreference<[SoundEvent: String]>(
        key: "soundEffectAssignments",
        read: { store, key in
            guard let data = store.data(forKey: key),
                  let saved = try? JSONDecoder().decode([String: String].self, from: data) else {
                return SoundEffectService.defaultAssignments
            }
            return [SoundEvent: String](keyedByRawValue: saved)
        },
        write: { assignments, store, key in
            guard let data = try? JSONEncoder().encode(assignments.keyedByRawValue) else { return }
            store.set(data, forKey: key)
        }
    )

    /// The keys of all three sound preferences.
    static var preferenceKeys: [String] {
        [enabledPreference.key, volumePreference.key, assignmentsPreference.key]
    }

    @Published var soundsEnabled: Bool {
        didSet { save(soundsEnabled, as: Self.enabledPreference) }
    }
    @Published var assignments: [SoundEvent: String] {
        didSet { save(assignments, as: Self.assignmentsPreference) }
    }
    @Published var volume: Float {
        didSet { save(volume, as: Self.volumePreference) }
    }

    /// The store holding the sound preferences.
    private let preferences: UserDefaults
    /// Reports changes to the sound preferences in the store.
    private var storeObserver: PreferenceObserver?
    /// True while the service takes values from the store, which already
    /// holds them, so nothing is written back.
    private var isFollowingStore = false

    /// Plays each sound handed over, on the sound queue.
    private let player: any SoundEffectPlaying
    /// The play under way, shared by the main thread, which hands sounds
    /// over, and the sound queue, which returns from them.
    private let gate = OSAllocatedUnfairLock(initialState: SoundEffectGate())

    /// Whether a sound's play is under way: handed to the sound queue and
    /// not yet returned. Later sounds are dropped meanwhile.
    var isPlayUnderWay: Bool {
        gate.withLock { $0.playHandedOverAt != nil }
    }

    static let systemSoundsPath = "/System/Library/Sounds"

    /// Loads the sound preferences from `preferences`, this process's
    /// preferences unless a test passes its own, and follows their changes
    /// there from then on. Missing values fall back to sounds on, half
    /// volume, and the default assignments. Sounds play through `player`:
    /// the system's, unless a test passes one that plays nothing aloud.
    ///
    /// Created on the main actor, where the service then follows the store,
    /// like the interface that uses it.
    @MainActor
    init(
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        player: any SoundEffectPlaying = SystemSoundEffectPlayer()
    ) {
        self.preferences = preferences
        self.player = player
        soundsEnabled = Self.enabledPreference.read(from: preferences)
        volume = Self.volumePreference.read(from: preferences)
        assignments = Self.assignmentsPreference.read(from: preferences)
        storeObserver = PreferenceObserver(keys: Self.preferenceKeys, in: preferences) { [weak self] _ in
            self?.followStore()
        }
    }

    // MARK: - Saving and Following the Store

    /// Saves a preference changed through this service, unless the change
    /// came from the store.
    private func save<Value>(_ value: Value, as preference: StoredPreference<Value>) {
        guard !isFollowingStore else { return }
        preference.write(value, to: preferences)
    }

    /// Takes each sound preference from the store where it differs from the
    /// one in use, because someone else changed it there.
    private func followStore() {
        isFollowingStore = true
        defer { isFollowingStore = false }
        adopt(Self.enabledPreference, into: \.soundsEnabled)
        adopt(Self.volumePreference, into: \.volume)
        adopt(Self.assignmentsPreference, into: \.assignments)
    }

    /// Sets the property at `keyPath` to `preference`'s stored value when
    /// the two differ, so a preference that did not change publishes nothing.
    private func adopt<Value>(
        _ preference: StoredPreference<Value>,
        into keyPath: ReferenceWritableKeyPath<SoundEffectService, Value>
    ) {
        let stored = preference.read(from: preferences)
        if self[keyPath: keyPath] != stored {
            self[keyPath: keyPath] = stored
        }
    }

    static var defaultAssignments: [SoundEvent: String] {
        [
            .play: "Pop",
            .pause: "Tink",
            .skipForward: "Tink",
            .skipBackward: "Tink",
            .whereAmIStart: "Glass",
            .whereAmIEnd: "Submarine"
        ]
    }

    /// `assignments` with every event named. An event they leave out plays
    /// no sound, so it is named None, as the Sounds settings show it.
    static func assignmentsNamingEveryEvent(_ assignments: [SoundEvent: String]) -> [SoundEvent: String] {
        Dictionary(uniqueKeysWithValues: SoundEvent.allCases.map { ($0, assignments[$0] ?? "None") })
    }

    /// Play the sound effect for a given event, as the settings say: none
    /// while sounds are off or the event's sound is None.
    func play(for event: SoundEvent) {
        guard soundsEnabled else { return }
        guard let soundName = assignments[event], soundName != "None" else { return }
        hand(soundName, for: "the \(event.rawValue) sound")
    }

    /// Preview a sound by name, whether or not sounds are on.
    func previewSound(_ name: String) {
        hand(name, for: "the preview of \(name)")
    }

    /// The file of the sound named `name`: a system sound, the only kind
    /// Settings and config.json offer (`SettingsPolicy.soundEffectAssignments`),
    /// or nil when there is no such sound.
    static func soundFile(named name: String) -> URL? {
        let file = URL(fileURLWithPath: systemSoundsPath, isDirectory: true)
            .appendingPathComponent("\(name).aiff")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Hand the sound named `name` to the sound queue to play at the volume
    /// set now, and return at once: the main thread never waits for it.
    ///
    /// While an earlier sound's play has not returned, this sound is dropped
    /// instead, never queued behind it, and the first sound dropped behind
    /// that play is logged.
    ///
    /// - Parameters:
    ///   - name: The sound's name, such as "Tink".
    ///   - purpose: What the sound was for, as the log names it.
    private func hand(_ name: String, for purpose: String) {
        guard let file = Self.soundFile(named: name) else { return }
        switch gate.withLock({ $0.ask(at: ProcessInfo.processInfo.systemUptime) }) {
        case .play:
            // Only Sendable values cross to the sound queue: the actor that
            // plays, the lock, and the file and volume.
            let player = self.player
            let gate = self.gate
            let volume = self.volume
            Task {
                await player.play(contentsOf: file, volume: volume)
                gate.withLock { $0.playReturned() }
            }
        case .drop(let seconds, let isFirstDrop):
            guard isFirstDrop else { return }
            DiagnosticLog.event(
                .playback,
                "SOUND_EFFECT_STUCK: dropped \(purpose); the sound before it has not returned from its play after "
                    + String(format: "%.1f", seconds) + " s, so sounds are dropped until it does"
            )
        }
    }

    /// All available system sound names
    static func availableSounds() -> [String] {
        var sounds = ["None"]
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: systemSoundsPath) {
            let names = files
                .filter { $0.hasSuffix(".aiff") }
                .map { $0.replacingOccurrences(of: ".aiff", with: "") }
                .sortedStably()
            sounds.append(contentsOf: names)
        }
        return sounds
    }

    func resetToDefaults() {
        assignments = Self.defaultAssignments
        volume = Float(SettingsPolicy.soundEffectsVolume.defaultValue)
        soundsEnabled = true
    }
}
