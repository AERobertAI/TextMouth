import SwiftUI

/// The words of Storage settings' Audio Editing group (FR04), shared by the
/// controls and their tests.
enum AudioEditingSettingsWording {
    /// The group's heading.
    static let title = "Audio Editing"
    /// The policy picker's label.
    static let policyLabel = "Original audio"
    /// The policy picker's hint: what an original is, what it costs, and
    /// whom a change reaches.
    static let policyHint = "What happens to the original audio of recordings and edited audiobooks: the lossless "
        + "take a recording is saved from, and a copy of an audiobook's file from before its first edit. Keeping an "
        + "original lets every edit be undone without loss; a recording's costs about 345 MB an hour. A change "
        + "applies to the originals already kept, too. In a library in the cloud, an original syncs with its book."
    /// The days stepper's label.
    static let daysLabel = "Days to keep an original"
    /// The ffmpeg switch's label.
    static let ffmpegLabel = "Use ffmpeg for filters and MP3"

    /// The ffmpeg switch's hint: where TextMouth found ffmpeg, and what it
    /// does when the switch is on.
    static func ffmpegHint(path: String) -> String {
        "TextMouth found ffmpeg at \(path). When this is on, the audio editor's filters run through it, with every "
            + "filter it has, and audio can be exported as MP3."
    }

    /// The line shown when no ffmpeg is installed.
    static let noFFmpeg = "ffmpeg isn't installed, so the audio editor uses TextMouth's own filters, and MP3 export "
        + "isn't available."

    /// How the picker names `choice`.
    static func choiceTitle(_ choice: AudioOriginalPolicy.Choice) -> String {
        switch choice {
        case .keep: return "Keep"
        case .delete: return "Don't keep"
        case .deleteAfterDays: return "Keep for a number of days"
        }
    }

    /// The days, in words: "1 day", "14 days".
    static func days(_ days: Int) -> String {
        CountWording.phrase(days, singular: "day", plural: "days")
    }

    /// The line under the controls saying what the policy in force does.
    static func explanation(_ policy: AudioOriginalPolicy) -> String {
        switch policy {
        case .keep:
            return "Each recording and edited audiobook keeps its original audio until the book is removed."
        case .delete:
            return "No original audio is kept: edits change a book's audio in place, and saved edits can't be undone."
        case .deleteAfter(let count):
            return "Each recording and edited audiobook keeps its original audio for \(days(Int(count.rounded()))) "
                + "after it was saved or last edited; then the original is deleted."
        }
    }
}

/// The audio editing settings as Storage settings shows and changes them:
/// the global original policy and whether an installed ffmpeg is used, read
/// from and written to the preferences store through their own definitions
/// (`AudioOriginalPolicy`, `AudioFilterEngine.usePreference`), where the
/// settings model mirrors them in config.json, and redrawn whenever they
/// change there, wherever they were changed.
@MainActor
final class AudioEditingSettingsModel: ObservableObject {
    /// The store the settings are kept in.
    private let store: UserDefaults
    /// Follows the settings' keys in the store.
    private var observer: PreferenceObserver?
    /// The ffmpeg TextMouth found, or nil when there is none or it hasn't
    /// looked yet.
    @Published private(set) var installedFFmpeg: FFmpeg?
    /// Whether TextMouth has looked for ffmpeg.
    @Published private(set) var hasLookedForFFmpeg = false

    /// A model of the settings in `store`, looking for ffmpeg with `locate`,
    /// off the main thread.
    init(store: UserDefaults, locate: @escaping @Sendable () -> FFmpeg? = { FFmpeg.locate() }) {
        self.store = store
        observer = PreferenceObserver(keys: AudioEditingPreferences.keys, in: store) { [weak self] _ in
            self?.objectWillChange.send()
        }
        Task { [weak self] in
            let found = await Task.detached { locate() }.value
            self?.installedFFmpeg = found
            self?.hasLookedForFFmpeg = true
        }
    }

    /// Whether an installed ffmpeg runs filters and writes MP3.
    var usesFFmpeg: Bool {
        get { AudioFilterEngine.usePreference.read(from: store) }
        set {
            guard newValue != usesFFmpeg else { return }
            objectWillChange.send()
            AudioFilterEngine.usePreference.write(newValue, to: store)
        }
    }

    /// The choice in force.
    var choice: AudioOriginalPolicy.Choice {
        get { AudioOriginalPolicy.choicePreference.read(from: store) }
        set {
            guard newValue != choice else { return }
            objectWillChange.send()
            AudioOriginalPolicy.choicePreference.write(newValue, to: store)
        }
    }

    /// The number of days an original is kept under "keep for a number of
    /// days", in whole days.
    var days: Int {
        get { Int(AudioOriginalPolicy.daysPreference.read(from: store).rounded()) }
        set {
            guard newValue != days else { return }
            objectWillChange.send()
            AudioOriginalPolicy.daysPreference.write(Double(newValue), to: store)
        }
    }

    /// The policy in force.
    var policy: AudioOriginalPolicy {
        AudioOriginalPolicy.global(in: store)
    }
}

/// Storage settings' Audio Editing group (FR04): what happens to the original
/// audio of recordings and edited audiobooks, and whether an installed ffmpeg
/// is used. A picker chooses keep, don't keep, or keep for a number of days,
/// and a stepper the days when that is the choice; the line under them says
/// what the choice does. A switch turns ffmpeg on or off when TextMouth
/// finds one, its hint naming where; without one, a line says what that
/// means. Each control carries its own label, value, and hint, so VoiceOver
/// and a braille display meet each on its own.
struct AudioEditingSettingsSection: View {
    /// The policy, in the app's preferences store unless a test hands in
    /// one of its own.
    @StateObject private var settings: AudioEditingSettingsModel

    /// The group for the policy kept in `store`.
    init(store: UserDefaults = TextMouthRuntime.current.preferences) {
        _settings = StateObject(wrappedValue: AudioEditingSettingsModel(store: store))
    }

    var body: some View {
        Section {
            Picker(AudioEditingSettingsWording.policyLabel, selection: Binding(
                get: { settings.choice },
                set: { settings.choice = $0 }
            )) {
                ForEach(AudioOriginalPolicy.Choice.allCases, id: \.self) { choice in
                    Text(AudioEditingSettingsWording.choiceTitle(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AudioEditingSettingsWording.policyLabel)
            .accessibilityHint(AudioEditingSettingsWording.policyHint)
            .help(AudioEditingSettingsWording.policyHint)

            if settings.choice == .deleteAfterDays {
                Stepper(
                    value: Binding(get: { settings.days }, set: { settings.days = $0 }),
                    in: Int(SettingsPolicy.recordingOriginalDays.range.lowerBound)...Int(SettingsPolicy.recordingOriginalDays.range.upperBound)
                ) {
                    Text("\(AudioEditingSettingsWording.daysLabel): \(AudioEditingSettingsWording.days(settings.days))")
                }
                // A stepper's title does not become its accessibility label.
                .accessibilityLabel(AudioEditingSettingsWording.daysLabel)
                .accessibilityValue(AudioEditingSettingsWording.days(settings.days))
            }

            Text(AudioEditingSettingsWording.explanation(settings.policy))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let ffmpeg = settings.installedFFmpeg {
                Toggle(AudioEditingSettingsWording.ffmpegLabel, isOn: Binding(
                    get: { settings.usesFFmpeg },
                    set: { settings.usesFFmpeg = $0 }
                ))
                .accessibilityHint(AudioEditingSettingsWording.ffmpegHint(path: ffmpeg.executable.path))
                .help(AudioEditingSettingsWording.ffmpegHint(path: ffmpeg.executable.path))
            } else if settings.hasLookedForFFmpeg {
                Text(AudioEditingSettingsWording.noFFmpeg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(AudioEditingSettingsWording.title)
        }
    }
}
