import SwiftUI

/// The words of Storage settings' Audio Editing group (FR04), shared by the
/// controls and their tests.
enum AudioEditingSettingsWording {
    /// The group's heading.
    static var title: String {
        // Translators: Heading of the Audio Editing group in Storage settings: what happens to originals of edited audio, ffmpeg, and the audio editor's behaviour.
        InterfaceText.line("audioEditingSettings.title", "Audio Editing")
    }

    /// The policy picker's label.
    static var policyLabel: String {
        // Translators: Label of the picker in Storage settings (Audio Editing) that chooses what happens to the original audio of recordings and edited audiobooks.
        InterfaceText.line("common.originalAudio", "Original audio")
    }

    /// The policy picker's hint: what an original is, what it costs, and
    /// whom a change reaches.
    static var policyHint: String {
        // Translators: Hint of the Original audio picker in Storage settings (Audio Editing): what an original is, what keeping it costs (345 MB is for an hour of a recording), and that a change reaches originals already kept.
        InterfaceText.line("audioEditingSettings.policyHint", "The original is the lossless take a recording is saved from, or a copy of an audiobook's file from before its first edit. Keeping it lets every edit be undone without loss; a recording's costs about 345 MB an hour. A change also applies to originals already kept, and in a cloud library an original syncs with its book.")
    }

    /// The days stepper's label.
    static var daysLabel: String {
        // Translators: Label of the stepper that sets how many days an original audio is kept, in Storage settings (Audio Editing) and the audio editor's Audio Info.
        InterfaceText.line("audioEditingSettings.daysLabel", "Days to keep an original")
    }

    /// The ffmpeg switch's label.
    static var ffmpegLabel: String {
        // Translators: Label of the switch in Storage settings (Audio Editing) that lets the audio editor's filters run through an installed ffmpeg program. ffmpeg is the program's name.
        InterfaceText.line("audioEditingSettings.ffmpegLabel", "Use ffmpeg for filters")
    }

    /// The ffmpeg switch's hint: where TextMouth found ffmpeg, and what it
    /// does when the switch is on. MP3 needs no ffmpeg: TextMouth writes it
    /// with the LAME encoder built in (`MP3Route`).
    static func ffmpegHint(path: String) -> String {
        // Translators: Hint of the Use ffmpeg for filters switch in Storage settings. %@ is the folder path where the ffmpeg program was found. ffmpeg is the program's name.
        InterfaceText.line("audioEditingSettings.ffmpegHint", "Found at \(path). When on, the editor's filters run through ffmpeg, with every filter it has.")
    }

    /// The line shown when no ffmpeg is installed.
    static var noFFmpeg: String {
        // Translators: Shown in Storage settings (Audio Editing) when no ffmpeg program is installed. ffmpeg is the program's name.
        InterfaceText.line("audioEditingSettings.noFFmpeg", "ffmpeg isn't installed; TextMouth's own filters are used.")
    }

    /// The preview switch's label.
    static var previewFiltersLabel: String {
        // Translators: Label of the switch in Storage settings (Audio Editing) that makes the audio editor's Apply Filter play the filtered audio first.
        InterfaceText.line("audioEditingSettings.previewFiltersLabel", "Preview filters before applying")
    }

    /// What the preview switch does.
    static var previewFiltersHint: String {
        // Translators: Hint of the Preview filters before applying switch in Storage settings. Apply Filter and Apply are the audio editor's command and button.
        InterfaceText.line("audioEditingSettings.previewFiltersHint", "Apply Filter plays a preview first, and applies when you choose Apply again.")
    }

    /// The half-second switch's label.
    static var playAfterMovesLabel: String {
        // Translators: Label of the switch in Storage settings (Audio Editing) that makes the audio editor play half a second at the cursor after each move.
        InterfaceText.line("audioEditingSettings.playAfterMovesLabel", "Play half a second after each move")
    }

    /// What the half-second switch does.
    static var playAfterMovesHint: String {
        // Translators: Hint of the Play half a second after each move switch in Storage settings.
        InterfaceText.line("audioEditingSettings.playAfterMovesHint", "Plays half a second at the cursor after each move.")
    }

    /// The button that opens the filter presets.
    static var presetsButton: String {
        // Translators: Button in Storage settings (Audio Editing) that opens the list of the audio editor's filter presets.
        InterfaceText.line("audioEditingSettings.presetsButton", "Filter Presets…")
    }

    /// What it opens.
    static var presetsHint: String {
        // Translators: Hint of the Filter Presets button in Storage settings.
        InterfaceText.line("audioEditingSettings.presetsHint", "Opens the filter presets, to edit, add, reorder, delete, or reset.")
    }

    /// How the picker names `choice`.
    static func choiceTitle(_ choice: AudioOriginalPolicy.Choice) -> String {
        switch choice {
        case .keep:
            // Translators: Choice of the Original audio picker: keep the original audio of a recording or edited audiobook until its book is removed.
            return InterfaceText.line("common.keep", "Keep")
        case .delete:
            // Translators: Choice of the Original audio picker: keep no original audio.
            return InterfaceText.line("audioEditingSettings.choiceTitle.delete", "Don't keep")
        case .deleteAfterDays:
            // Translators: Choice of the Original audio picker: keep the original audio for a number of days, set by a stepper beside it.
            return InterfaceText.line("audioEditingSettings.choiceTitle.deleteAfterDays", "Keep for a number of days")
        }
    }

    /// The days, in words: "1 day", "14 days".
    static func days(_ days: Int) -> String {
        // Translators: A number of days, as the audio editor's original audio is kept for them. %lld is the number of days.
        InterfaceText.line("common.countDays", "\(number: days) days")
    }

    /// The line under the controls saying what the policy in force does.
    static func explanation(_ policy: AudioOriginalPolicy) -> String {
        switch policy {
        case .keep:
            // Translators: Explains Storage settings' Original audio choice Keep: originals are kept until their book is removed.
            return InterfaceText.line("audioEditingSettings.explanation.keep", "Originals are kept until the book is removed.")
        case .delete:
            // Translators: Explains Storage settings' Original audio choice Don't keep: no original is kept, so saved edits can't be undone.
            return InterfaceText.line("audioEditingSettings.explanation.delete", "No original is kept: edits change the audio in place, and saved edits can't be undone.")
        case .deleteAfter(let count):
            // Translators: Explains Storage settings' Original audio choice Keep for a number of days. %lld is the number of days.
            return InterfaceText.line("audioEditingSettings.explanation.deleteAfter", "Originals are kept for \(number: Int(count.rounded())) days after the book was saved or last edited, then deleted.")
        }
    }

    /// A stepper's title, its label and its value: "Days to keep an
    /// original: 14 days".
    static func daysTitle(_ days: Int) -> String {
        AudioEditorWording.labeled(daysLabel, Self.days(days))
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

    /// Whether an installed ffmpeg runs filters, and writes MP3 should
    /// TextMouth's own encoder be unavailable (`MP3Route`).
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

    /// Whether Apply Filter previews a filter before applying it.
    var previewsFiltersFirst: Bool {
        get { AudioEditorPreferences.previewFiltersFirst.read(from: store) }
        set {
            guard newValue != previewsFiltersFirst else { return }
            objectWillChange.send()
            AudioEditorPreferences.previewFiltersFirst.write(newValue, to: store)
        }
    }

    /// Whether the editor plays half a second after each move.
    var playsAfterMoves: Bool {
        get { AudioEditorPreferences.playAfterMoves.read(from: store) }
        set {
            guard newValue != playsAfterMoves else { return }
            objectWillChange.send()
            AudioEditorPreferences.playAfterMoves.write(newValue, to: store)
        }
    }
}

/// Storage settings' Audio Editing group (FR04): what happens to the original
/// audio of recordings and edited audiobooks, and whether an installed ffmpeg
/// is used. A picker chooses keep, don't keep, or keep for a number of days,
/// and a stepper the days when that is the choice; the line under them says
/// what the choice does. A switch turns ffmpeg on or off when TextMouth
/// finds one, its hint naming where; without one, a line says what that
/// means. Two switches set how the audio editor window behaves, and Filter
/// Presets… opens the presets it applies. Each control carries its own
/// label, value, and hint, so VoiceOver and a braille display meet each on
/// its own.
struct AudioEditingSettingsSection: View {
    /// The policy, in the app's preferences store unless a test hands in
    /// one of its own.
    @StateObject private var settings: AudioEditingSettingsModel
    /// Whether the filter presets' sheet is open.
    @State private var showsPresets = false

    /// The group for the settings kept in `store`, looking for ffmpeg with
    /// `locate`: on this Mac's disk, unless a test says what it finds.
    init(store: UserDefaults = TextMouthRuntime.current.preferences, locate: @escaping @Sendable () -> FFmpeg? = { FFmpeg.locate() }) {
        _settings = StateObject(wrappedValue: AudioEditingSettingsModel(store: store, locate: locate))
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
                    Text(AudioEditingSettingsWording.daysTitle(settings.days))
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

            Toggle(AudioEditingSettingsWording.previewFiltersLabel, isOn: Binding(
                get: { settings.previewsFiltersFirst },
                set: { settings.previewsFiltersFirst = $0 }
            ))
            .accessibilityHint(AudioEditingSettingsWording.previewFiltersHint)
            .help(AudioEditingSettingsWording.previewFiltersHint)

            Toggle(AudioEditingSettingsWording.playAfterMovesLabel, isOn: Binding(
                get: { settings.playsAfterMoves },
                set: { settings.playsAfterMoves = $0 }
            ))
            .accessibilityHint(AudioEditingSettingsWording.playAfterMovesHint)
            .help(AudioEditingSettingsWording.playAfterMovesHint)

            Button(AudioEditingSettingsWording.presetsButton) { showsPresets = true }
                .accessibilityHint(AudioEditingSettingsWording.presetsHint)
                .help(AudioEditingSettingsWording.presetsHint)
                .sheet(isPresented: $showsPresets) {
                    AudioFilterPresetsView(close: { showsPresets = false })
                }
        } header: {
            Text(AudioEditingSettingsWording.title)
        }
    }
}
