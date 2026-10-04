import SwiftUI

/// The words of Storage settings' Recordings group (FR04), shared by the
/// controls and their tests.
enum RecordingSettingsWording {
    /// The group's heading.
    static let title = "Recordings"
    /// The policy picker's label.
    static let policyLabel = "Original recordings"
    /// The policy picker's hint: what an original is, what it costs, and
    /// whom a change reaches.
    static let policyHint = "What happens to a recording's original take, the lossless audio a recording is saved "
        + "from, once it is an audiobook. Keeping it lets an edit start again from it without loss, at about 345 MB "
        + "an hour. A change applies to the originals already kept, too. In a library in the cloud, an original syncs "
        + "with its book."
    /// The days stepper's label.
    static let daysLabel = "Days to keep an original"

    /// How the picker names `choice`.
    static func choiceTitle(_ choice: RecordingOriginalPolicy.Choice) -> String {
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
    static func explanation(_ policy: RecordingOriginalPolicy) -> String {
        switch policy {
        case .keep:
            return "Each recording keeps its original take until the book is removed."
        case .delete:
            return "Recordings keep no original take: the audiobook's audio is all there is."
        case .deleteAfter(let count):
            return "Each recording keeps its original take for \(days(Int(count.rounded()))) after it was saved "
                + "or last edited; then the original is deleted."
        }
    }
}

/// The global original-take policy as Storage settings shows and changes
/// it: read from and written to the preferences store through the policy's
/// own definitions (`RecordingOriginalPolicy`), where the settings model
/// mirrors it in config.json, and redrawn whenever it changes there,
/// wherever it was changed.
@MainActor
final class RecordingSettingsModel: ObservableObject {
    /// The store the policy is kept in.
    private let store: UserDefaults
    /// Follows the policy's keys in the store.
    private var observer: PreferenceObserver?

    /// A model of the policy in `store`.
    init(store: UserDefaults) {
        self.store = store
        observer = PreferenceObserver(keys: RecordingOriginalPolicy.preferenceKeys, in: store) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// The choice in force.
    var choice: RecordingOriginalPolicy.Choice {
        get { RecordingOriginalPolicy.choicePreference.read(from: store) }
        set {
            guard newValue != choice else { return }
            objectWillChange.send()
            RecordingOriginalPolicy.choicePreference.write(newValue, to: store)
        }
    }

    /// The number of days an original is kept under "keep for a number of
    /// days", in whole days.
    var days: Int {
        get { Int(RecordingOriginalPolicy.daysPreference.read(from: store).rounded()) }
        set {
            guard newValue != days else { return }
            objectWillChange.send()
            RecordingOriginalPolicy.daysPreference.write(Double(newValue), to: store)
        }
    }

    /// The policy in force.
    var policy: RecordingOriginalPolicy {
        RecordingOriginalPolicy.global(in: store)
    }
}

/// Storage settings' Recordings group (FR04): what happens to a recording's
/// original take once it is saved as an audiobook. A picker chooses keep,
/// don't keep, or keep for a number of days, and a stepper the days when
/// that is the choice; the line under them says what the choice does. Each
/// control carries its own label, value, and hint, so VoiceOver and a
/// braille display meet each on its own.
struct RecordingSettingsSection: View {
    /// The policy, in the app's preferences store unless a test hands in
    /// one of its own.
    @StateObject private var settings: RecordingSettingsModel

    /// The group for the policy kept in `store`.
    init(store: UserDefaults = TextMouthRuntime.current.preferences) {
        _settings = StateObject(wrappedValue: RecordingSettingsModel(store: store))
    }

    var body: some View {
        Section {
            Picker(RecordingSettingsWording.policyLabel, selection: Binding(
                get: { settings.choice },
                set: { settings.choice = $0 }
            )) {
                ForEach(RecordingOriginalPolicy.Choice.allCases, id: \.self) { choice in
                    Text(RecordingSettingsWording.choiceTitle(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(RecordingSettingsWording.policyLabel)
            .accessibilityHint(RecordingSettingsWording.policyHint)
            .help(RecordingSettingsWording.policyHint)

            if settings.choice == .deleteAfterDays {
                Stepper(
                    value: Binding(get: { settings.days }, set: { settings.days = $0 }),
                    in: Int(SettingsPolicy.recordingOriginalDays.range.lowerBound)...Int(SettingsPolicy.recordingOriginalDays.range.upperBound)
                ) {
                    Text("\(RecordingSettingsWording.daysLabel): \(RecordingSettingsWording.days(settings.days))")
                }
                // A stepper's title does not become its accessibility label.
                .accessibilityLabel(RecordingSettingsWording.daysLabel)
                .accessibilityValue(RecordingSettingsWording.days(settings.days))
            }

            Text(RecordingSettingsWording.explanation(settings.policy))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(RecordingSettingsWording.title)
        }
    }
}
