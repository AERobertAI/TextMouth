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
class SoundEffectService: ObservableObject {
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundEffectsEnabled") }
    }
    @Published var assignments: [SoundEvent: String] {
        didSet { saveAssignments() }
    }
    @Published var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: "soundEffectsVolume") }
    }

    /// Currently playing sound (kept alive until playback finishes)
    private var currentSound: NSSound?

    static let systemSoundsPath = "/System/Library/Sounds"

    init() {
        let enabled = UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool ?? true
        self.soundsEnabled = enabled
        let vol = UserDefaults.standard.object(forKey: "soundEffectsVolume") as? Float ?? 0.5
        self.volume = vol

        if let data = UserDefaults.standard.data(forKey: "soundEffectAssignments"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            var loaded: [SoundEvent: String] = [:]
            for (key, value) in saved {
                if let event = SoundEvent(rawValue: key) {
                    loaded[event] = value
                }
            }
            self.assignments = loaded
        } else {
            self.assignments = Self.defaultAssignments
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

    private func saveAssignments() {
        var dict: [String: String] = [:]
        for (event, sound) in assignments {
            dict[event.rawValue] = sound
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "soundEffectAssignments")
        }
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
        volume = 0.5
        soundsEnabled = true
    }
}
