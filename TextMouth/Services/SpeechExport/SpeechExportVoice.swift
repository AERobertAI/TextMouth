import AVFoundation
import Foundation

// MARK: - The Voice, Speed, and Pitch

/// The voice, speed, and pitch a text book is read with, which a speech
/// export (FMT43) speaks it into a file with: the book's own where it has
/// them, else the global ones, chosen as a reader chooses them when it opens
/// the book (`ReaderViewModel.applyLocalSpeechOverrides()` over what
/// `SpeechService.init(userDefaults:)` reads).
struct SpeechExportVoiceSettings: Equatable, Sendable {
    /// The identifier of the voice that speaks, or nil when no voice at all
    /// is installed to speak.
    var voiceIdentifier: String?
    /// The speed, in words per minute.
    var wordsPerMinute: Double
    /// The pitch multiplier; 1 is the voice's own pitch.
    var pitch: Double

    /// The preference holding the global voice's identifier: the key
    /// `SpeechService` reads at launch and writes when a voice is chosen
    /// (`selectVoice(_:)`), and the one the Settings model,
    /// `SettingsViewModel`, keeps its `selectedVoiceID` under.
    static let globalVoiceKey = "selectedVoiceID"

    /// The voice, speed, and pitch `book` is read with, as a reader applies
    /// them:
    /// - the voice: the book's own when it is installed; else the global
    ///   voice when it is installed; else `fallback()`, the voice
    ///   `SpeechService` falls back to.
    /// - the speed: the book's own when it is a number, held to the speeds
    ///   Settings offers, as `SpeechService.setSpeedRealtime(_:)` holds it;
    ///   else the global speed, validated as Settings validates it. An
    ///   audiobook's own speed is a playback rate, never words per minute,
    ///   so it is passed over, as a reader passes it over.
    /// - the pitch: the book's own when it is a number, held to the pitches
    ///   both speech engines take (`SpeechService.clampedPitch(_:)`); else
    ///   the global pitch, validated likewise.
    /// - Parameters:
    ///   - book: The book.
    ///   - defaults: The preferences holding the global voice, speed, and
    ///     pitch.
    ///   - isInstalled: Whether a voice with an identifier is installed;
    ///     tests pass their own.
    ///   - fallback: The identifier of the voice that speaks when neither
    ///     the book's voice nor the global one is installed, or nil when
    ///     there is none; tests pass their own.
    static func of(
        _ book: Book,
        defaults: UserDefaults,
        isInstalled: (String) -> Bool = SpeechExportVoiceInfo.isInstalled,
        fallback: () -> String? = SpeechExportVoiceInfo.fallbackIdentifier
    ) -> SpeechExportVoiceSettings {
        // The book's voice comes first and the global one second; the first
        // of them installed speaks.
        let chosenVoices = [book.localVoiceID, defaults.string(forKey: globalVoiceKey)].compactMap { $0 }
        let speeds = SettingsPolicy.wordsPerMinute.range
        return SpeechExportVoiceSettings(
            voiceIdentifier: chosenVoices.first(where: isInstalled) ?? fallback(),
            wordsPerMinute: setting(
                book.format.isAudio ? nil : book.localWPM,
                heldBy: { min(max($0, speeds.lowerBound), speeds.upperBound) },
                otherwise: SettingsPolicy.wordsPerMinute,
                in: defaults
            ),
            pitch: setting(
                book.localPitch,
                heldBy: SpeechService.clampedPitch,
                otherwise: SettingsPolicy.pitchMultiplier,
                in: defaults
            )
        )
    }

    /// A book's own value, `own`, held by `hold`, when it has one that is a
    /// finite number; otherwise the global preference `rule` reads from
    /// `defaults` (its default when nothing usable is stored).
    private static func setting(
        _ own: Double?,
        heldBy hold: (Double) -> Double,
        otherwise rule: NumericSettingRule,
        in defaults: UserDefaults
    ) -> Double {
        guard let own, own.isFinite else { return rule.storedValue(in: defaults) }
        return hold(own)
    }
}

// MARK: - An Installed Voice

/// What a speech export needs to know of an installed voice: its name, for
/// the Export dialog and its refusals, and whether it is a Personal Voice,
/// which macOS speaks aloud but never into a file. It is read from the
/// voice's description alone: nothing here speaks, or asks to use a
/// Personal Voice.
struct SpeechExportVoiceInfo: Equatable, Sendable {
    /// The voice's identifier.
    let identifier: String
    /// The voice's name, as Settings and the reader's Voice button show it.
    let name: String
    /// Whether the voice is a Personal Voice, one the user made of their own
    /// voice.
    let isPersonalVoice: Bool

    /// The installed voice with `identifier`, or nil when no installed voice
    /// has it.
    static func installed(_ identifier: String) -> SpeechExportVoiceInfo? {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return nil }
        return SpeechExportVoiceInfo(
            identifier: voice.identifier,
            name: voice.name,
            isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }

    /// Whether a voice with `identifier` is installed.
    static func isInstalled(_ identifier: String) -> Bool {
        installed(identifier) != nil
    }

    /// The identifier of the voice speech falls back to when no voice chosen
    /// is installed: the system's voice for US English, as
    /// `SpeechService.init(userDefaults:)` falls back; nil when there is
    /// none.
    static func fallbackIdentifier() -> String? {
        AVSpeechSynthesisVoice(language: "en-US")?.identifier
    }
}
