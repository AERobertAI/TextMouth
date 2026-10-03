import AppKit
import AVFoundation

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

/// Manages playback of short sound effects for UI events.
/// Uses macOS system sounds from /System/Library/Sounds/ by default.
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

    /// Currently playing sound (kept alive until playback finishes)
    private var currentSound: NSSound?

    static let systemSoundsPath = "/System/Library/Sounds"

    /// Loads the sound preferences from `preferences`, this process's
    /// preferences unless a test passes its own, and follows their changes
    /// there from then on. Missing values fall back to sounds on, half
    /// volume, and the default assignments.
    ///
    /// Created on the main actor, where the service then follows the store,
    /// like the interface that uses it.
    @MainActor
    init(preferences: UserDefaults = TextMouthRuntime.current.preferences) {
        self.preferences = preferences
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

    /// Play the sound effect for a given event
    func play(for event: SoundEvent) {
        guard soundsEnabled else { return }
        guard let soundName = assignments[event], soundName != "None" else { return }

        let sound: NSSound?
        if let systemSound = NSSound(contentsOfFile: "\(Self.systemSoundsPath)/\(soundName).aiff", byReference: true) {
            sound = systemSound
        } else {
            sound = NSSound(named: NSSound.Name(soundName))
        }

        guard let soundToPlay = sound else { return }
        soundToPlay.volume = volume
        soundToPlay.stop()
        soundToPlay.play()
        currentSound = soundToPlay
    }

    /// Preview a sound by name
    func previewSound(_ name: String) {
        let sound: NSSound?
        if let systemSound = NSSound(contentsOfFile: "\(Self.systemSoundsPath)/\(name).aiff", byReference: true) {
            sound = systemSound
        } else {
            sound = NSSound(named: NSSound.Name(name))
        }
        guard let soundToPlay = sound else { return }
        soundToPlay.volume = volume
        soundToPlay.play()
        currentSound = soundToPlay
    }

    /// All available system sound names
    static func availableSounds() -> [String] {
        var sounds = ["None"]
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: systemSoundsPath) {
            let names = files
                .filter { $0.hasSuffix(".aiff") }
                .map { $0.replacingOccurrences(of: ".aiff", with: "") }
                .sorted()
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
